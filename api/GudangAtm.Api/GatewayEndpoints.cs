using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

/// Jembatan ke alat di LAN gudang. Web/HP minta timbang atau cetak lewat API ini; PC "Gateway" di gudang
/// mengambil pekerjaannya (koneksi keluar saja) lalu mengirim hasilnya kembali.
public static class GatewayEndpoints
{
    static IResult Bad(string m) => Results.BadRequest(new { message = m });

    // ------------------------------------------------------------------ untuk krani (cookie / Bearer)
    public static void MapAlat(this RouteGroupBuilder api, Func<SqlConnection> dbf)
    {
        // Daftar timbangan & printer di gudang user
        api.MapGet("/alat", async (string whs) =>
        {
            await using var db = dbf();
            var timbangan = await db.QueryAsync(@"SELECT t.KodeTimbangan, t.Alat, t.Lokasi, g.LastSeen
                FROM WHS_MasterTimbangan t LEFT JOIN WHS_Gateway g ON g.GatewayId = t.GatewayId
                WHERE t.WhsCode = @whs AND t.Aktif = 1 ORDER BY t.KodeTimbangan", new { whs });
            var printer = await db.QueryAsync(@"SELECT p.KodePrinter, p.Lokasi, p.UkuranMm, g.LastSeen
                FROM WHS_MasterPrinter p JOIN WHS_Gateway g ON g.GatewayId = p.GatewayId
                WHERE p.WhsCode = @whs AND p.Aktif = 1 ORDER BY p.KodePrinter", new { whs });
            return Results.Ok(new { timbangan, printer, sekarang = DateTime.Now });
        });

        // Baca berat dari indikator. Menunggu hasil gateway sampai ~15 detik.
        api.MapPost("/alat/timbang", async (TimbangReq req, ClaimsPrincipal u, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(req.KodeTimbangan)) return Bad("Pilih timbangan");
            await using var db = dbf();
            var t = await db.QueryFirstOrDefaultAsync<(string? GatewayId, DateTime? LastSeen)>(@"SELECT t.GatewayId, g.LastSeen
                FROM WHS_MasterTimbangan t LEFT JOIN WHS_Gateway g ON g.GatewayId = t.GatewayId AND g.Aktif = 1
                WHERE t.KodeTimbangan = @k AND t.Aktif = 1", new { k = req.KodeTimbangan });
            if (t.GatewayId is null) return Bad("Timbangan tidak ditemukan atau belum dihubungkan ke gateway");
            if (t.LastSeen is null || (DateTime.Now - t.LastSeen.Value).TotalSeconds > 60)
                return Bad("PC gateway gudang tidak terhubung. Hubungi IT, atau isi berat manual.");
            var id = await db.ExecuteScalarAsync<long>(@"INSERT INTO WHS_GatewayJob (GatewayId, Tipe, Target, UserId)
                OUTPUT INSERTED.JobId VALUES (@g, 'TIMBANG', @k, @u)", new { g = t.GatewayId, k = req.KodeTimbangan, u = u.UserId() });
            return await Tunggu(db, id, 15, ct);
        });

        // Cetak label QR. Server menyusun TSPL; HP/web hanya kirim isi label.
        api.MapPost("/alat/cetak", async (CetakReq req, ClaimsPrincipal u) =>
        {
            if (string.IsNullOrWhiteSpace(req.KodePrinter)) return Bad("Pilih printer");
            var err = req.Validasi();
            if (err is not null) return Bad(err);
            await using var db = dbf();
            var p = await db.QueryFirstOrDefaultAsync<(string GatewayId, string UkuranMm, DateTime? LastSeen)>(@"SELECT p.GatewayId, p.UkuranMm, g.LastSeen
                FROM WHS_MasterPrinter p JOIN WHS_Gateway g ON g.GatewayId = p.GatewayId AND g.Aktif = 1
                WHERE p.KodePrinter = @k AND p.Aktif = 1", new { k = req.KodePrinter });
            if (p.GatewayId is null) return Bad("Printer tidak ditemukan");
            if (p.LastSeen is null || (DateTime.Now - p.LastSeen.Value).TotalSeconds > 60)
                return Bad("PC gateway gudang tidak terhubung. Label belum dicetak.");
            var tspl = Tspl.Label(req, p.UkuranMm);
            var id = await db.ExecuteScalarAsync<long>(@"INSERT INTO WHS_GatewayJob (GatewayId, Tipe, Target, Payload, UserId)
                OUTPUT INSERTED.JobId VALUES (@g, 'CETAK', @k, @tspl, @u)", new { g = p.GatewayId, k = req.KodePrinter, tspl, u = u.UserId() });
            return await Tunggu(db, id, 20, CancellationToken.None);
        });
    }

    static async Task<IResult> Tunggu(SqlConnection db, long id, int detik, CancellationToken ct)
    {
        var sampai = DateTime.UtcNow.AddSeconds(detik);
        while (DateTime.UtcNow < sampai && !ct.IsCancellationRequested)
        {
            await Task.Delay(400, CancellationToken.None);
            var j = await db.QueryFirstAsync<JobRow>("SELECT Status, BeratKg, Stabil, Pesan FROM WHS_GatewayJob WHERE JobId = @id", new { id });
            if (j.Status == "SELESAI") return Results.Ok(new { jobId = id, ok = true, beratKg = j.BeratKg, stabil = j.Stabil, pesan = j.Pesan });
            if (j.Status == "GAGAL") return Results.Json(new { message = j.Pesan ?? "Alat gagal merespons" }, statusCode: 502);
        }
        await db.ExecuteAsync("UPDATE WHS_GatewayJob SET Status = 'LEWAT', Pesan = N'Tidak ada respons' WHERE JobId = @id AND Status IN ('BARU','DIAMBIL')", new { id });
        return Results.Json(new { message = "Alat tidak merespons. Periksa PC gateway dan kabelnya." }, statusCode: 504);
    }

    // ------------------------------------------------------------------ untuk PC gateway (header X-Gateway-Key)
    public static void MapGateway(this IEndpointRouteBuilder app, Func<SqlConnection> dbf)
    {
        var g = app.MapGroup("/api/gateway");

        // Gateway memanggil ini berulang (long-poll ~20 dtk): sekaligus menandai "hidup" dan mengambil pekerjaan.
        g.MapPost("/poll", async (HttpRequest r, GatewayPoll body, CancellationToken ct) =>
        {
            await using var db = dbf();
            var gid = await Authenticate(db, r);
            if (gid is null) return Results.Unauthorized();
            await db.ExecuteAsync("UPDATE WHS_Gateway SET LastSeen = SYSDATETIME(), Versi = @v WHERE GatewayId = @g",
                new { g = gid, v = Trunc(body.Versi, 20) });
            await db.ExecuteAsync("UPDATE WHS_GatewayJob SET Status = 'LEWAT', Pesan = N'Kedaluwarsa' WHERE GatewayId = @g AND Status IN ('BARU','DIAMBIL') AND Dibuat < DATEADD(MINUTE, -2, SYSDATETIME())", new { g = gid });
            var sampai = DateTime.UtcNow.AddSeconds(20);
            while (!ct.IsCancellationRequested)
            {
                var jobs = (await db.QueryAsync<JobOut>(@"UPDATE TOP (5) WHS_GatewayJob SET Status = 'DIAMBIL', Diambil = SYSDATETIME()
                    OUTPUT INSERTED.JobId, INSERTED.Tipe, INSERTED.Target, INSERTED.Payload
                    WHERE GatewayId = @g AND Status = 'BARU'", new { g = gid })).ToList();
                if (jobs.Count > 0) return Results.Ok(new { jobs });
                if (DateTime.UtcNow >= sampai) return Results.Ok(new { jobs });
                try { await Task.Delay(500, ct); } catch (TaskCanceledException) { break; }
            }
            return Results.Ok(new { jobs = Array.Empty<JobOut>() });
        });

        g.MapPost("/hasil/{id:long}", async (long id, HttpRequest r, JobHasil h) =>
        {
            await using var db = dbf();
            var gid = await Authenticate(db, r);
            if (gid is null) return Results.Unauthorized();
            var n = await db.ExecuteAsync(@"UPDATE WHS_GatewayJob SET Status = @st, BeratKg = @b, Stabil = @s, Pesan = @p, Selesai = SYSDATETIME()
                WHERE JobId = @id AND GatewayId = @g AND Status = 'DIAMBIL'",
                new { id, g = gid, st = h.Ok ? "SELESAI" : "GAGAL", b = h.BeratKg, s = h.Stabil, p = Trunc(h.Pesan, 200) });
            return n == 1 ? Results.Ok() : Results.NotFound();
        });
    }

    static string? Trunc(string? s, int n) => s is null ? null : (s.Length <= n ? s : s[..n]);

    static async Task<string?> Authenticate(SqlConnection db, HttpRequest r)
    {
        var key = r.Headers["X-Gateway-Key"].ToString();
        var gid = r.Headers["X-Gateway-Id"].ToString();
        if (key.Length < 20 || key.Length > 200 || gid.Length is 0 or > 20) return null;
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))).ToLowerInvariant();
        var stored = await db.ExecuteScalarAsync<string?>("SELECT KeyHash FROM WHS_Gateway WHERE GatewayId = @gid AND Aktif = 1", new { gid });
        if (stored is null) return null;
        // perbandingan waktu-konstan
        return CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(stored.ToLowerInvariant()), Encoding.ASCII.GetBytes(hash)) ? gid : null;
    }

    record JobRow(string Status, decimal? BeratKg, bool? Stabil, string? Pesan);
}

public record TimbangReq(string? KodeTimbangan);
public record GatewayPoll(string? Versi);
public record JobOut(long JobId, string Tipe, string Target, string? Payload);
public record JobHasil(bool Ok, decimal? BeratKg, bool? Stabil, string? Pesan);

/// Isi label: QR + beberapa baris teks.
public record CetakReq(string? KodePrinter, string? Qr, List<string>? Baris, int? Salinan)
{
    public string? Validasi()
    {
        if (string.IsNullOrWhiteSpace(Qr) || Qr.Length > 200) return "Isi QR kosong atau terlalu panjang";
        if (Baris is { Count: > 5 }) return "Maksimal 5 baris teks";
        if (Baris is not null && Baris.Any(b => b.Length > 40)) return "Satu baris maksimal 40 karakter";
        if (Salinan is < 1 or > 50) return "Jumlah salinan 1-50";
        return null;
    }
}

/// Menyusun perintah TSPL (printer TSC). Ukuran label "LxT" dalam mm, 203 dpi (8 dot/mm).
public static class Tspl
{
    static string Q(string s) => s.Replace("\"", "'").Replace("\r", " ").Replace("\n", " ");

    public static string Label(CetakReq r, string ukuranMm)
    {
        var parts = ukuranMm.Split('x');
        int w = int.TryParse(parts[0], out var a) ? a : 100, h = parts.Length > 1 && int.TryParse(parts[1], out var b) ? b : 70;
        var sb = new StringBuilder();
        sb.Append($"SIZE {w} mm,{h} mm\r\nGAP 3 mm,0 mm\r\nDIRECTION 1\r\nCLS\r\n");
        var qrCell = Math.Max(3, Math.Min(8, h * 8 / 40));           // ukuran sel QR
        sb.Append($"QRCODE 24,24,M,{qrCell},A,0,M2,S7,\"{Q(r.Qr!)}\"\r\n");
        var x = 24 + qrCell * 33 + 24;                                // teks di kanan QR
        var y = 24;
        foreach (var line in r.Baris ?? new())
        {
            sb.Append($"TEXT {x},{y},\"2\",0,1,1,\"{Q(line)}\"\r\n");
            y += 36;
        }
        sb.Append($"PRINT 1,{r.Salinan ?? 1}\r\n");
        return sb.ToString();
    }
}
