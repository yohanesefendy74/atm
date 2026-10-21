using System.Data;
using System.Security.Claims;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

public record TerimaLine(int PlanLine, decimal Qty, decimal Qty2, decimal QtyPalet, string? Brand, string? KodeRuangan);
public record TerimaReq(long? RegId, DateTime? DocDate, List<TerimaLine> Lines, long? SesiId = null);

/// Krani menyimpan penerimaan (SPBB) / pengiriman (SPMB) terhadap dokumen rencana. Satu simpan = satu OKRN (penerimaan ke-N).
public static class PlanKraniSave
{
    static IResult Bad(string m) => Results.BadRequest(new { message = m });

    public static void MapPlanKraniSave(this RouteGroupBuilder api, Func<SqlConnection> dbf)
    {
        api.MapPost("/plan/{id:long}/simpan", async (long id, TerimaReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (r.Lines is null || r.Lines.Count == 0) return Bad("Belum ada baris yang diisi");
            if (r.Lines.Any(l => l.Qty <= 0 || l.Qty > 10_000_000 || l.Qty2 < 0 || l.QtyPalet < 0)) return Bad("Qty tidak valid");
            if (r.Lines.Select(l => l.PlanLine).Distinct().Count() != r.Lines.Count) return Bad("Baris dokumen dobel");
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.Serializable);
            try
            {
                var p = await db.QueryFirstOrDefaultAsync<(long PlanId, string PlanNo, string Jenis, string WhsCode, string Status, string? KodeRuangan, bool? Titipan, string? PtCode)?>(
                    @"SELECT p.PlanId, p.PlanNo, p.Jenis, p.WhsCode, p.Status, p.KodeRuangan, rm.Titipan, p.U_IDU_Kode_PT AS PtCode
                      FROM WHS_Plan p WITH (UPDLOCK) JOIN WHS_PlanKrani k ON k.PlanId = p.PlanId AND k.UserId = @uid
                      LEFT JOIN WHS_MasterRuangan rm ON rm.KodeRuangan = p.KodeRuangan WHERE p.PlanId = @id", new { id, uid = u.UserId() }, tx);
                if (p is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan atau bukan tugas Anda" });
                var pl = p.Value;
                if (pl.Status is not ("Terbit" or "Proses" or "Partial")) return Bad($"Dokumen berstatus {pl.Status} · tidak bisa diinput");
                if (pl.Jenis is not ("SPBB" or "SPMB")) return Bad("Jenis dokumen tidak dikenal");

                string noMobil = "", cont = "";
                long? regId = r.RegId, sesiId = null;
                if (pl.Jenis == "SPBB")
                {
                    // Bongkar kontainer: input krani terhadap kontainer di dock (truk pembawa mungkin sudah keluar)
                    if (r.SesiId is null) return Bad("Pilih kontainer yang sedang dibongkar");
                    var ks = await db.QueryFirstOrDefaultAsync<(long? PlanId, string Status, string ContainerNo, string? Plat1, long? RegId1)?>(
                        "SELECT PlanId, Status, ContainerNo, Plat1, RegId1 FROM WHS_KontainerSesi WHERE SesiId = @s", new { s = r.SesiId }, tx);
                    if (ks is null) return Bad("Kontainer tidak ditemukan");
                    if (ks.Value.PlanId != id) return Bad("Kontainer ini terdaftar untuk dokumen lain");
                    if (ks.Value.Status is not ("ISI_MASUK" or "DI_DOCK")) return Bad("Kontainer sudah selesai dibongkar");
                    noMobil = ks.Value.Plat1 ?? ""; cont = ks.Value.ContainerNo; regId = ks.Value.RegId1; sesiId = r.SesiId;
                }
                else if (r.RegId is not null)
                {
                    var k = await db.QueryFirstOrDefaultAsync<(long? PlanId, string NoPolisi, string? ContainerNo, string Status)?>("SELECT PlanId, NoPolisi, ContainerNo, Status FROM WHS_Kendaraan WHERE RegId = @r", new { r = r.RegId }, tx);
                    if (k is null || k.Value.Status != "Di dalam") return Bad("Kendaraan tidak di dalam gudang");
                    if (k.Value.PlanId != id) return Bad("Kendaraan ini terdaftar untuk dokumen lain");
                    noMobil = k.Value.NoPolisi; cont = k.Value.ContainerNo ?? "";
                }
                else return Bad("Pilih kendaraan yang sedang memuat");

                var plan1 = (await db.QueryAsync<(int PlanLine, string ItemCode, string? Dscription, string? ContainerNo, string? BrandName, decimal QtyPlan, decimal QtyDone, string? PaletCode, string? KodeRuangan, string? Size, string? Type, string? Crop)>(
                    "SELECT PlanLine, ItemCode, Dscription, ContainerNo, BrandName, QtyPlan, QtyDone, PaletCode, KodeRuangan, Size, [Type], Crop FROM WHS_Plan1 WITH (UPDLOCK) WHERE PlanId = @id", new { id }, tx)).ToDictionary(x => x.PlanLine);
                foreach (var l in r.Lines)
                {
                    if (!plan1.TryGetValue(l.PlanLine, out var pr)) return Bad($"Baris {l.PlanLine} tidak ada di dokumen");
                    var sisa = pr.QtyPlan - pr.QtyDone;
                    if (l.Qty > sisa + 0.0001m) return Bad($"{pr.ItemCode}: qty {l.Qty:N0} melebihi sisa dokumen {sisa:N0} kg");
                    var ruang = l.KodeRuangan ?? pr.KodeRuangan ?? pl.KodeRuangan;
                    if (ruang is null) return Bad(pl.Jenis == "SPBB" ? $"{pr.ItemCode}: pilih ruangan tujuan" : $"{pr.ItemCode}: pilih ruangan sumber");
                    if (ruang is not null)
                    {
                        var rt = await db.QueryFirstOrDefaultAsync<(bool Titipan, string WhsCode)?>("SELECT Titipan, WhsCode FROM WHS_MasterRuangan WHERE KodeRuangan = @k AND Aktif = 1", new { k = ruang }, tx);
                        if (rt is null) return Bad($"Ruangan {ruang} tidak ditemukan atau nonaktif");
                        if (rt.Value.WhsCode != pl.WhsCode) return Bad($"Ruangan {ruang} bukan milik gudang {pl.WhsCode}");
                        if (pl.Titipan is not null && rt.Value.Titipan != pl.Titipan) return Bad("Titipan dan non-titipan tidak boleh dicampur dalam satu dokumen");
                    }
                }
                if (pl.Jenis == "SPBB" && string.IsNullOrWhiteSpace(pl.PtCode) == false) { /* PT terisi dari dokumen */ }

                var date = (r.DocDate ?? DateTime.Today).Date;
                if (date > DateTime.Today || date < DateTime.Today.AddDays(-3)) date = DateTime.Today;
                var objType = pl.Jenis == "SPBB" ? "6730" : "6710";
                var flag = pl.Jenis == "SPBB" ? 1 : -1;
                var trx = (pl.Titipan ?? false) ? "BT" : pl.Jenis == "SPBB" ? "IB" : "OB";

                var dp = new DynamicParameters();
                dp.Add("@ObjType", objType); dp.Add("@DocDate", date, DbType.Date);
                dp.Add("@DocEntry", dbType: DbType.Int64, direction: ParameterDirection.Output);
                await db.ExecuteAsync(Sql.NextDocEntry, dp, tx, commandType: CommandType.StoredProcedure);
                var docEntry = dp.Get<long>("@DocEntry");
                await db.ExecuteAsync(Sql.InsertHeader, new { objType, docEntry, docDate = date, bplId = u.BplId(), whsCode = pl.WhsCode, userId = u.UserId(), trxCode = trx, noMobil, containerNo = string.IsNullOrEmpty(cont) ? null : cont }, tx);
                var ke = await db.ExecuteScalarAsync<int>("SELECT ISNULL(MAX(PenerimaanKe), 0) + 1 FROM OKRN WHERE PlanId = @id", new { id }, tx);
                await db.ExecuteAsync("UPDATE OKRN SET PlanId = @id, PenerimaanKe = @ke, RegId = @reg, SesiId = @sesi WHERE ObjType = @objType AND DocEntry = @docEntry", new { id, ke, reg = regId, sesi = sesiId, objType, docEntry }, tx);
                // Data dari SPBB/SPMB ikut ke dokumen krani supaya Admin tinggal mengecek & memposting stok di CMS
                await db.ExecuteAsync(@"UPDATE h SET U_IDU_Kode_PT = p.U_IDU_Kode_PT, cardcode = COALESCE(NULLIF(p.CardCodeTitipan, ''), p.CardCode),
                        NumAtCard = LEFT(d.NumAtCard, COL_LENGTH('OKRN', 'NumAtCard')), BaseType = d.BaseType, BaseDocEntry = d.BaseDocEntry, BaseDocNum = d.BaseDocNum
                    FROM OKRN h JOIN WHS_Plan p ON p.PlanId = @id
                    OUTER APPLY (SELECT TOP 1 BaseType, BaseDocEntry, BaseDocNum, NumAtCard FROM WHS_PlanDoc WHERE PlanId = @id ORDER BY BaseDocEntry) d
                    WHERE h.ObjType = @objType AND h.DocEntry = @docEntry", new { id, objType, docEntry }, tx);

                var lineNum = 0;
                foreach (var l in r.Lines)
                {
                    var pr = plan1[l.PlanLine];
                    var ruang = l.KodeRuangan ?? pr.KodeRuangan ?? pl.KodeRuangan;
                    var brand = Helpers.Empty(l.Brand) ?? pr.BrandName;
                    await db.ExecuteAsync(Sql.InsertLine, new { objType, docEntry, lineNum, itemCode = pr.ItemCode, uom = "KG", brand, origin = (string?)null, qty = l.Qty, qty2 = l.Qty2, qtyPalet = l.QtyPalet, flag, ruang }, tx);
                    await db.ExecuteAsync(@"UPDATE KRN1 SET PlanLine = @pl, ContainerNo = @c, KodeRuangan = @ru, PaletCode = @pc, Size = @sz, [Type] = @ty, Crop = @cr,
                        brand_asli = CASE WHEN @brand IS NOT NULL AND ISNULL(@asli, '') <> @brand THEN @asli END,
                        brand_diubah_oleh = CASE WHEN @brand IS NOT NULL AND ISNULL(@asli, '') <> @brand THEN @uid END,
                        brand_diubah_at = CASE WHEN @brand IS NOT NULL AND ISNULL(@asli, '') <> @brand THEN SYSDATETIME() END
                        WHERE ObjType = @objType AND DocEntry = @docEntry AND LineNum = @lineNum",
                        new { pl = l.PlanLine, c = pr.ContainerNo, ru = ruang, pc = pr.PaletCode, sz = pr.Size, ty = pr.Type, cr = pr.Crop, brand, asli = pr.BrandName, uid = u.UserId(), objType, docEntry, lineNum }, tx);
                    if (brand != pr.BrandName)
                        await db.ExecuteAsync("INSERT WHS_BrandChangeLog (OKRN_DocEntry, LineNum, BrandLama, BrandBaru, ChangedBy) VALUES (@de, @ln, @a, @b, @uid)",
                            new { de = docEntry, ln = lineNum, a = pr.BrandName, b = brand ?? "", uid = u.UserId() }, tx);
                    await db.ExecuteAsync("UPDATE WHS_Plan1 SET QtyDone = QtyDone + @q, Qty2Done = Qty2Done + @q2, PaletDone = PaletDone + @pa WHERE PlanId = @id AND PlanLine = @pl",
                        new { q = l.Qty, q2 = l.Qty2, pa = (int)Math.Ceiling(l.QtyPalet), id, pl = l.PlanLine }, tx);
                    lineNum++;
                }
                await db.ExecuteAsync(Sql.UpdateTotals, new { objType, docEntry }, tx);
                var sisaTotal = await db.ExecuteScalarAsync<decimal>("SELECT SUM(QtyPlan - QtyDone) FROM WHS_Plan1 WHERE PlanId = @id", new { id }, tx);
                var status = sisaTotal <= 0.0001m ? "Selesai" : "Proses";
                await db.ExecuteAsync("UPDATE WHS_Plan SET Status = @s WHERE PlanId = @id", new { s = status, id }, tx);
                await Audit.Write(db, tx, u, ctx, "PLAN_SIMPAN", objType, docEntry, $"{pl.PlanNo} penerimaan ke-{ke} {r.Lines.Count} baris");
                await tx.CommitAsync();
                return Results.Ok(new { objType, docEntry, trxCode = trx, penerimaanKe = ke, status });
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
}
