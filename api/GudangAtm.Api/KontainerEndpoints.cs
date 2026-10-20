using System.Security.Claims;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

public record SamplingLine(int PlanLine, int SakSampel, decimal KgSampel);
public record SamplingReq(List<SamplingLine> Items);

/// Kontainer bongkar: daftar di dock, sampling berat per barang, selesai bongkar, pembagian berat (prorata).
public static class KontainerEndpoints
{
    static IResult Bad(string m) => Results.BadRequest(new { message = m });

    public class AlokasiItem
    {
        public int PlanLine { get; set; }
        public string ItemCode { get; set; } = "";
        public string? Dscription { get; set; }
        public decimal SakTotal { get; set; }
        public decimal KgKrani { get; set; }
        public int SakSampel { get; set; }
        public decimal KgSampel { get; set; }
        public decimal EstimasiSisaKg { get; set; }
        public decimal AlokasiSisaKg { get; set; }
        public decimal KgTimbang { get; set; }
    }

    /// Barang di kontainer = input krani (KRN1 masuk) per baris dokumen + sampling.
    public static async Task<List<AlokasiItem>> Items(SqlConnection db, SqlTransaction? tx, long sesiId) =>
        (await db.QueryAsync<AlokasiItem>(@"
SELECT d.PlanLine, MAX(d.ItemCode) AS ItemCode, MAX(p1.Dscription) AS Dscription,
       SUM(ISNULL(d.Qty2, 0)) AS SakTotal, SUM(d.qty) AS KgKrani,
       ISNULL(MAX(s.SakSampel), 0) AS SakSampel, ISNULL(MAX(s.KgSampel), 0) AS KgSampel
FROM OKRN h JOIN KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
JOIN WHS_KontainerSesi k ON k.SesiId = h.SesiId
LEFT JOIN WHS_Plan1 p1 ON p1.PlanId = k.PlanId AND p1.PlanLine = d.PlanLine
LEFT JOIN WHS_Sampling s ON s.SesiId = h.SesiId AND s.PlanLine = d.PlanLine
WHERE h.SesiId = @sesiId AND d.flags = 1
GROUP BY d.PlanLine ORDER BY d.PlanLine", new { sesiId }, tx)).ToList();

    /// Net timbangan dibagi ke tiap barang:
    ///   rata2 kg/karung = KgSampel / SakSampel;  estimasi sisa = (SakTotal - SakSampel) x rata2  (tanpa karung: KgKrani - KgSampel)
    ///   alokasi sisa    = (Net - total KgSampel) x estimasi sisa / total estimasi sisa
    ///   KgTimbang       = KgSampel + alokasi sisa
    public static List<AlokasiItem> Hitung(List<AlokasiItem> items, decimal net)
    {
        foreach (var i in items)
        {
            var avg = i.SakSampel > 0 ? i.KgSampel / i.SakSampel : 0;
            i.EstimasiSisaKg = Math.Max(0, i.SakTotal > 0 ? (i.SakTotal - i.SakSampel) * avg : i.KgKrani - i.KgSampel);
        }
        var sisaNet = net - items.Sum(i => i.KgSampel);
        var totalEst = items.Sum(i => i.EstimasiSisaKg);
        foreach (var i in items)
        {
            i.AlokasiSisaKg = totalEst > 0 ? Math.Round(sisaNet * i.EstimasiSisaKg / totalEst, 2) : 0;
            i.KgTimbang = Math.Round(i.KgSampel + i.AlokasiSisaKg, 2);
        }
        // pembulatan: selisih sen dimasukkan ke barang terbesar supaya total = net
        if (items.Count > 0 && totalEst > 0)
        {
            var diff = net - items.Sum(i => i.KgTimbang);
            var big = items.OrderByDescending(i => i.EstimasiSisaKg).First();
            big.AlokasiSisaKg += diff; big.KgTimbang += diff;
        }
        return items;
    }

    static async Task<object?> Detail(SqlConnection db, long id)
    {
        var h = await db.QueryFirstOrDefaultAsync(@"
SELECT k.SesiId AS sesiId, k.WhsCode AS whsCode, k.ContainerNo AS containerNo, k.Status AS status, p.PlanNo AS planNo, p.CardName AS cardName,
       k.Plat1 AS plat1, k.T1Kg AS t1, k.T1At AS t1At, k.T2Kg AS t2, k.T2At AS t2At, k.Plat3 AS plat3, k.T3Kg AS t3, k.T3At AS t3At, k.T4Kg AS t4, k.T4At AS t4At,
       k.BeratIsiKg AS beratIsi, k.BeratKosongKg AS beratKosong, k.NetKg AS net, k.NetInputKrani AS netKrani, k.SelisihPersen AS selisihPersen, k.Peringatan AS peringatan,
       kt.Posisi AS posisi
FROM WHS_KontainerSesi k LEFT JOIN WHS_Plan p ON p.PlanId = k.PlanId
LEFT JOIN WHS_Kontainer kt ON kt.ContainerNo = k.ContainerNo AND kt.WhsCode = k.WhsCode AND kt.SesiId = k.SesiId
WHERE k.SesiId = @id", new { id });
        if (h is null) return null;
        var items = await Items(db, null, id);
        var alokasi = await db.QueryAsync("SELECT PlanLine AS planLine, ItemCode AS itemCode, SakTotal AS sakTotal, KgKrani AS kgKrani, SakSampel AS sakSampel, KgSampel AS kgSampel, EstimasiSisaKg AS estimasiSisaKg, AlokasiSisaKg AS alokasiSisaKg, KgTimbang AS kgTimbang FROM WHS_KontainerAlokasi WHERE SesiId = @id ORDER BY PlanLine", new { id });
        var lines = await db.QueryAsync(@"SELECT p1.PlanLine AS planLine, p1.ItemCode AS itemCode, p1.Dscription AS dscription
            FROM WHS_KontainerSesi k JOIN WHS_Plan1 p1 ON p1.PlanId = k.PlanId WHERE k.SesiId = @id ORDER BY p1.PlanLine", new { id });
        return new { header = h, items, alokasi, planLines = lines };
    }

    static async Task<bool> Akses(SqlConnection db, ClaimsPrincipal u, string whs) =>
        await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @whs", new { uid = u.UserId(), whs }) > 0;

    public static void MapKontainer(this RouteGroupBuilder api, Func<SqlConnection> dbf)
    {
        // Kontainer bongkar yang masih di gudang (untuk krani)
        api.MapGet("/kontainer/dock", async (string whs, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            if (!await Akses(db, u, whs)) return Results.Forbid();
            return Results.Ok(await db.QueryAsync(@"
SELECT k.SesiId AS sesiId, k.ContainerNo AS containerNo, k.Status AS status, p.PlanNo AS planNo, p.PlanId AS planId, p.CardName AS cardName,
       k.Plat1 AS plat1, k.T1Kg - k.T2Kg AS beratIsi, kt.Posisi AS posisi,
       (SELECT COUNT(*) FROM WHS_Sampling s WHERE s.SesiId = k.SesiId) AS jumlahSampling
FROM WHS_KontainerSesi k LEFT JOIN WHS_Plan p ON p.PlanId = k.PlanId
LEFT JOIN WHS_Kontainer kt ON kt.ContainerNo = k.ContainerNo AND kt.WhsCode = k.WhsCode AND kt.SesiId = k.SesiId
WHERE k.WhsCode = @whs AND k.Status IN ('ISI_MASUK','DI_DOCK','KOSONG') ORDER BY k.SesiId", new { whs }));
        });

        api.MapGet("/kontainer/{id:long}", async (long id, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var whs = await db.ExecuteScalarAsync<string?>("SELECT WhsCode FROM WHS_KontainerSesi WHERE SesiId = @id", new { id });
            if (whs is null) return Results.NotFound(new { message = "Kontainer tidak ditemukan" });
            if (!await Akses(db, u, whs)) return Results.Forbid();
            return Results.Ok(await Detail(db, id));
        });

        // Sampling berat per barang (bebas jumlah karung, minimal 1)
        api.MapPut("/kontainer/{id:long}/sampling", async (long id, SamplingReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (r.Items is null || r.Items.Count == 0) return Bad("Isi sampling minimal satu barang");
            if (r.Items.Any(i => i.SakSampel < 1 || i.SakSampel > 10000 || i.KgSampel <= 0 || i.KgSampel > 1_000_000)) return Bad("Sampling: karung minimal 1 dan berat lebih dari 0");
            await using var db = dbf();
            var k = await db.QueryFirstOrDefaultAsync<(string WhsCode, long? PlanId, string Status)?>("SELECT WhsCode, PlanId, Status FROM WHS_KontainerSesi WHERE SesiId = @id", new { id });
            if (k is null) return Results.NotFound(new { message = "Kontainer tidak ditemukan" });
            if (!await Akses(db, u, k.Value.WhsCode)) return Results.Forbid();
            if (k.Value.Status is not ("ISI_MASUK" or "DI_DOCK" or "KOSONG")) return Bad("Kontainer sudah selesai ditimbang · sampling tidak bisa diubah");
            foreach (var i in r.Items)
            {
                var item = await db.ExecuteScalarAsync<string?>("SELECT ItemCode FROM WHS_Plan1 WHERE PlanId = @p AND PlanLine = @l", new { p = k.Value.PlanId, l = i.PlanLine });
                if (item is null) return Bad($"Baris {i.PlanLine} tidak ada di dokumen");
                await db.ExecuteAsync(@"MERGE WHS_Sampling AS t USING (SELECT @id AS SesiId, @l AS PlanLine) s ON t.SesiId = s.SesiId AND t.PlanLine = s.PlanLine
                    WHEN MATCHED THEN UPDATE SET SakSampel = @sak, KgSampel = @kg, UserId = @u, UpdatedAt = SYSDATETIME()
                    WHEN NOT MATCHED THEN INSERT (SesiId, PlanLine, ItemCode, SakSampel, KgSampel, UserId) VALUES (@id, @l, @item, @sak, @kg, @u);",
                    new { id, l = i.PlanLine, item, sak = i.SakSampel, kg = i.KgSampel, u = u.UserId() });
            }
            await Audit.Safe(db, u, ctx, "SAMPLING", "KONTAINER", id, $"{r.Items.Count} barang");
            return Results.Ok(await Detail(db, id));
        });

        // Krani selesai membongkar: kontainer jadi kosong, siap ditarik (T3/T4)
        api.MapPost("/kontainer/{id:long}/selesai-bongkar", async (long id, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            var k = await db.QueryFirstOrDefaultAsync<(string WhsCode, string ContainerNo, string Status)?>("SELECT WhsCode, ContainerNo, Status FROM WHS_KontainerSesi WHERE SesiId = @id", new { id });
            if (k is null) return Results.NotFound(new { message = "Kontainer tidak ditemukan" });
            if (!await Akses(db, u, k.Value.WhsCode)) return Results.Forbid();
            if (k.Value.Status == "ISI_MASUK") return Bad("Kepala truk belum ditimbang (lepas kontainer) di pos timbang");
            if (k.Value.Status != "DI_DOCK") return Bad("Kontainer tidak dalam proses bongkar");
            var items = await Items(db, null, id);
            if (items.Count == 0) return Bad("Belum ada input krani untuk kontainer ini");
            var tanpa = items.Where(i => i.SakSampel <= 0).Select(i => i.ItemCode).ToList();
            if (tanpa.Count > 0) return Bad("Sampling berat belum diisi untuk: " + string.Join(", ", tanpa));
            await db.ExecuteAsync("UPDATE WHS_KontainerSesi SET Status = 'KOSONG' WHERE SesiId = @id", new { id });
            await db.ExecuteAsync("UPDATE WHS_Kontainer SET Kondisi = 'Kosong' WHERE ContainerNo = @c AND WhsCode = @w AND SesiId = @id", new { c = k.Value.ContainerNo, w = k.Value.WhsCode, id });
            await Audit.Safe(db, u, ctx, "BONGKAR_SELESAI", "KONTAINER", id, k.Value.ContainerNo);
            return Results.Ok();
        });
    }

    public static void MapKontainerAdmin(this RouteGroupBuilder cms, Func<SqlConnection> dbf)
    {
        cms.MapGet("/kontainer-sesi", async (string? whs, string? q) =>
        {
            await using var db = dbf();
            var term = (q ?? "").Trim().ToUpperInvariant();
            return Results.Ok(await db.QueryAsync(@"
SELECT TOP 300 k.SesiId AS sesiId, k.WhsCode AS whsCode, k.ContainerNo AS containerNo, k.Status AS status, p.PlanNo AS planNo, p.CardName AS cardName,
       k.Plat1 AS plat1, k.Plat3 AS plat3, k.BeratIsiKg AS beratIsi, k.BeratKosongKg AS beratKosong, k.NetKg AS net, k.NetInputKrani AS netKrani,
       k.SelisihPersen AS selisihPersen, k.CreatedAt AS createdAt, k.SelesaiAt AS selesaiAt
FROM WHS_KontainerSesi k LEFT JOIN WHS_Plan p ON p.PlanId = k.PlanId
WHERE (@whs IS NULL OR k.WhsCode = @whs) AND (@q = '' OR k.ContainerNo LIKE '%' + @q + '%' OR p.PlanNo LIKE '%' + @q + '%' OR k.Plat1 LIKE '%' + @q + '%' OR k.Plat3 LIKE '%' + @q + '%')
ORDER BY k.SesiId DESC", new { whs = string.IsNullOrWhiteSpace(whs) ? null : whs, q = term }));
        });
        cms.MapGet("/kontainer-sesi/{id:long}", async (long id) =>
        {
            await using var db = dbf();
            var d = await Detail(db, id);
            return d is null ? Results.NotFound() : Results.Ok(d);
        });
    }
}
