using System.Security.Claims;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

public record JadwalItemReq(long PlanId, string? Eta, string? Dock);
public record JadwalReq(string WhsCode, DateTime Tgl, List<JadwalItemReq> Items);

public record JadwalSetup(decimal RateBongkar, decimal RateMuat, decimal PrepMenit, decimal GapMenit, int WsMenit, int WeMenit);
public record JadwalIn(long PlanId, string Jenis, decimal Kg, int? EtaMenit, string? Pin);
public record JadwalOut(long PlanId, string? Dock, int? Mulai, int? Selesai, int Durasi, int Tunggu, bool Lewat);

/// Penjadwalan bongkar muat: urut ETA, tiap kendaraan ke jalur yang paling cepat kosong (atau jalur yang dipin Admin).
/// Durasi = CEILING((persiapan + kg / kecepatan * 60) / 5) * 5 menit. Kecepatan, persiapan, jeda, jam kerja dari WHS_Setup.
public static class JadwalHitung
{
    public static int Durasi(JadwalSetup s, string jenis, decimal kg)
    {
        var rate = jenis == "SPBB" ? s.RateBongkar : s.RateMuat;
        return (int)(Math.Ceiling((double)(s.PrepMenit + kg / rate * 60m) / 5.0) * 5);
    }

    public static List<JadwalOut> Hitung(JadwalSetup s, List<string> docks, List<JadwalIn> items)
    {
        var free = docks.ToDictionary(d => d, _ => s.WsMenit);
        var res = new Dictionary<long, JadwalOut>();
        foreach (var it in items.Where(i => i.EtaMenit is null)) res[it.PlanId] = new JadwalOut(it.PlanId, null, null, null, Durasi(s, it.Jenis, it.Kg), 0, false);
        foreach (var it in items.Where(i => i.EtaMenit is not null).OrderBy(i => i.EtaMenit).ThenBy(i => i.PlanId))
        {
            var dur = Durasi(s, it.Jenis, it.Kg);
            var cand = it.Pin is not null && free.ContainsKey(it.Pin) ? new List<string> { it.Pin } : docks;
            string? bestK = null; var bestSt = int.MaxValue;
            foreach (var k in cand)
            {
                var st = Math.Max(Math.Max(it.EtaMenit!.Value, free[k]), s.WsMenit);
                if (st < bestSt) { bestSt = st; bestK = k; }
            }
            if (bestK is null) { res[it.PlanId] = new JadwalOut(it.PlanId, null, null, null, dur, 0, false); continue; }
            var en = bestSt + dur;
            res[it.PlanId] = new JadwalOut(it.PlanId, bestK, bestSt, en, dur, bestSt - Math.Max(it.EtaMenit!.Value, s.WsMenit), en > s.WeMenit);
            free[bestK] = en + (int)Math.Ceiling(s.GapMenit);
        }
        return items.Select(i => res[i.PlanId]).ToList();
    }
}

public static class JadwalEndpoints
{
    static IResult Bad(string m) => Results.BadRequest(new { message = m });

    static int? HM(string? s)
    {
        var m = Regex.Match((s ?? "").Trim(), @"^([01]\d|2[0-3]):([0-5]\d)$");
        return m.Success ? int.Parse(m.Groups[1].Value) * 60 + int.Parse(m.Groups[2].Value) : null;
    }

    static async Task<JadwalSetup> LoadSetup(SqlConnection db)
    {
        var d = (await db.QueryAsync<(string Kode, decimal Nilai)>("SELECT Kode, Nilai FROM WHS_Setup")).ToDictionary(x => x.Kode, x => x.Nilai);
        decimal G(string k, decimal def) => d.TryGetValue(k, out var v) ? v : def;
        return new JadwalSetup(G("KECEPATAN_BONGKAR_KGJAM", 12000), G("KECEPATAN_MUAT_KGJAM", 15000), G("PERSIAPAN_MENIT", 15), G("JEDA_MENIT", 10), (int)G("JAM_KERJA_MULAI", 480), (int)G("JAM_KERJA_SELESAI", 1020));
    }

    public static void MapJadwal(this RouteGroupBuilder cms, Func<SqlConnection> dbf)
    {
        // Data awal: jalur, setup, dan plan aktif pada tanggal itu (belum ada SPBB/SPMB tanpa TglJadwal: tidak tampil)
        cms.MapGet("/jadwal", async (string whs, DateTime tgl, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @whs", new { uid = u.UserId(), whs }) == 0) return Results.Forbid();
            var setup = await LoadSetup(db);
            var docks = (await db.QueryAsync<string>("SELECT DockCode FROM WHS_MasterDock WHERE WhsCode = @whs AND Aktif = 1 ORDER BY DockCode", new { whs })).ToList();
            var plans = (await db.QueryAsync(@"
SELECT p.PlanId AS planId, p.PlanNo AS planNo, p.Jenis AS jenis, p.CardName AS party, p.Status AS status,
       ISNULL((SELECT SUM(QtyPlan - QtyDone) FROM WHS_Plan1 WHERE PlanId = p.PlanId), 0) AS kg,
       CONVERT(char(5), p.EtaDatang, 108) AS eta, p.DockCode AS dock, p.DockDipin AS dockDipin, p.JadwalMulai AS jadwalMulai, p.JadwalSelesai AS jadwalSelesai, p.JadwalDikirimAt AS dikirimAt,
       k.NoPolisi AS noPolisi, k.ContainerNo AS containerNo, CONVERT(char(5), k.JamMasuk, 108) AS aktualMasuk
FROM WHS_Plan p OUTER APPLY (SELECT TOP 1 NoPolisi, ContainerNo, JamMasuk FROM WHS_Kendaraan WHERE PlanId = p.PlanId AND Status <> 'Batal' ORDER BY RegId DESC) k
WHERE p.WhsCode = @whs AND p.TglJadwal = @tgl AND p.Status IN ('Terbit','Proses','Partial') ORDER BY p.EtaDatang, p.PlanId",
                new { whs, tgl = tgl.Date })).ToList();
            return Results.Ok(new { setup, docks, plans });
        });

        // Hitung ulang tanpa menyimpan (dipakai layar saat Admin mengubah ETA/jalur)
        cms.MapPost("/jadwal/hitung", async (JadwalReq r, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var (err, outs) = await Proses(db, r, u);
            return err is not null ? Bad(err) : Results.Ok(outs);
        });

        // Terapkan: simpan ETA, jalur, durasi, jam; tandai dikirim ke krani
        cms.MapPost("/jadwal/terapkan", async (JadwalReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            var (err, outs) = await Proses(db, r, u);
            if (err is not null) return Bad(err);
            if (outs!.Any(o => o.Dock is null)) return Bad("Ada kendaraan tanpa ETA yang valid atau tanpa jalur");
            if (outs!.Any(o => o.Lewat)) return Bad("Ada jadwal yang selesai melewati jam kerja. Ubah ETA/jalur dulu.");
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync();
            foreach (var o in outs!)
            {
                var it = r.Items.First(i => i.PlanId == o.PlanId);
                var tgl = r.Tgl.Date;
                await db.ExecuteAsync(@"UPDATE WHS_Plan SET EtaDatang = @eta, DockCode = @dock, DockDipin = @pin, DurasiMenit = @dur,
                    JadwalMulai = DATEADD(MINUTE, @mulai, @tgl), JadwalSelesai = DATEADD(MINUTE, @selesai, @tgl),
                    JadwalCatatan = @cat, JadwalDikirimAt = SYSDATETIME() WHERE PlanId = @id",
                    new
                    {
                        id = o.PlanId, eta = TimeSpan.FromMinutes(HM(it.Eta)!.Value), dock = o.Dock, pin = !string.IsNullOrWhiteSpace(it.Dock) && it.Dock != "auto",
                        dur = o.Durasi, mulai = o.Mulai, selesai = o.Selesai, tgl, cat = o.Tunggu > 0 ? $"Menunggu jalur {o.Tunggu} menit" : "Langsung dikerjakan",
                    }, tx);
            }
            await Audit.Write(db, tx, u, ctx, "JADWAL_TERAPKAN", "JADWAL", null, $"{r.WhsCode} {r.Tgl:yyyy-MM-dd} {outs!.Count} jadwal");
            await tx.CommitAsync();
            return Results.Ok(outs);
        });
    }

    static async Task<(string? err, List<JadwalOut>? outs)> Proses(SqlConnection db, JadwalReq r, ClaimsPrincipal u)
    {
        if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @whs", new { uid = u.UserId(), whs = r.WhsCode }) == 0) return ("Tidak punya akses ke warehouse ini", null);
        if (r.Items is null || r.Items.Count == 0 || r.Items.Count > 200) return ("Tidak ada jadwal", null);
        var setup = await LoadSetup(db);
        var docks = (await db.QueryAsync<string>("SELECT DockCode FROM WHS_MasterDock WHERE WhsCode = @whs AND Aktif = 1 ORDER BY DockCode", new { whs = r.WhsCode })).ToList();
        if (docks.Count == 0) return ("Belum ada jalur aktif di warehouse ini (Master Jalur)", null);
        var ids = r.Items.Select(i => i.PlanId).Distinct().ToList();
        var rows = (await db.QueryAsync<(long PlanId, string Jenis, decimal Kg)>(@"SELECT p.PlanId, p.Jenis, ISNULL((SELECT SUM(QtyPlan - QtyDone) FROM WHS_Plan1 WHERE PlanId = p.PlanId), 0) AS Kg
            FROM WHS_Plan p WHERE p.PlanId IN @ids AND p.WhsCode = @whs AND p.Status IN ('Terbit','Proses','Partial')", new { ids, whs = r.WhsCode })).ToDictionary(x => x.PlanId);
        var ins = new List<JadwalIn>();
        foreach (var it in r.Items)
        {
            if (!rows.TryGetValue(it.PlanId, out var p)) return ($"Dokumen {it.PlanId} tidak aktif di warehouse ini", null);
            var eta = HM(it.Eta);
            if (!string.IsNullOrWhiteSpace(it.Eta) && eta is null) return ("ETA format JJ:MM", null);
            var pin = string.IsNullOrWhiteSpace(it.Dock) || it.Dock == "auto" ? null : it.Dock;
            if (pin is not null && !docks.Contains(pin)) return ($"Jalur {pin} tidak aktif", null);
            ins.Add(new JadwalIn(it.PlanId, p.Jenis, p.Kg, eta, pin));
        }
        return (null, JadwalHitung.Hitung(setup, docks, ins));
    }
}
