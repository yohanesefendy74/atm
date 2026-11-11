using System.Data;
using System.Security.Claims;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

public record MuatLangsungLine(int SpmbLine, int SpbbLine, decimal Sak, decimal Palet, decimal KgEstimasi, string? Brand);
public record MuatLangsungReq(long RegId, long SesiId, List<MuatLangsungLine> Lines, string? NoMobilAktual = null, string? Catatan = null);

/// Muat langsung (cross-dock) di gudang timbangan mobil: sebagian barang SPBB dari kontainer yang sedang dibongkar
/// langsung dimuat ke truk SPMB. Satu simpan = satu dokumen masuk (SPBB) + satu dokumen keluar (SPMB), baris berpasangan
/// dengan ruangan/BL/PT/lot yang sama sehingga saldo bersih nol. Kg sementara = estimasi; kg final = net timbang keluar truk
/// dikurangi kg muatan lain (stok gudang, beratnya sudah diketahui).
public static class MuatLangsung
{
    static IResult Bad(string m) => Results.BadRequest(new { message = m });

    record PlanH(long PlanId, string PlanNo, string Jenis, string WhsCode, string Status, string? KodeRuangan, bool Titipan, string? PtCode);
    record PlanL(int PlanLine, string ItemCode, string? ContainerNo, string? BrandName, decimal QtyPlan, decimal QtyDone, string? PaletCode, string? KodeRuangan, string? Size, string? Type, string? Crop, string? NoBL, string? NoLot);

    const string HeaderDariPlan = @"UPDATE h SET U_IDU_Kode_PT = p.U_IDU_Kode_PT, cardcode = COALESCE(NULLIF(p.CardCodeTitipan, ''), p.CardCode),
            NumAtCard = LEFT(d.NumAtCard, COL_LENGTH('OKRN', 'NumAtCard')),
            U_NoBL = CASE WHEN p.Jenis = 'SPBB' THEN LEFT((SELECT TOP 1 NoBL FROM WHS_Plan1 WHERE PlanId = @id AND NoBL IS NOT NULL ORDER BY PlanLine), COL_LENGTH('OKRN', 'U_NoBL')) ELSE h.U_NoBL END,
            BaseType = d.BaseType, BaseDocEntry = d.BaseDocEntry, BaseDocNum = d.BaseDocNum
        FROM OKRN h JOIN WHS_Plan p ON p.PlanId = @id
        OUTER APPLY (SELECT TOP 1 BaseType, BaseDocEntry, BaseDocNum, NumAtCard FROM WHS_PlanDoc WHERE PlanId = @id ORDER BY BaseDocEntry) d
        WHERE h.ObjType = @objType AND h.DocEntry = @docEntry";

    static Task<PlanH?> Plan(SqlConnection db, SqlTransaction tx, long id, int uid) =>
        db.QueryFirstOrDefaultAsync<PlanH?>(@"SELECT p.PlanId, p.PlanNo, p.Jenis, p.WhsCode, p.Status, p.KodeRuangan, CAST(COALESCE(p.Titipan, rm.Titipan, 0) AS BIT) AS Titipan, p.U_IDU_Kode_PT AS PtCode
            FROM WHS_Plan p WITH (UPDLOCK) JOIN WHS_PlanKrani k ON k.PlanId = p.PlanId AND k.UserId = @uid
            LEFT JOIN WHS_MasterRuangan rm ON rm.KodeRuangan = p.KodeRuangan WHERE p.PlanId = @id", new { id, uid }, tx);

    static async Task<Dictionary<int, PlanL>> Lines(SqlConnection db, SqlTransaction tx, long id) =>
        (await db.QueryAsync<PlanL>(@"SELECT PlanLine, ItemCode, ContainerNo, BrandName, QtyPlan, QtyDone, PaletCode, KodeRuangan, Size, [Type] AS Type, Crop, NoBL, NoLot
            FROM WHS_Plan1 WITH (UPDLOCK) WHERE PlanId = @id", new { id }, tx)).ToDictionary(x => x.PlanLine);

    /// Rata-rata kg/karung dari sampling kontainer (null bila belum ada sampel)
    public static Task<decimal?> AvgSampel(SqlConnection db, SqlTransaction? tx, long sesiId, int planLine) =>
        db.ExecuteScalarAsync<decimal?>("SELECT AVG(KgSak) FROM WHS_SamplingSak WHERE SesiId = @s AND PlanLine = @l", new { s = sesiId, l = planLine }, tx);

    public static void MapMuatLangsung(this RouteGroupBuilder api, Func<SqlConnection> dbf)
    {
        api.MapPost("/plan/{id:long}/muat-langsung", async (long id, MuatLangsungReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (r.Lines is null || r.Lines.Count == 0) return Bad("Belum ada barang yang dimuat langsung");
            if (r.Lines.Any(l => l.Sak <= 0 || l.Sak > 100_000 || l.Palet < 0 || l.KgEstimasi < 0)) return Bad("Isi jumlah sak (lebih dari 0) dan palet");
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.Serializable);
            try
            {
                var spmb = await Plan(db, tx, id, u.UserId());
                if (spmb is null) return Results.NotFound(new { message = "SPMB tidak ditemukan atau bukan tugas Anda" });
                if (spmb.Jenis != "SPMB") return Bad("Muat langsung hanya dari dokumen SPMB");
                if (spmb.Status is not ("Terbit" or "Proses" or "Partial")) return Bad($"SPMB berstatus {spmb.Status}");

                // Truk SPMB: di dalam, keperluan muat, belum selesai. Satu SPMB yang sedang dimuat hanya berisi barang dari satu partial SPBB;
                // muatan lain baru boleh setelah truk ditimbang (timbang antara) dan lanjut ke SPMB berikutnya.
                var k = await db.QueryFirstOrDefaultAsync<(long? PlanId, string NoPolisi, string? ContainerNo, string Status, string Keperluan, bool SelesaiKrani, string WhsCode)?>(
                    "SELECT PlanId, NoPolisi, ContainerNo, Status, Keperluan, SelesaiKrani, WhsCode FROM WHS_Kendaraan WITH (UPDLOCK) WHERE RegId = @r", new { r = r.RegId }, tx);
                if (k is null || k.Value.Status != "Di dalam") return Bad("Truk tidak di dalam gudang");
                if (k.Value.PlanId != id || k.Value.Keperluan != "Muat") return Bad("Truk ini tidak terdaftar untuk memuat SPMB ini");
                if (k.Value.SelesaiKrani) return Bad("Muat truk ini sudah diselesaikan");
                var stokSpmbIni = await db.ExecuteScalarAsync<int>(@"SELECT COUNT(*) FROM OKRN h JOIN KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
                    WHERE h.RegId = @r AND h.PlanId = @id AND d.flags = -1 AND d.CrossDockKey IS NULL", new { r = r.RegId, id }, tx);
                if (stokSpmbIni > 0) return Bad("SPMB ini sudah dimuat dari stok gudang · muat langsung harus di SPMB lain setelah truk ditimbang");
                var sesiLain = await db.ExecuteScalarAsync<int>(@"SELECT COUNT(*) FROM KRN1 d JOIN OKRN h ON h.ObjType = d.ObjType AND h.DocEntry = d.DocEntry
                    WHERE d.CrossDockRegId = @r AND h.PlanId = @id AND d.CrossDockSesiId <> @s", new { r = r.RegId, id, s = r.SesiId }, tx);
                if (sesiLain > 0) return Bad("SPMB ini sudah memuat langsung dari kontainer lain · selesaikan & timbang truk dulu");

                // Kontainer SPBB yang sedang dibongkar
                var ks = await db.QueryFirstOrDefaultAsync<(long? PlanId, string Status, string ContainerNo, string? Plat1, long? RegId1, string WhsCode)?>(
                    "SELECT PlanId, Status, ContainerNo, Plat1, RegId1, WhsCode FROM WHS_KontainerSesi WITH (UPDLOCK) WHERE SesiId = @s", new { s = r.SesiId }, tx);
                if (ks is null || ks.Value.PlanId is null) return Bad("Kontainer SPBB tidak ditemukan");
                if (ks.Value.Status is not ("ISI_MASUK" or "DI_DOCK")) return Bad("Kontainer sudah selesai dibongkar");
                if (ks.Value.WhsCode != spmb.WhsCode) return Bad("Kontainer berada di gudang lain");
                var spbb = await Plan(db, tx, ks.Value.PlanId.Value, u.UserId());
                if (spbb is null) return Bad("SPBB kontainer ini bukan tugas Anda");
                if (spbb.Status is not ("Terbit" or "Proses" or "Partial")) return Bad($"SPBB berstatus {spbb.Status}");
                if (spbb.Titipan != spmb.Titipan) return Bad("Titipan dan non-titipan tidak boleh dicampur");

                var l1 = await Lines(db, tx, spbb.PlanId);
                var l2 = await Lines(db, tx, spmb.PlanId);
                var est = new List<(MuatLangsungLine L, PlanL B, PlanL M, decimal Kg, string Ruang)>();
                // prorata hanya bila lebih dari 1 item: satu item tidak perlu sampel (estimasi dari isi per karung SPBB)
                var banyakItem = r.Lines.Select(l => l1.TryGetValue(l.SpbbLine, out var bx) ? bx.ItemCode : "").Distinct().Count() > 1;
                foreach (var l in r.Lines)
                {
                    if (!l1.TryGetValue(l.SpbbLine, out var b)) return Bad($"Baris SPBB {l.SpbbLine} tidak ada");
                    if (!l2.TryGetValue(l.SpmbLine, out var m)) return Bad($"Baris SPMB {l.SpmbLine} tidak ada");
                    if (b.ItemCode != m.ItemCode) return Bad($"Item SPBB {b.ItemCode} tidak sama dengan item SPMB {m.ItemCode}");
                    var ruang = b.KodeRuangan ?? spbb.KodeRuangan;
                    if (ruang is null) return Bad($"{b.ItemCode}: ruangan SPBB belum diisi");
                    // kg sementara: sak x rata-rata sampling, atau isian krani, atau isi per sak dari SPBB
                    var avg = await AvgSampel(db, tx, r.SesiId, b.PlanLine);
                    var pack = await db.ExecuteScalarAsync<decimal?>("SELECT CASE WHEN Qty2Plan > 0 THEN QtyPlan / Qty2Plan END FROM WHS_Plan1 WHERE PlanId = @p AND PlanLine = @l", new { p = spbb.PlanId, l = b.PlanLine }, tx);
                    var kg = avg is > 0 ? Math.Round(l.Sak * avg.Value, 2) : l.KgEstimasi > 0 ? l.KgEstimasi : !banyakItem && pack is > 0 ? Math.Round(l.Sak * pack.Value, 2) : 0;
                    if (kg <= 0) return Bad(banyakItem ? $"{b.ItemCode}: lebih dari 1 item · timbang sampel berat sak dulu atau isi estimasi kg" : $"{b.ItemCode}: isi estimasi kg");
                    est.Add((l, b, m, kg, ruang));
                }
                foreach (var g in est.GroupBy(e => e.B.PlanLine))
                    if (g.Sum(e => e.Kg) > g.First().B.QtyPlan - g.First().B.QtyDone + 0.0001m) return Bad($"{g.First().B.ItemCode}: melebihi sisa SPBB");
                foreach (var g in est.GroupBy(e => e.M.PlanLine))
                    if (g.Sum(e => e.Kg) > g.First().M.QtyPlan - g.First().M.QtyDone + 0.0001m) return Bad($"{g.First().M.ItemCode}: melebihi sisa SPMB");

                var date = DateTime.Today;
                var hasil = new List<object>();
                var seq = await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM KRN1 WHERE CrossDockRegId = @r AND flags = -1", new { r = r.RegId }, tx);
                var keys = est.Select((_, i) => $"{r.RegId}-{seq + i + 1}").ToList();
                foreach (var (plan, objType, flag, reg, plat, cont) in new[]
                {
                    (spbb, "6730", 1, ks.Value.RegId1, ks.Value.Plat1 ?? "", ks.Value.ContainerNo),
                    (spmb, "6710", -1, (long?)r.RegId, k.Value.NoPolisi, k.Value.ContainerNo ?? ""),
                })
                {
                    var trx = plan.Titipan ? "BT" : flag == 1 ? "IB" : "OB";
                    var dp = new DynamicParameters();
                    dp.Add("@ObjType", objType); dp.Add("@DocDate", date, DbType.Date);
                    dp.Add("@DocEntry", dbType: DbType.Int64, direction: ParameterDirection.Output);
                    await db.ExecuteAsync(Sql.NextDocEntry, dp, tx, commandType: CommandType.StoredProcedure);
                    var docEntry = dp.Get<long>("@DocEntry");
                    await db.ExecuteAsync(Sql.InsertHeader, new { objType, docEntry, docDate = date, bplId = u.BplId(), whsCode = plan.WhsCode, userId = u.UserId(), trxCode = trx, noMobil = plat, containerNo = string.IsNullOrEmpty(cont) ? null : cont }, tx);
                    var ke = await db.ExecuteScalarAsync<int>("SELECT ISNULL(MAX(PenerimaanKe), 0) + 1 FROM OKRN WHERE PlanId = @id", new { id = plan.PlanId }, tx);
                    await db.ExecuteAsync("UPDATE OKRN SET PlanId = @id, PenerimaanKe = @ke, RegId = @reg, SesiId = @sesi, CatatanKrani = @cat WHERE ObjType = @objType AND DocEntry = @docEntry",
                        new { id = plan.PlanId, ke, reg, sesi = flag == 1 ? r.SesiId : (long?)null, cat = $"Muat langsung {spbb.PlanNo} -> {spmb.PlanNo} truk {k.Value.NoPolisi}" + (string.IsNullOrWhiteSpace(r.Catatan) ? "" : $" · {r.Catatan.Trim()}"), objType, docEntry }, tx);
                    await db.ExecuteAsync(HeaderDariPlan, new { id = plan.PlanId, objType, docEntry }, tx);
                    for (var i = 0; i < est.Count; i++)
                    {
                        var e = est[i];
                        var pl = flag == 1 ? e.B : e.M;
                        var brand = Helpers.Empty(e.L.Brand) ?? e.B.BrandName;
                        await db.ExecuteAsync(Sql.InsertLine, new { objType, docEntry, lineNum = i, itemCode = e.B.ItemCode, uom = "KG", brand, origin = (string?)null, qty = e.Kg, qty2 = e.L.Sak, qtyPalet = e.L.Palet, flag,
                            ruang = e.Ruang, bl = spbb.Titipan ? null : e.B.NoBL, tit = spbb.Titipan, pt = spbb.PtCode, lot = e.B.NoLot }, tx);
                        await db.ExecuteAsync(@"UPDATE KRN1 SET PlanLine = @pl, ContainerNo = @c, PaletCode = @pc, Size = @sz, [Type] = @ty, Crop = @cr,
                                CrossDockSesiId = @sesi, CrossDockRegId = @truk, CrossDockKey = @key, CrossDockFinal = 0
                            WHERE ObjType = @objType AND DocEntry = @docEntry AND LineNum = @ln",
                            new { pl = pl.PlanLine, c = e.B.ContainerNo, pc = e.B.PaletCode, sz = e.B.Size, ty = e.B.Type, cr = e.B.Crop, sesi = r.SesiId, truk = r.RegId, key = keys[i], objType, docEntry, ln = i }, tx);
                        await db.ExecuteAsync("UPDATE WHS_Plan1 SET QtyDone = QtyDone + @q, Qty2Done = Qty2Done + @q2, PaletDone = PaletDone + @pa WHERE PlanId = @id AND PlanLine = @pl",
                            new { q = e.Kg, q2 = e.L.Sak, pa = (int)Math.Ceiling(e.L.Palet), id = plan.PlanId, pl = pl.PlanLine }, tx);
                    }
                    await db.ExecuteAsync(Sql.UpdateTotals, new { objType, docEntry }, tx);
                    var sisa = await db.ExecuteScalarAsync<decimal>("SELECT SUM(QtyPlan - QtyDone) FROM WHS_Plan1 WHERE PlanId = @id", new { id = plan.PlanId }, tx);
                    await db.ExecuteAsync("UPDATE WHS_Plan SET Status = @s WHERE PlanId = @id", new { s = sisa <= 0.0001m ? "Selesai" : "Proses", id = plan.PlanId }, tx);
                    hasil.Add(new { planNo = plan.PlanNo, objType, docEntry, trxCode = trx });
                }
                await Audit.Write(db, tx, u, ctx, "MUAT_LANGSUNG", "KENDARAAN", r.RegId, $"{spbb.PlanNo} -> {spmb.PlanNo} {est.Count} baris est {est.Sum(e => e.Kg):N0} kg");
                await tx.CommitAsync();
                return Results.Ok(new { dokumen = hasil, estimasiKg = est.Sum(e => e.Kg), catatan = "Kg final ditetapkan saat truk timbang keluar" });
            }
            catch (SqlException ex) when (ex.Class == 16)
            {
                try { await tx.RollbackAsync(); } catch { }
                return Bad(ex.Message);
            }
            catch
            {
                try { await tx.RollbackAsync(); } catch { }
                throw;
            }
        });
    }

    /// Timbang keluar truk SPMB yang memuat langsung: net dibagi ke baris (prorata estimasi), kg baris keluar
    /// dan pasangan baris masuk SPBB diganti dengan hasil timbang, QtyDone rencana disesuaikan.
    public static async Task<List<object>?> TetapkanBerat(SqlConnection db, SqlTransaction tx, long regId, decimal net, long? planId = null)
    {
        var rows = (await db.QueryAsync<(string ObjType, long DocEntry, int LineNum, string Key, decimal Qty, long PlanId, int PlanLine)>(
            @"SELECT d.ObjType, d.DocEntry, d.LineNum, d.CrossDockKey, d.qty, h.PlanId, d.PlanLine
              FROM KRN1 d JOIN OKRN h ON h.ObjType = d.ObjType AND h.DocEntry = d.DocEntry
              WHERE d.CrossDockRegId = @regId AND d.flags = -1 AND ISNULL(d.CrossDockFinal, 0) = 0 AND (@planId IS NULL OR h.PlanId = @planId)", new { regId, planId }, tx)).ToList();
        if (rows.Count == 0) return null;
        var total = rows.Sum(x => x.Qty);
        var alloc = rows.Select(x => Math.Round(net * x.Qty / total, 2)).ToList();
        var diff = net - alloc.Sum();
        var big = rows.IndexOf(rows.OrderByDescending(x => x.Qty).First());
        alloc[big] += diff;
        var hasil = new List<object>();
        var docs = new HashSet<(string, long)>();
        for (var i = 0; i < rows.Count; i++)
        {
            var key = rows[i].Key; var kg = alloc[i];
            // baris keluar (SPMB) dan pasangan baris masuk (SPBB)
            var pair = (await db.QueryAsync<(string ObjType, long DocEntry, int LineNum, decimal Qty, long PlanId, int PlanLine)>(
                @"SELECT d.ObjType, d.DocEntry, d.LineNum, d.qty, h.PlanId, d.PlanLine FROM KRN1 d JOIN OKRN h ON h.ObjType = d.ObjType AND h.DocEntry = d.DocEntry
                  WHERE d.CrossDockKey = @key", new { key }, tx)).ToList();
            foreach (var p in pair)
            {
                await db.ExecuteAsync("UPDATE KRN1 SET qty = @kg, CrossDockFinal = 1 WHERE ObjType = @o AND DocEntry = @d AND LineNum = @l", new { kg, o = p.ObjType, d = p.DocEntry, l = p.LineNum }, tx);
                await db.ExecuteAsync("UPDATE WHS_Plan1 SET QtyDone = QtyDone + @delta WHERE PlanId = @id AND PlanLine = @pl", new { delta = kg - p.Qty, id = p.PlanId, pl = p.PlanLine }, tx);
                docs.Add((p.ObjType, p.DocEntry));
            }
            hasil.Add(new { key, estimasiKg = rows[i].Qty, kgTimbang = kg });
        }
        foreach (var (o, d) in docs) await db.ExecuteAsync(Sql.UpdateTotals, new { objType = o, docEntry = d }, tx);
        return hasil;
    }
}
