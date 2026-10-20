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
SELECT p.PlanId AS planId, p.PlanNo AS planNo, p.CardCode AS cardCode, p.CardName AS cardName, r.Titipan AS titipan,
       (SELECT SUM(QtyDone) FROM WHS_Plan1 WHERE PlanId = p.PlanId) AS kg,
       (SELECT TOP 1 NumAtCard FROM WHS_SuratJalanPlan WHERE PlanId = p.PlanId ORDER BY SjId DESC) AS poTerakhir
FROM WHS_Plan p LEFT JOIN WHS_MasterRuangan r ON r.KodeRuangan = p.KodeRuangan
WHERE p.WhsCode = @whs AND p.Jenis = 'SPMB' AND p.Status IN ('Selesai','SelesaiKurang')
  AND NOT EXISTS (SELECT 1 FROM WHS_SuratJalanPlan s WHERE s.PlanId = p.PlanId AND s.Aktif = 1)
ORDER BY p.PlanId DESC", new { whs }));
        });

        cms.MapGet("/surat-jalan", async (string whs, string? status) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(@"
SELECT TOP 200 s.SjId AS sjId, s.SjNo AS sjNo, s.TglSj AS tglSj, s.NoPolisi AS noPolisi, s.ContainerNo AS containerNo, s.Sopir AS sopir, s.TotalKg AS totalKg, s.Status AS status,
       (SELECT COUNT(*) FROM WHS_SuratJalanPlan WHERE SjId = s.SjId) AS jumlahSpmb
FROM WHS_SuratJalan s
WHERE EXISTS (SELECT 1 FROM WHS_SuratJalanPlan sp JOIN WHS_Plan p ON p.PlanId = sp.PlanId WHERE sp.SjId = s.SjId AND p.WhsCode = @whs)
  AND (@status IS NULL OR s.Status = @status) ORDER BY s.SjId DESC", new { whs, status = string.IsNullOrWhiteSpace(status) ? null : status }));
        });

        cms.MapGet("/surat-jalan/{id:long}", async (long id) =>
        {
            await using var db = dbf();
            var h = await db.QueryFirstOrDefaultAsync("SELECT SjId AS sjId, SjNo AS sjNo, TglSj AS tglSj, RegId AS regId, NoPolisi AS noPolisi, ContainerNo AS containerNo, Sopir AS sopir, TotalKg AS totalKg, TotalSak AS totalSak, TotalPalet AS totalPalet, Catatan AS catatan, Status AS status FROM WHS_SuratJalan WHERE SjId = @id", new { id });
            if (h is null) return Results.NotFound();
            var plans = await db.QueryAsync("SELECT sp.PlanId AS planId, p.PlanNo AS planNo, sp.CardCode AS cardCode, sp.CardName AS cardName, sp.NumAtCard AS numAtCard, sp.AlamatKirim AS alamatKirim FROM WHS_SuratJalanPlan sp JOIN WHS_Plan p ON p.PlanId = sp.PlanId WHERE sp.SjId = @id", new { id });
            var lines = await db.QueryAsync("SELECT SjLine AS sjLine, PlanId AS planId, ItemCode AS itemCode, Dscription AS dscription, QtyPlan AS qtyPlan, QtyMuat AS qtyMuat, QtySak AS qtySak, QtyPalet AS qtyPalet FROM WHS_SuratJalan1 WHERE SjId = @id ORDER BY SjLine", new { id });
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
                    "SELECT p.PlanId, p.WhsCode, p.Jenis, p.Status, p.CardCode, p.CardName, rm.Titipan FROM WHS_Plan p LEFT JOIN WHS_MasterRuangan rm ON rm.KodeRuangan = p.KodeRuangan WHERE p.PlanId IN @ids", new { ids }, tx)).ToList();
                if (ps.Count != ids.Length) return Bad("Ada SPMB yang tidak ditemukan");
                if (ps.Any(p => p.Jenis != "SPMB")) return Bad("Surat Jalan hanya untuk SPMB");
                if (ps.Any(p => p.WhsCode != r.WhsCode)) return Bad("SPMB harus dari gudang yang sama");
                if (r.WhsCode != "ATM") { /* aturan: hanya Gudang ATM */ if (!(await db.ExecuteScalarAsync<string?>("SELECT WhsName FROM OWHS WHERE WhsCode = @w", new { w = r.WhsCode }, tx) ?? "").Contains("ATM", StringComparison.OrdinalIgnoreCase)) return Bad("Surat Jalan hanya untuk Gudang ATM"); }
                if (ps.Any(p => p.Status is not ("Selesai" or "SelesaiKurang"))) return Bad("SPMB harus sudah selesai dimuat");
                if (ps.Select(p => p.Titipan ?? false).Distinct().Count() > 1) return Bad("Titipan dan non-titipan tidak boleh dicampur dalam satu Surat Jalan");
                if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_SuratJalanPlan WHERE PlanId IN @ids AND Aktif = 1", new { ids }, tx) > 0) return Bad("Ada SPMB yang sudah punya Surat Jalan aktif");

                string? plat = null, cont = null, sopir = null;
                if (r.RegId is not null)
                {
                    var k = await db.QueryFirstOrDefaultAsync<(string NoPolisi, string? ContainerNo, string Sopir, string WhsCode)?>("SELECT NoPolisi, ContainerNo, Sopir, WhsCode FROM WHS_Kendaraan WHERE RegId = @id", new { id = r.RegId }, tx);
                    if (k is null || k.Value.WhsCode != r.WhsCode) return Bad("Kendaraan tidak ditemukan di gudang ini");
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
                await db.ExecuteAsync(@"INSERT WHS_SuratJalan1 (SjId, SjLine, PlanId, ItemCode, Dscription, QtyPlan, QtyMuat, QtySak, QtyPalet)
                    SELECT @sjId, ROW_NUMBER() OVER (ORDER BY PlanId, PlanLine), PlanId, ItemCode, Dscription, QtyPlan, QtyDone, CAST(Qty2Done AS INT), NULL
                    FROM WHS_Plan1 WHERE PlanId IN @ids AND QtyDone > 0", new { sjId, ids }, tx);
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
