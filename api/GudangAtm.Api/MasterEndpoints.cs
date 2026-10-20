using System.Data;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

public record SetupItem(string Kode, decimal Nilai);
public record SetupSave(List<SetupItem> Items);
public record RuanganReq(string? KodeRuangan, string? WhsCode, string? NamaRuangan, decimal KapasitasTon, bool Titipan, bool Aktif = true);
public record PaletReq(string? PaletCode, decimal PanjangCm, decimal LebarCm, decimal TinggiCm, decimal BeratKg, bool Aktif = true);
public record JenisContainerReq(string? Kode, string? Nama, decimal BatasMuatanKg, bool Aktif = true);
public record DockReq(string? DockCode, string? WhsCode, string? Nama, bool Aktif = true);
public record TimbanganReq(string? KodeTimbangan, string? WhsCode, string? Alat, string? Lokasi, string? AlamatLan, string? GatewayId, decimal? TolOverridePct, bool Aktif = true);
public record PrinterReq(string? KodePrinter, string? WhsCode, string? GatewayId, string? Lokasi, string? UkuranMm, bool Aktif = true);
public record GatewayReq(string? GatewayId, string? WhsCode, string? Keterangan, bool Aktif = true);

/// Master data Gudang ATM (CMS Admin): Setup toleransi/jadwal, Ruangan, Palet, Jenis Container, Jalur (dock), Timbangan, Printer, Gateway.
public static partial class MasterEndpoints
{
    static IResult Bad(string m) => Results.BadRequest(new { message = m });
    static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    [GeneratedRegex(@"^[A-Z0-9][A-Z0-9\-]{2,29}$")] private static partial Regex KodeRx();
    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9\-]{1,19}$")] private static partial Regex KodeKecilRx();

    public static async Task<bool> WhsAda(SqlConnection db, string? whs) =>
        !string.IsNullOrWhiteSpace(whs) && await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM OWHS WHERE WhsCode = @whs", new { whs }) > 0;

    // Batas wajar tiap nilai Setup. Kunci tak dikenal ditolak.
    static readonly Dictionary<string, (decimal min, decimal max)> SetupRange = new()
    {
        ["SUSUT_WARN_PCT"] = (0.01m, 100), ["KOREKSI_WARN_PCT"] = (0.01m, 100),
        ["REPACK_OK_PCT"] = (0.01m, 100), ["REPACK_WARN_PCT"] = (0.01m, 100),
        ["TARA_DEV_PCT"] = (0.01m, 100), ["BRUTO_MAX_KG"] = (1000, 200000), ["TARA_MAX_KG"] = (1000, 100000),
        ["NET_TOL_PCT"] = (0.01m, 100), ["NET_ADMIN_PCT"] = (0.01m, 100),
        ["KECEPATAN_BONGKAR_KGJAM"] = (100, 200000), ["KECEPATAN_MUAT_KGJAM"] = (100, 200000),
        ["PERSIAPAN_MENIT"] = (0.01m, 600), ["JEDA_MENIT"] = (0.01m, 600),
        ["JAM_KERJA_MULAI"] = (0.01m, 1439), ["JAM_KERJA_SELESAI"] = (1, 1440),
    };

    public static void MapMaster(this RouteGroupBuilder cms, Func<SqlConnection> dbf)
    {
        // ------------------------------------------------------------ Setup
        cms.MapGet("/setup", async () =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync("SELECT Kode AS kode, Nilai AS nilai, Keterangan AS keterangan, UpdatedAt AS updatedAt FROM WHS_Setup ORDER BY Kode"));
        });

        cms.MapPut("/setup", async (SetupSave req, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (req.Items is null || req.Items.Count == 0 || req.Items.Count > 50) return Bad("Tidak ada nilai untuk disimpan");
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync();
            var cur = (await db.QueryAsync<(string Kode, decimal Nilai)>("SELECT Kode, Nilai FROM WHS_Setup", transaction: tx)).ToDictionary(x => x.Kode, x => x.Nilai);
            foreach (var it in req.Items)
            {
                if (!SetupRange.TryGetValue(it.Kode ?? "", out var r)) return Bad($"Setup {it.Kode} tidak dikenal");
                if (it.Nilai < r.min || it.Nilai > r.max) return Bad($"{it.Kode}: nilai harus {r.min}-{r.max}");
                cur[it.Kode!] = it.Nilai;
            }
            // aturan antar nilai
            if (cur.TryGetValue("JAM_KERJA_MULAI", out var ws) && cur.TryGetValue("JAM_KERJA_SELESAI", out var we) && we <= ws) return Bad("Jam kerja selesai harus setelah jam mulai");
            if (cur.TryGetValue("REPACK_OK_PCT", out var ro) && cur.TryGetValue("REPACK_WARN_PCT", out var rw) && rw <= ro) return Bad("Batas peringatan Repacking harus lebih besar dari batas wajar");
            if (cur.TryGetValue("NET_TOL_PCT", out var nt) && cur.TryGetValue("NET_ADMIN_PCT", out var na) && na <= nt) return Bad("Batas butuh kode Admin harus lebih besar dari batas wajar net");
            foreach (var it in req.Items)
                await db.ExecuteAsync("UPDATE WHS_Setup SET Nilai = @n, UpdatedBy = @u, UpdatedAt = SYSDATETIME() WHERE Kode = @k", new { n = it.Nilai, u = u.UserId(), k = it.Kode }, tx);
            await Audit.Write(db, tx, u, ctx, "SETUP_SAVE", "SETUP", null, string.Join("; ", req.Items.Select(i => $"{i.Kode}={i.Nilai}")));
            await tx.CommitAsync();
            return Results.Ok();
        });

        // ------------------------------------------------------------ Ruangan
        cms.MapGet("/master/ruangan", async (string? whs) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(@"
SELECT r.KodeRuangan AS kodeRuangan, r.WhsCode AS whsCode, w.WhsName AS whsName, r.NamaRuangan AS namaRuangan,
       r.KapasitasTon AS kapasitasTon, r.Titipan AS titipan, r.Aktif AS aktif,
       (SELECT COUNT(*) FROM KRN1 k WHERE k.KodeRuangan = r.KodeRuangan)
     + (SELECT COUNT(*) FROM WHS_Plan p WHERE p.KodeRuangan = r.KodeRuangan)
     + (SELECT COUNT(*) FROM WHS_Plan1 p1 WHERE p1.KodeRuangan = r.KodeRuangan) AS dipakai
FROM WHS_MasterRuangan r LEFT JOIN OWHS w ON w.WhsCode = r.WhsCode
WHERE (@whs IS NULL OR r.WhsCode = @whs) ORDER BY r.WhsCode, r.KodeRuangan", new { whs = Clean(whs) }));
        });

        cms.MapPost("/master/ruangan", async (RuanganReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var kode = (r.KodeRuangan ?? "").Trim().ToUpperInvariant();
            if (!KodeRx().IsMatch(kode)) return Bad("Kode ruangan 3-30 karakter: huruf besar, angka, strip");
            if (string.IsNullOrWhiteSpace(r.NamaRuangan) || r.NamaRuangan.Length > 100) return Bad("Nama ruangan wajib (maks 100 karakter)");
            if (r.KapasitasTon < 0 || r.KapasitasTon > 1_000_000) return Bad("Kapasitas tidak valid (0 = tanpa batas)");
            await using var db = dbf();
            if (!await WhsAda(db, r.WhsCode)) return Bad("Warehouse tidak ditemukan");
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_MasterRuangan WHERE KodeRuangan = @kode", new { kode }) > 0) return Bad("Kode ruangan sudah ada");
            await db.ExecuteAsync(@"INSERT WHS_MasterRuangan (KodeRuangan, WhsCode, NamaRuangan, KapasitasTon, Titipan, Aktif, CreatedBy)
                VALUES (@kode, @whs, @nama, @kap, @tit, 1, @u)", new { kode, whs = r.WhsCode, nama = r.NamaRuangan!.Trim(), kap = r.KapasitasTon, tit = r.Titipan, u = u.UserId() });
            await Audit.Safe(db, u, ctx, "MST_RUANGAN", "RUANGAN", null, $"buat {kode} titipan={r.Titipan}");
            return Results.Ok(new { kodeRuangan = kode });
        });

        cms.MapPut("/master/ruangan/{kode}", async (string kode, RuanganReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (string.IsNullOrWhiteSpace(r.NamaRuangan) || r.NamaRuangan.Length > 100) return Bad("Nama ruangan wajib (maks 100 karakter)");
            if (r.KapasitasTon < 0 || r.KapasitasTon > 1_000_000) return Bad("Kapasitas tidak valid");
            await using var db = dbf();
            var cur = await db.QueryFirstOrDefaultAsync<(bool Titipan, bool Aktif)?>("SELECT Titipan, Aktif FROM WHS_MasterRuangan WHERE KodeRuangan = @kode", new { kode });
            if (cur is null) return Results.NotFound(new { message = "Ruangan tidak ditemukan" });
            var dipakai = await db.ExecuteScalarAsync<int>(@"SELECT (SELECT COUNT(*) FROM KRN1 WHERE KodeRuangan = @kode) + (SELECT COUNT(*) FROM WHS_Plan WHERE KodeRuangan = @kode) + (SELECT COUNT(*) FROM WHS_Plan1 WHERE KodeRuangan = @kode)", new { kode });
            if (cur.Value.Titipan != r.Titipan && dipakai > 0) return Bad("Tanda titipan tidak bisa diubah: ruangan sudah dipakai transaksi");
            if (cur.Value.Aktif && !r.Aktif)
            {
                var stok = await db.ExecuteScalarAsync<decimal?>(@"SELECT SUM(d.qty * d.flags) FROM KRN1 d JOIN OKRN h ON h.ObjType = d.ObjType AND h.DocEntry = d.DocEntry
                    WHERE h.DocStatus = 'C' AND d.KodeRuangan = @kode", new { kode }) ?? 0;
                if (stok > 0) return Bad($"Ruangan masih berisi barang ({stok:N0} kg), tidak boleh dinonaktifkan");
                var plan = await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_Plan WHERE KodeRuangan = @kode AND Status IN ('Terbit','Proses','Partial')", new { kode });
                if (plan > 0) return Bad("Masih ada SPBB/SPMB aktif memakai ruangan ini");
            }
            await db.ExecuteAsync(@"UPDATE WHS_MasterRuangan SET NamaRuangan = @nama, KapasitasTon = @kap, Titipan = @tit, Aktif = @aktif, UpdatedBy = @u, UpdatedAt = SYSDATETIME() WHERE KodeRuangan = @kode",
                new { kode, nama = r.NamaRuangan!.Trim(), kap = r.KapasitasTon, tit = r.Titipan, aktif = r.Aktif, u = u.UserId() });
            await Audit.Safe(db, u, ctx, "MST_RUANGAN", "RUANGAN", null, $"ubah {kode} titipan={r.Titipan} aktif={r.Aktif}");
            return Results.Ok();
        });

        // ------------------------------------------------------------ Palet
        cms.MapGet("/master/palet", async () => { await using var db = dbf(); return Results.Ok(await db.QueryAsync("SELECT PaletCode AS paletCode, PanjangCm AS panjangCm, LebarCm AS lebarCm, TinggiCm AS tinggiCm, BeratKg AS beratKg, Aktif AS aktif FROM WHS_MasterPalet ORDER BY PaletCode")); });
        cms.MapPost("/master/palet", async (PaletReq p, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var kode = (p.PaletCode ?? "").Trim().ToUpperInvariant();
            if (!KodeKecilRx().IsMatch(kode)) return Bad("Kode palet 2-20 karakter (huruf, angka, strip)");
            var err = ValidPalet(p); if (err is not null) return Bad(err);
            await using var db = dbf();
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_MasterPalet WHERE PaletCode = @kode", new { kode }) > 0) return Bad("Kode palet sudah ada");
            await db.ExecuteAsync("INSERT WHS_MasterPalet (PaletCode, PanjangCm, LebarCm, TinggiCm, BeratKg, Aktif) VALUES (@kode, @pj, @lb, @tg, @br, 1)", new { kode, pj = p.PanjangCm, lb = p.LebarCm, tg = p.TinggiCm, br = p.BeratKg });
            await Audit.Safe(db, u, ctx, "MST_PALET", "PALET", null, $"buat {kode} {p.BeratKg} kg");
            return Results.Ok();
        });
        cms.MapPut("/master/palet/{kode}", async (string kode, PaletReq p, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var err = ValidPalet(p); if (err is not null) return Bad(err);
            await using var db = dbf();
            var n = await db.ExecuteAsync("UPDATE WHS_MasterPalet SET PanjangCm = @pj, LebarCm = @lb, TinggiCm = @tg, BeratKg = @br, Aktif = @a WHERE PaletCode = @kode", new { kode, pj = p.PanjangCm, lb = p.LebarCm, tg = p.TinggiCm, br = p.BeratKg, a = p.Aktif });
            if (n == 0) return Results.NotFound(new { message = "Palet tidak ditemukan" });
            await Audit.Safe(db, u, ctx, "MST_PALET", "PALET", null, $"ubah {kode} {p.BeratKg} kg aktif={p.Aktif}");
            return Results.Ok();
        });

        // ------------------------------------------------------------ Jenis container
        cms.MapGet("/master/jenis-container", async () => { await using var db = dbf(); return Results.Ok(await db.QueryAsync("SELECT Kode AS kode, Nama AS nama, BatasMuatanKg AS batasMuatanKg, Aktif AS aktif FROM WHS_MasterJenisContainer ORDER BY Kode")); });
        cms.MapPut("/master/jenis-container/{kode}", async (string kode, JenisContainerReq j, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (string.IsNullOrWhiteSpace(j.Nama) || j.Nama.Length > 60) return Bad("Nama wajib (maks 60 karakter)");
            if (j.BatasMuatanKg <= 0 || j.BatasMuatanKg > 100_000) return Bad("Batas muatan tidak valid");
            await using var db = dbf();
            var n = await db.ExecuteAsync("UPDATE WHS_MasterJenisContainer SET Nama = @nama, BatasMuatanKg = @b, Aktif = @a WHERE Kode = @kode", new { kode, nama = j.Nama.Trim(), b = j.BatasMuatanKg, a = j.Aktif });
            if (n == 0) return Results.NotFound(new { message = "Jenis container tidak ditemukan" });
            await Audit.Safe(db, u, ctx, "MST_CONTAINER", "JENISCONT", null, $"{kode} batas={j.BatasMuatanKg}");
            return Results.Ok();
        });

        // ------------------------------------------------------------ Jalur (dock)
        cms.MapGet("/master/dock", async (string? whs) => { await using var db = dbf(); return Results.Ok(await db.QueryAsync("SELECT DockCode AS dockCode, WhsCode AS whsCode, Nama AS nama, Aktif AS aktif FROM WHS_MasterDock WHERE (@whs IS NULL OR WhsCode = @whs) ORDER BY WhsCode, DockCode", new { whs = Clean(whs) })); });
        cms.MapPost("/master/dock", async (DockReq d, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var kode = (d.DockCode ?? "").Trim().ToUpperInvariant();
            if (!KodeKecilRx().IsMatch(kode)) return Bad("Kode jalur 2-20 karakter (huruf, angka, strip)");
            if (string.IsNullOrWhiteSpace(d.Nama) || d.Nama.Length > 50) return Bad("Nama jalur wajib (maks 50 karakter)");
            await using var db = dbf();
            if (!await WhsAda(db, d.WhsCode)) return Bad("Warehouse tidak ditemukan");
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_MasterDock WHERE DockCode = @kode", new { kode }) > 0) return Bad("Kode jalur sudah ada");
            await db.ExecuteAsync("INSERT WHS_MasterDock (DockCode, WhsCode, Nama, UpdatedBy) VALUES (@kode, @whs, @nama, @u)", new { kode, whs = d.WhsCode, nama = d.Nama.Trim(), u = u.UserId() });
            await Audit.Safe(db, u, ctx, "MST_DOCK", "DOCK", null, $"buat {kode}");
            return Results.Ok();
        });
        cms.MapPut("/master/dock/{kode}", async (string kode, DockReq d, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (string.IsNullOrWhiteSpace(d.Nama) || d.Nama.Length > 50) return Bad("Nama jalur wajib (maks 50 karakter)");
            await using var db = dbf();
            if (!d.Aktif && await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_Plan WHERE DockCode = @kode AND Status IN ('Terbit','Proses','Partial') AND TglJadwal >= CAST(GETDATE() AS date)", new { kode }) > 0)
                return Bad("Jalur masih dipakai jadwal yang belum selesai");
            var n = await db.ExecuteAsync("UPDATE WHS_MasterDock SET Nama = @nama, Aktif = @a, UpdatedBy = @u, UpdatedAt = SYSDATETIME() WHERE DockCode = @kode", new { kode, nama = d.Nama.Trim(), a = d.Aktif, u = u.UserId() });
            if (n == 0) return Results.NotFound(new { message = "Jalur tidak ditemukan" });
            await Audit.Safe(db, u, ctx, "MST_DOCK", "DOCK", null, $"ubah {kode} aktif={d.Aktif}");
            return Results.Ok();
        });

        // ------------------------------------------------------------ Timbangan
        cms.MapGet("/master/timbangan", async (string? whs) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(@"SELECT KodeTimbangan AS kodeTimbangan, WhsCode AS whsCode, Alat AS alat, Lokasi AS lokasi, AlamatLan AS alamatLan,
                GatewayId AS gatewayId, TolOverridePct AS tolOverridePct, Aktif AS aktif FROM WHS_MasterTimbangan WHERE (@whs IS NULL OR WhsCode = @whs) ORDER BY WhsCode, KodeTimbangan", new { whs = Clean(whs) }));
        });
        cms.MapPost("/master/timbangan", async (TimbanganReq t, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var kode = (t.KodeTimbangan ?? "").Trim().ToUpperInvariant();
            if (!Regex.IsMatch(kode, @"^[A-Z0-9\-]{2,10}$")) return Bad("Kode timbangan 2-10 karakter (mis. TP-01)");
            await using var db = dbf();
            var err = await ValidTimbangan(db, t); if (err is not null) return Bad(err);
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_MasterTimbangan WHERE KodeTimbangan = @kode", new { kode }) > 0) return Bad("Kode timbangan sudah ada");
            await db.ExecuteAsync(@"INSERT WHS_MasterTimbangan (KodeTimbangan, WhsCode, Alat, Lokasi, AlamatLan, GatewayId, TolOverridePct, Aktif) VALUES (@kode, @whs, @alat, @lok, @lan, @gw, @tol, 1)",
                new { kode, whs = t.WhsCode, alat = t.Alat, lok = Clean(t.Lokasi), lan = t.AlamatLan!.Trim(), gw = Clean(t.GatewayId), tol = t.TolOverridePct });
            await Audit.Safe(db, u, ctx, "MST_TIMBANGAN", "TIMBANGAN", null, $"buat {kode}");
            return Results.Ok();
        });
        cms.MapPut("/master/timbangan/{kode}", async (string kode, TimbanganReq t, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            var err = await ValidTimbangan(db, t); if (err is not null) return Bad(err);
            var n = await db.ExecuteAsync(@"UPDATE WHS_MasterTimbangan SET WhsCode = @whs, Alat = @alat, Lokasi = @lok, AlamatLan = @lan, GatewayId = @gw, TolOverridePct = @tol, Aktif = @a WHERE KodeTimbangan = @kode",
                new { kode, whs = t.WhsCode, alat = t.Alat, lok = Clean(t.Lokasi), lan = t.AlamatLan!.Trim(), gw = Clean(t.GatewayId), tol = t.TolOverridePct, a = t.Aktif });
            if (n == 0) return Results.NotFound(new { message = "Timbangan tidak ditemukan" });
            await Audit.Safe(db, u, ctx, "MST_TIMBANGAN", "TIMBANGAN", null, $"ubah {kode} aktif={t.Aktif}");
            return Results.Ok();
        });

        // ------------------------------------------------------------ Printer
        cms.MapGet("/master/printer", async (string? whs) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync("SELECT KodePrinter AS kodePrinter, WhsCode AS whsCode, GatewayId AS gatewayId, Lokasi AS lokasi, UkuranMm AS ukuranMm, Aktif AS aktif FROM WHS_MasterPrinter WHERE (@whs IS NULL OR WhsCode = @whs) ORDER BY WhsCode, KodePrinter", new { whs = Clean(whs) }));
        });
        cms.MapPost("/master/printer", async (PrinterReq p, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var kode = (p.KodePrinter ?? "").Trim().ToUpperInvariant();
            if (!Regex.IsMatch(kode, @"^[A-Z0-9\-]{2,10}$")) return Bad("Kode printer 2-10 karakter (mis. LP-01)");
            await using var db = dbf();
            var err = await ValidPrinter(db, p); if (err is not null) return Bad(err);
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_MasterPrinter WHERE KodePrinter = @kode", new { kode }) > 0) return Bad("Kode printer sudah ada");
            await db.ExecuteAsync("INSERT WHS_MasterPrinter (KodePrinter, WhsCode, GatewayId, Lokasi, UkuranMm, Aktif) VALUES (@kode, @whs, @gw, @lok, @uk, 1)",
                new { kode, whs = p.WhsCode, gw = p.GatewayId, lok = Clean(p.Lokasi), uk = p.UkuranMm });
            await Audit.Safe(db, u, ctx, "MST_PRINTER", "PRINTER", null, $"buat {kode}");
            return Results.Ok();
        });
        cms.MapPut("/master/printer/{kode}", async (string kode, PrinterReq p, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            var err = await ValidPrinter(db, p); if (err is not null) return Bad(err);
            var n = await db.ExecuteAsync("UPDATE WHS_MasterPrinter SET WhsCode = @whs, GatewayId = @gw, Lokasi = @lok, UkuranMm = @uk, Aktif = @a WHERE KodePrinter = @kode",
                new { kode, whs = p.WhsCode, gw = p.GatewayId, lok = Clean(p.Lokasi), uk = p.UkuranMm, a = p.Aktif });
            if (n == 0) return Results.NotFound(new { message = "Printer tidak ditemukan" });
            await Audit.Safe(db, u, ctx, "MST_PRINTER", "PRINTER", null, $"ubah {kode} aktif={p.Aktif}");
            return Results.Ok();
        });

        // ------------------------------------------------------------ Gateway (PC gudang)
        cms.MapGet("/master/gateway", async () =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync("SELECT GatewayId AS gatewayId, WhsCode AS whsCode, Keterangan AS keterangan, Aktif AS aktif, LastSeen AS lastSeen, Versi AS versi, CAST(CASE WHEN LastSeen > DATEADD(SECOND, -60, SYSDATETIME()) THEN 1 ELSE 0 END AS bit) AS online FROM WHS_Gateway ORDER BY GatewayId"));
        });
        // Key dibuat acak di server dan ditampilkan SEKALI; yang disimpan hanya hash SHA-256.
        cms.MapPost("/master/gateway", async (GatewayReq g, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var id = (g.GatewayId ?? "").Trim().ToUpperInvariant();
            if (!Regex.IsMatch(id, @"^[A-Z0-9\-]{3,20}$")) return Bad("ID gateway 3-20 karakter (mis. GW-JKT01)");
            await using var db = dbf();
            if (!await WhsAda(db, g.WhsCode)) return Bad("Warehouse tidak ditemukan");
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_Gateway WHERE GatewayId = @id", new { id }) > 0) return Bad("ID gateway sudah ada");
            var key = NewKey();
            await db.ExecuteAsync("INSERT WHS_Gateway (GatewayId, WhsCode, Keterangan, KeyHash) VALUES (@id, @whs, @ket, @h)", new { id, whs = g.WhsCode, ket = Clean(g.Keterangan), h = Hash(key) });
            await Audit.Safe(db, u, ctx, "MST_GATEWAY", "GATEWAY", null, $"buat {id}");
            return Results.Ok(new { gatewayId = id, apiKey = key, catatan = "Simpan key ini sekarang. Tidak bisa ditampilkan lagi." });
        });
        cms.MapPost("/master/gateway/{id}/key-baru", async (string id, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            var key = NewKey();
            var n = await db.ExecuteAsync("UPDATE WHS_Gateway SET KeyHash = @h WHERE GatewayId = @id", new { id, h = Hash(key) });
            if (n == 0) return Results.NotFound(new { message = "Gateway tidak ditemukan" });
            await Audit.Safe(db, u, ctx, "MST_GATEWAY", "GATEWAY", null, $"key baru {id}");
            return Results.Ok(new { gatewayId = id, apiKey = key, catatan = "Key lama tidak berlaku lagi. Pasang key baru di PC gudang." });
        });
        cms.MapPut("/master/gateway/{id}", async (string id, GatewayReq g, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            var n = await db.ExecuteAsync("UPDATE WHS_Gateway SET Keterangan = @ket, Aktif = @a WHERE GatewayId = @id", new { id, ket = Clean(g.Keterangan), a = g.Aktif });
            if (n == 0) return Results.NotFound(new { message = "Gateway tidak ditemukan" });
            await Audit.Safe(db, u, ctx, "MST_GATEWAY", "GATEWAY", null, $"ubah {id} aktif={g.Aktif}");
            return Results.Ok();
        });
    }

    // Master untuk krani (hanya baca): ruangan, palet, jenis container, setup yang dipakai aplikasi.
    public static void MapMasterBaca(this RouteGroupBuilder api, Func<SqlConnection> dbf)
    {
        api.MapGet("/master/ruangan", async (string whs, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @whs", new { uid = u.UserId(), whs }) == 0) return Results.Forbid();
            return Results.Ok(await db.QueryAsync("SELECT KodeRuangan AS kodeRuangan, NamaRuangan AS namaRuangan, KapasitasTon AS kapasitasTon, Titipan AS titipan FROM WHS_MasterRuangan WHERE WhsCode = @whs AND Aktif = 1 ORDER BY KodeRuangan", new { whs }));
        });
        api.MapGet("/master/palet", async () => { await using var db = dbf(); return Results.Ok(await db.QueryAsync("SELECT PaletCode AS paletCode, BeratKg AS beratKg FROM WHS_MasterPalet WHERE Aktif = 1 ORDER BY PaletCode")); });
        api.MapGet("/master/setup", async () => { await using var db = dbf(); return Results.Ok(await db.QueryAsync("SELECT Kode AS kode, Nilai AS nilai FROM WHS_Setup")); });
    }

    static string? ValidPalet(PaletReq p)
    {
        if (p.PanjangCm <= 0 || p.LebarCm <= 0 || p.TinggiCm <= 0 || p.PanjangCm > 500 || p.LebarCm > 500 || p.TinggiCm > 500) return "Ukuran palet tidak valid (cm)";
        if (p.BeratKg <= 0 || p.BeratKg > 500) return "Berat palet tidak valid (kg)";
        return null;
    }

    static async Task<string?> ValidTimbangan(SqlConnection db, TimbanganReq t)
    {
        if (!await WhsAda(db, t.WhsCode)) return "Warehouse tidak ditemukan";
        if (t.Alat is not ("KENDARAAN" or "PALET")) return "Alat harus KENDARAAN atau PALET";
        if (string.IsNullOrWhiteSpace(t.AlamatLan) || t.AlamatLan.Length > 30) return "Alamat/port indikator wajib (mis. COM3 atau 192.168.1.52:4001)";
        if (t.TolOverridePct is <= 0 or > 100) return "Toleransi override harus 0-100 persen (kosong = pakai Setup)";
        if (Clean(t.GatewayId) is { } g && await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_Gateway WHERE GatewayId = @g", new { g }) == 0) return "Gateway tidak ditemukan";
        return null;
    }

    static async Task<string?> ValidPrinter(SqlConnection db, PrinterReq p)
    {
        if (!await WhsAda(db, p.WhsCode)) return "Warehouse tidak ditemukan";
        if (string.IsNullOrWhiteSpace(p.GatewayId) || await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_Gateway WHERE GatewayId = @g", new { g = p.GatewayId }) == 0) return "Pilih gateway yang valid";
        if (!Regex.IsMatch(p.UkuranMm ?? "", @"^\d{2,3}x\d{2,3}$")) return "Ukuran label format LxT mm (mis. 100x70)";
        return null;
    }

    static string NewKey() => Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
    static string Hash(string key) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))).ToLowerInvariant();
}
