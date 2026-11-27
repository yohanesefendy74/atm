using System.Data;
using System.Security.Claims;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

public record SjPlanReq(long PlanId, string? NumAtCard, string AlamatKirim);
public record SjCreateReq(string WhsCode, DateTime TglSj, long? RegId, string? Catatan, List<SjPlanReq> Plans);

/// Surat Jalan: boleh memuat beberapa SPMB (customer berbeda), hanya di Gudang ATM, titipan tidak dicampur.
public static class SuratJalanEndpoints
{
    static IResult Bad(string m) => Results.BadRequest(new { message = m });

    public static void MapSuratJalan(this RouteGroupBuilder cms, Func<SqlConnection> dbf)
    {
        // SPMB yang sudah selesai dimuat dan belum punya Surat Jalan aktif
        cms.MapGet("/surat-jalan/kandidat", async (string whs) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(@"
SELECT p.PlanId AS planId, p.PlanNo AS planNo, p.WhsCode AS whsCode, p.CardCode AS cardCode, p.CardName AS cardName, CAST(COALESCE(p.Titipan, r.Titipan, 0) AS bit) AS titipan,
       (SELECT SUM(QtyDone) FROM WHS_Plan1 WHERE PlanId = p.PlanId) AS kg,
       (SELECT TOP 1 NumAtCard FROM WHS_SuratJalanPlan WHERE PlanId = p.PlanId ORDER BY SjId DESC) AS poTerakhir
FROM WHS_Plan p LEFT JOIN WHS_MasterRuangan r ON r.KodeRuangan = p.KodeRuangan
WHERE p.WhsCode IN " + Area.In("@whs") + @" AND p.Jenis = 'SPMB' AND p.Status IN ('Selesai','SelesaiKurang')
  AND NOT EXISTS (SELECT 1 FROM WHS_SuratJalanPlan s WHERE s.PlanId = p.PlanId AND s.Aktif = 1)
ORDER BY p.PlanId DESC", new { whs }));
        });

        // Daftar Surat Jalan yang sudah dibuat + filter: gudang, status, periode tanggal SJ, kata kunci
        // (no. SJ / no. polisi / container / sopir / no. SPMB / customer / PO).
        cms.MapGet("/surat-jalan", async (string? whs, string? status, DateTime? dari, DateTime? sampai, string? q) =>
        {
            await using var db = dbf();
            var key = string.IsNullOrWhiteSpace(q) ? null : "%" + q.Trim().Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]") + "%";
            return Results.Ok(await db.QueryAsync(@"
SELECT TOP 500 s.SjId AS sjId, s.SjNo AS sjNo, s.TglSj AS tglSj, s.NoPolisi AS noPolisi, s.ContainerNo AS containerNo, s.Sopir AS sopir,
       s.TotalKg AS totalKg, s.TotalSak AS totalSak, s.TotalPalet AS totalPalet, s.Status AS status,
       (SELECT COUNT(*) FROM WHS_SuratJalanPlan WHERE SjId = s.SjId) AS jumlahSpmb,
       STUFF((SELECT DISTINCT ', ' + p.WhsCode FROM WHS_SuratJalanPlan sp JOIN WHS_Plan p ON p.PlanId = sp.PlanId WHERE sp.SjId = s.SjId FOR XML PATH('')), 1, 2, '') AS whsCode,
       STUFF((SELECT ', ' + p.PlanNo FROM WHS_SuratJalanPlan sp JOIN WHS_Plan p ON p.PlanId = sp.PlanId WHERE sp.SjId = s.SjId ORDER BY p.PlanNo FOR XML PATH('')), 1, 2, '') AS spmb,
       STUFF((SELECT DISTINCT ', ' + sp.CardName FROM WHS_SuratJalanPlan sp WHERE sp.SjId = s.SjId FOR XML PATH('')), 1, 2, '') AS customer,
       STUFF((SELECT DISTINCT ', ' + sp.NumAtCard FROM WHS_SuratJalanPlan sp WHERE sp.SjId = s.SjId AND sp.NumAtCard <> '' FOR XML PATH('')), 1, 2, '') AS po
FROM WHS_SuratJalan s
WHERE EXISTS (SELECT 1 FROM WHS_SuratJalanPlan sp JOIN WHS_Plan p ON p.PlanId = sp.PlanId WHERE sp.SjId = s.SjId AND (@whs IS NULL OR p.WhsCode = @whs))
  AND (@status IS NULL OR s.Status = @status)
  AND (@dari IS NULL OR s.TglSj >= @dari) AND (@sampai IS NULL OR s.TglSj < DATEADD(DAY, 1, @sampai))
  AND (@key IS NULL OR s.SjNo LIKE @key OR s.NoPolisi LIKE @key OR s.ContainerNo LIKE @key OR s.Sopir LIKE @key
       OR EXISTS (SELECT 1 FROM WHS_SuratJalanPlan sp JOIN WHS_Plan p ON p.PlanId = sp.PlanId
                  WHERE sp.SjId = s.SjId AND (p.PlanNo LIKE @key OR sp.CardName LIKE @key OR sp.CardCode LIKE @key OR sp.NumAtCard LIKE @key)))
ORDER BY s.TglSj DESC, s.SjId DESC", new
            {
                whs = string.IsNullOrWhiteSpace(whs) ? null : whs,
                status = string.IsNullOrWhiteSpace(status) ? null : status,
                dari = dari?.Date, sampai = sampai?.Date, key,
            }));
        });

        cms.MapGet("/surat-jalan/{id:long}", async (long id) =>
        {
            await using var db = dbf();
            var h = await db.QueryFirstOrDefaultAsync("SELECT SjId AS sjId, SjNo AS sjNo, TglSj AS tglSj, RegId AS regId, NoPolisi AS noPolisi, ContainerNo AS containerNo, Sopir AS sopir, TotalKg AS totalKg, TotalSak AS totalSak, TotalPalet AS totalPalet, Catatan AS catatan, Status AS status FROM WHS_SuratJalan WHERE SjId = @id", new { id });
            if (h is null) return Results.NotFound();
            var plans = await db.QueryAsync("SELECT sp.PlanId AS planId, p.PlanNo AS planNo, sp.CardCode AS cardCode, sp.CardName AS cardName, sp.NumAtCard AS numAtCard, sp.AlamatKirim AS alamatKirim FROM WHS_SuratJalanPlan sp JOIN WHS_Plan p ON p.PlanId = sp.PlanId WHERE sp.SjId = @id", new { id });
            var lines = await db.QueryAsync("SELECT SjLine AS sjLine, PlanId AS planId, ItemCode AS itemCode, Dscription AS dscription, QtyPlan AS qtyPlan, QtyMuat AS qtyMuat, QtySak AS qtySak, QtyPalet AS qtyPalet, NoBL AS noBL, PtCode AS ptCode FROM WHS_SuratJalan1 WHERE SjId = @id ORDER BY SjLine", new { id });
            return Results.Ok(new { header = h, plans, lines });
        });

        cms.MapPost("/surat-jalan", async (SjCreateReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if (r.Plans is null || r.Plans.Count == 0) return Bad("Pilih minimal satu SPMB");
            if (r.Plans.Select(p => p.PlanId).Distinct().Count() != r.Plans.Count) return Bad("SPMB dobel dalam satu Surat Jalan");
            if (r.TglSj.Date > DateTime.Today) return Bad("Tanggal Surat Jalan tidak boleh melewati hari ini");
            if (r.Plans.Any(p => string.IsNullOrWhiteSpace(p.AlamatKirim))) return Bad("Alamat kirim wajib per SPMB");
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.Serializable);
            try
            {
                var ids = r.Plans.Select(p => p.PlanId).ToArray();
                var ps = (await db.QueryAsync<(long PlanId, string WhsCode, string Jenis, string Status, string CardCode, string? CardName, bool? Titipan)>(
                    "SELECT p.PlanId, p.WhsCode, p.Jenis, p.Status, p.CardCode, p.CardName, CAST(COALESCE(p.Titipan, rm.Titipan, 0) AS BIT) AS Titipan FROM WHS_Plan p LEFT JOIN WHS_MasterRuangan rm ON rm.KodeRuangan = p.KodeRuangan WHERE p.PlanId IN @ids", new { ids }, tx)).ToList();
                if (ps.Count != ids.Length) return Bad("Ada SPMB yang tidak ditemukan");
                if (ps.Any(p => p.Jenis != "SPMB")) return Bad("Surat Jalan hanya untuk SPMB");
                // Satu mobil bisa memuat SPMB dari beberapa kode gudang dalam satu area (OWHS.State) -> satu Surat Jalan gabungan
                var area = await Area.Gudang(db, tx, r.WhsCode);
                if (ps.Any(p => !area.Contains(p.WhsCode, StringComparer.OrdinalIgnoreCase))) return Bad("SPMB harus dari kode gudang dalam satu area");
                if (r.WhsCode != "ATM") { /* aturan: hanya Gudang ATM */ if (!(await db.ExecuteScalarAsync<string?>("SELECT WhsName FROM OWHS WHERE WhsCode = @w", new { w = r.WhsCode }, tx) ?? "").Contains("ATM", StringComparison.OrdinalIgnoreCase)) return Bad("Surat Jalan hanya untuk Gudang ATM"); }
                if (ps.Any(p => p.Status is not ("Selesai" or "SelesaiKurang"))) return Bad("SPMB harus sudah selesai dimuat");
                if (ps.Select(p => p.Titipan ?? false).Distinct().Count() > 1) return Bad("Titipan dan non-titipan tidak boleh dicampur dalam satu Surat Jalan");
                if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_SuratJalanPlan WHERE PlanId IN @ids AND Aktif = 1", new { ids }, tx) > 0) return Bad("Ada SPMB yang sudah punya Surat Jalan aktif");

                string? plat = null, cont = null, sopir = null;
                if (r.RegId is not null)
                {
                    var k = await db.QueryFirstOrDefaultAsync<(string NoPolisi, string? ContainerNo, string Sopir, string WhsCode)?>("SELECT NoPolisi, ContainerNo, Sopir, WhsCode FROM WHS_Kendaraan WHERE RegId = @id", new { id = r.RegId }, tx);
                    if (k is null || !area.Contains(k.Value.WhsCode, StringComparer.OrdinalIgnoreCase)) return Bad("Kendaraan tidak ditemukan di area gudang ini");
                    (plat, cont, sopir) = (k.Value.NoPolisi, k.Value.ContainerNo, k.Value.Sopir);
                }
                var prefix = $"SJ/{r.TglSj:yyMM}/";
                var last = await db.ExecuteScalarAsync<string?>("SELECT TOP 1 SjNo FROM WHS_SuratJalan WITH (UPDLOCK, HOLDLOCK) WHERE SjNo LIKE @p ORDER BY SjNo DESC", new { p = prefix + "%" }, tx);
                var sjNo = prefix + ((last is null ? 0 : int.Parse(last[prefix.Length..])) + 1).ToString("0000");
                var sjId = await db.ExecuteScalarAsync<long>(@"INSERT WHS_SuratJalan (SjNo, TglSj, RegId, NoPolisi, ContainerNo, Sopir, TotalKg, Catatan, Status, CreatedBy)
                    OUTPUT INSERTED.SjId VALUES (@no, @tgl, @reg, @plat, @cont, @sopir, 0, @cat, 'Terbit', @uid)",
                    new { no = sjNo, tgl = r.TglSj.Date, reg = r.RegId, plat, cont, sopir, cat = r.Catatan, uid = u.UserId() }, tx);
                foreach (var pr in r.Plans)
                {
                    var p = ps.First(x => x.PlanId == pr.PlanId);
                    await db.ExecuteAsync("INSERT WHS_SuratJalanPlan (SjId, PlanId, CardCode, CardName, NumAtCard, AlamatKirim) VALUES (@sjId, @pid, @cc, @cn, @po, @al)",
                        new { sjId, pid = pr.PlanId, cc = p.CardCode, cn = p.CardName, po = pr.NumAtCard, al = pr.AlamatKirim.Trim() }, tx);
                }
                // baris = qty yang benar-benar dimuat (hasil scan), bukan qty rencana
                // Surat Jalan = dasar DO: baris per item + No. BL + PT dari transaksi keluar SPMB (qty yang benar-benar dimuat)
                await db.ExecuteAsync(@"INSERT WHS_SuratJalan1 (SjId, SjLine, PlanId, PlanLine, ItemCode, Dscription, QtyPlan, QtyMuat, QtySak, QtyPalet, NoBL, PtCode)
                    SELECT @sjId, ROW_NUMBER() OVER (ORDER BY h.PlanId, d.PlanLine, d.NoBL), h.PlanId, d.PlanLine, d.ItemCode, MAX(p1.Dscription), MAX(p1.QtyPlan),
                           SUM(d.qty), CAST(SUM(ISNULL(d.Qty2, 0)) AS INT), CAST(SUM(ISNULL(d.QtyPalet, 0)) AS INT), NULLIF(d.NoBL, ''), COALESCE(NULLIF(d.U_IDU_Kode_PT, ''), MAX(h.U_IDU_Kode_PT))
                    FROM OKRN h JOIN KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
                    LEFT JOIN WHS_Plan1 p1 ON p1.PlanId = h.PlanId AND p1.PlanLine = d.PlanLine
                    WHERE h.PlanId IN @ids AND d.flags = -1
                    GROUP BY h.PlanId, d.PlanLine, d.ItemCode, NULLIF(d.NoBL, ''), d.U_IDU_Kode_PT", new { sjId, ids }, tx);
                await db.ExecuteAsync("UPDATE WHS_SuratJalan SET TotalKg = (SELECT ISNULL(SUM(QtyMuat),0) FROM WHS_SuratJalan1 WHERE SjId = @sjId), TotalSak = (SELECT SUM(QtySak) FROM WHS_SuratJalan1 WHERE SjId = @sjId) WHERE SjId = @sjId", new { sjId }, tx);
                await Audit.Write(db, tx, u, ctx, "SJ_BUAT", "SURAT_JALAN", sjId, $"{sjNo} {r.Plans.Count} SPMB");
                await tx.CommitAsync();
                return Results.Ok(new { sjId, sjNo });
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

        cms.MapPost("/surat-jalan/{id:long}/batal", async (long id, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            var n = await db.ExecuteAsync("UPDATE WHS_SuratJalan SET Status = 'Batal', BatalBy = @u, BatalAt = SYSDATETIME() WHERE SjId = @id AND Status <> 'Batal'", new { id, u = u.UserId() });
            if (n == 0) return Bad("Surat Jalan tidak ditemukan atau sudah batal");
            await Audit.Safe(db, u, ctx, "SJ_BATAL", "SURAT_JALAN", id, null);
            return Results.Ok();
        });
    }
}
