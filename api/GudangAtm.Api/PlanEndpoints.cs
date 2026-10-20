using System.Data;
using System.Globalization;
using System.Security.Claims;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

public record PlanLineReq(int BaseDocEntry, int BaseLineNum, decimal QtyPlan, string? ContainerNo, string? KodeRuangan, string? PaletCode, int? PaletPlan, string? FreeTxt);
public record PlanCreateReq(string Jenis, string WhsCode, string Src, List<int> Docs, string KodeRuangan, string? CardCodeTitipan,
    string? PtCode, string? JenisContainer, string? EtaDatang, DateTime? TglJadwal, List<int>? Kranis, List<PlanLineReq> Lines);
public record PlanKraniReq(List<int> Kranis);
public record PlanTutupReq(string Alasan);

/// SPBB (inbound dari BL/DO) dan SPMB (outbound dari SO): sumber SAP, terbit, alokasi qty, ruangan/titipan, penugasan krani, tutup sisa.
public static class PlanEndpoints
{
    static IResult Bad(string m) => Results.BadRequest(new { message = m });
    static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    // Tabel SAP sumber (kolom ASUMSI, cek ke skema asli): header, baris, kolom jumlah-per-kemasan
    static (string H, string L)? Tbl(string src) => src switch { "BL" => ("OPBL", "PBL1"), "DO" => ("ODLN", "DLN1"), "SO" => ("ORDR", "RDR1"), _ => null };

    public static bool Iso6346(string? c)
    {
        if (c is null || !Regex.IsMatch(c, @"^[A-Z]{4}\d{7}$")) return false;
        var vals = new Dictionary<char, int>(); var n = 10;
        for (var ch = 'A'; ch <= 'Z'; ch++) { if (n % 11 == 0) n++; vals[ch] = n++; }
        long sum = 0;
        for (var i = 0; i < 10; i++) sum += (i < 4 ? vals[c[i]] : c[i] - '0') * (1L << i);
        return (int)(sum % 11 % 10) == c[10] - '0';
    }

    static string NormCont(string? s) => (s ?? "").ToUpperInvariant().Replace(" ", "").Replace("-", "");

    static bool TryEta(string? s, out TimeSpan? t)
    {
        t = null;
        if (string.IsNullOrWhiteSpace(s)) return true;
        if (!Regex.IsMatch(s.Trim(), @"^([01]\d|2[0-3]):[0-5]\d$")) return false;
        t = TimeSpan.ParseExact(s.Trim(), @"hh\:mm", CultureInfo.InvariantCulture);
        return true;
    }

    static async Task<bool> PunyaAkses(SqlConnection db, SqlTransaction? tx, int uid, string whs) =>
        await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM USR9 WHERE UserId = @uid AND WhsCode = @whs", new { uid, whs }, tx) > 0;

    public static void MapPlan(this RouteGroupBuilder cms, Func<SqlConnection> dbf)
    {
        // Dokumen SAP terbuka yang bisa dijadikan dasar plan
        cms.MapGet("/plan/sumber", async (string src, string? q, ClaimsPrincipal u) =>
        {
            var t = Tbl(src); if (t is null) return Bad("Sumber harus BL, DO, atau SO");
            var like = $"%{(q ?? "").Trim()}%";
            await using var db = dbf();
            var ptCol = src == "SO" ? "NULL" : "h.U_IDU_KODE_PT";
            var sql = $@"
SELECT TOP 100 h.DocEntry AS docEntry, h.DocNum AS docNum, h.CardCode AS cardCode, h.CardName AS cardName, h.DocDate AS docDate,
       h.NumAtCard AS numAtCard, {ptCol} AS ptCode
FROM {t.Value.H} h
WHERE h.CANCELED = 'N' AND h.DocStatus = 'O' AND h.DocType = 'I' AND h.DocDate <= GETDATE() AND h.BPLId = @bplId
  AND (CAST(h.DocNum AS NVARCHAR(20)) LIKE @like OR h.CardName LIKE @like OR h.CardCode LIKE @like OR h.NumAtCard LIKE @like)
  AND EXISTS (SELECT 1 FROM {t.Value.L} l WHERE l.DocEntry = h.DocEntry AND l.OpenQty > 0)
ORDER BY h.DocDate DESC, h.DocNum DESC";
            return Results.Ok(await db.QueryAsync(sql, new { like, bplId = u.BplId() }));
        });

        cms.MapGet("/plan/sumber/{src}/{docEntry:int}", async (string src, int docEntry, ClaimsPrincipal u) =>
        {
            var t = Tbl(src); if (t is null) return Bad("Sumber harus BL, DO, atau SO");
            await using var db = dbf();
            var head = await db.QueryFirstOrDefaultAsync($@"SELECT DocEntry AS docEntry, DocNum AS docNum, CardCode AS cardCode, CardName AS cardName, DocDate AS docDate, NumAtCard AS numAtCard
                FROM {t.Value.H} WHERE DocEntry = @docEntry AND BPLId = @bplId", new { docEntry, bplId = u.BplId() });
            if (head is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan" });
            var lines = src == "SO"
                ? await db.QueryAsync($@"SELECT l.LineNum AS lineNum, l.ItemCode AS itemCode, l.Dscription AS dscription, l.Quantity AS qty, l.OpenQty AS openQty,
                      ISNULL(a.Teralokasi, 0) AS teralokasi, l.OpenQty - ISNULL(a.Teralokasi, 0) AS tersedia, l.U_IDU_QtyPack AS qtyPack, l.FreeTxt AS freeTxt,
                      NULL AS containerNo, NULL AS brandName, NULL AS size, NULL AS [type], NULL AS crop
                  FROM {t.Value.L} l LEFT JOIN vw_WHS_PlanAlokasi a ON a.BaseType = 'SO' AND a.BaseDocEntry = l.DocEntry AND a.BaseLineNum = l.LineNum
                  WHERE l.DocEntry = @docEntry AND l.OpenQty > 0 ORDER BY l.LineNum", new { docEntry })
                : await db.QueryAsync($@"SELECT l.LineNum AS lineNum, l.ItemCode AS itemCode, l.Dscription AS dscription, l.Quantity AS qty, l.OpenQty AS openQty,
                      ISNULL(a.Teralokasi, 0) AS teralokasi, l.OpenQty - ISNULL(a.Teralokasi, 0) AS tersedia, l.U_IDU_QtyPack AS qtyPack, l.FreeTxt AS freeTxt,
                      l.ShipToCode AS containerNo, l.StgDesc AS brandName, l.SerialNum AS size, l.BaseAtCard AS [type], l.BlockNum AS crop
                  FROM {t.Value.L} l LEFT JOIN vw_WHS_PlanAlokasi a ON a.BaseType = @src AND a.BaseDocEntry = l.DocEntry AND a.BaseLineNum = l.LineNum
                  WHERE l.DocEntry = @docEntry AND l.OpenQty > 0 ORDER BY l.LineNum", new { docEntry, src });
            return Results.Ok(new { header = head, lines });
        });

        // Krani yang punya akses ke warehouse (untuk penugasan)
        cms.MapGet("/plan/krani", async (string whs) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync("SELECT u.USERID AS userId, u.USER_CODE AS userCode, u.U_NAME AS name FROM OUSR u JOIN USR9 a ON a.UserId = u.USERID WHERE a.WhsCode = @whs ORDER BY u.USER_CODE", new { whs }));
        });

        cms.MapGet("/plan", async (string? status, string? jenis, string? whs, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(@"
SELECT TOP 300 p.PlanId AS planId, p.PlanNo AS planNo, p.Jenis AS jenis, p.WhsCode AS whsCode, p.CardName AS cardName, p.Status AS status, p.CloseReason AS closeReason,
       p.KodeRuangan AS kodeRuangan, r.Titipan AS titipan, p.CardCodeTitipan AS cardCodeTitipan, p.TglJadwal AS tglJadwal, p.EtaDatang AS etaDatang,
       (SELECT SUM(QtyPlan) FROM WHS_Plan1 WHERE PlanId = p.PlanId) AS qtyPlan, (SELECT SUM(QtyDone) FROM WHS_Plan1 WHERE PlanId = p.PlanId) AS qtyDone,
       (SELECT STRING_AGG(CAST(BaseDocNum AS NVARCHAR(20)), ', ') FROM WHS_PlanDoc WHERE PlanId = p.PlanId) AS dokumen, p.CreatedAt AS createdAt
FROM WHS_Plan p LEFT JOIN WHS_MasterRuangan r ON r.KodeRuangan = p.KodeRuangan
WHERE (@status IS NULL OR p.Status = @status) AND (@jenis IS NULL OR p.Jenis = @jenis) AND (@whs IS NULL OR p.WhsCode = @whs)
  AND EXISTS (SELECT 1 FROM USR9 a WHERE a.UserId = @uid AND a.WhsCode = p.WhsCode)
ORDER BY CASE WHEN p.Status IN ('Terbit','Proses','Partial') THEN 0 ELSE 1 END, p.PlanId DESC",
                new { status = Clean(status), jenis = Clean(jenis), whs = Clean(whs), uid = u.UserId() }));
        });

        cms.MapGet("/plan/{id:long}", async (long id, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var p = await db.QueryFirstOrDefaultAsync(@"SELECT p.*, r.NamaRuangan AS namaRuangan, r.Titipan AS titipan FROM WHS_Plan p LEFT JOIN WHS_MasterRuangan r ON r.KodeRuangan = p.KodeRuangan WHERE p.PlanId = @id", new { id });
            if (p is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan" });
            if (!await PunyaAkses(db, null, u.UserId(), (string)p.WhsCode)) return Results.Forbid();
            var docs = await db.QueryAsync("SELECT BaseType AS baseType, BaseDocEntry AS baseDocEntry, BaseDocNum AS baseDocNum, CardCode AS cardCode, CardName AS cardName, NumAtCard AS numAtCard FROM WHS_PlanDoc WHERE PlanId = @id", new { id });
            var lines = await db.QueryAsync("SELECT * FROM WHS_Plan1 WHERE PlanId = @id ORDER BY PlanLine", new { id });
            var kranis = await db.QueryAsync("SELECT k.UserId AS userId, u.USER_CODE AS userCode FROM WHS_PlanKrani k JOIN OUSR u ON u.USERID = k.UserId WHERE k.PlanId = @id", new { id });
            return Results.Ok(new { header = p, docs, lines, kranis });
        });

        // ------------------------------------------------------------ Terbitkan
        cms.MapPost("/plan", async (PlanCreateReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var jenis = (r.Jenis ?? "").ToUpperInvariant();
            var src = (r.Src ?? "").ToUpperInvariant();
            if (jenis is not ("SPBB" or "SPMB")) return Bad("Jenis harus SPBB atau SPMB");
            if (jenis == "SPBB" ? src is not ("BL" or "DO") : src != "SO") return Bad(jenis == "SPBB" ? "SPBB dari BL atau DO" : "SPMB dari Sales Order");
            var t = Tbl(src)!.Value;
            var docs = (r.Docs ?? new()).Distinct().ToList();
            if (docs.Count == 0) return Bad("Pilih dokumen dasar");
            if (jenis == "SPBB" && docs.Count != 1) return Bad("SPBB hanya dari satu BL/DO");
            if (r.Lines is null || r.Lines.Count == 0 || r.Lines.Count > 300) return Bad("Pilih minimal satu item (maks 300)");
            if (!TryEta(r.EtaDatang, out var eta)) return Bad("ETA format JJ:MM, contoh 08:30");
            if (r.TglJadwal is { } tg && tg.Date < DateTime.Today) return Bad("Tanggal jadwal tidak boleh sebelum hari ini");

            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.Serializable);
            try
            {
                if (!await PunyaAkses(db, tx, u.UserId(), r.WhsCode)) return Results.Forbid();
                var room = await db.QueryFirstOrDefaultAsync<(string WhsCode, bool Titipan, bool Aktif)?>("SELECT WhsCode, Titipan, Aktif FROM WHS_MasterRuangan WHERE KodeRuangan = @k", new { k = r.KodeRuangan }, tx);
                if (room is null || room.Value.WhsCode != r.WhsCode || !room.Value.Aktif) return Bad("Ruangan tidak valid untuk warehouse ini");
                var titipan = room.Value.Titipan;
                string? titCode = Clean(r.CardCodeTitipan), titName = null;
                if (titipan)
                {
                    if (titCode is null) return Bad("Ruangan titipan: kode customer titipan wajib diisi");
                    titName = await db.ExecuteScalarAsync<string?>("SELECT CardName FROM OCRD WHERE CardCode = @c AND CardType = 'C'", new { c = titCode }, tx);
                    if (titName is null) return Bad("Kode customer titipan tidak ada di master customer");
                }
                else titCode = null;

                // header SAP
                var heads = (await db.QueryAsync<(int DocEntry, int DocNum, string? CardCode, string? CardName, string? NumAtCard, DateTime? DocDate)>(
                    $"SELECT DocEntry, DocNum, CardCode, CardName, NumAtCard, DocDate FROM {t.H} WHERE DocEntry IN @docs AND CANCELED = 'N' AND DocStatus = 'O' AND DocType = 'I' AND BPLId = @bpl",
                    new { docs, bpl = u.BplId() }, tx)).ToList();
                if (heads.Count != docs.Count) return Bad("Ada dokumen yang sudah tertutup/batal/bukan cabang Anda");
                if (jenis == "SPMB" && heads.Select(h => h.CardCode).Distinct().Count() > 1) return Bad("Satu SPMB hanya untuk satu customer");

                string? pt = Clean(r.PtCode);
                if (jenis == "SPBB")
                {
                    pt ??= await db.ExecuteScalarAsync<string?>($"SELECT U_IDU_KODE_PT FROM {t.H} WHERE DocEntry = @d", new { d = docs[0] }, tx);
                    if (string.IsNullOrWhiteSpace(pt)) return Bad("PT kosong di dokumen · pilih PT");
                    if (await db.ExecuteScalarAsync<int>(Sql.PtExists, new { ptCode = pt }, tx) == 0) return Bad("PT tidak ada di OPRC");
                }

                // batas muatan container (SPMB), peringatan saja
                string? jc = Clean(r.JenisContainer); decimal? batas = null;
                if (jenis == "SPMB" && jc is not null)
                {
                    batas = await db.ExecuteScalarAsync<decimal?>("SELECT BatasMuatanKg FROM WHS_MasterJenisContainer WHERE Kode = @k AND Aktif = 1", new { k = jc }, tx);
                    if (batas is null) return Bad("Jenis container tidak ada di master");
                }

                // baris
                var seen = new HashSet<(int, int)>();
                var rows = new List<(PlanLineReq q, dynamic sap, string room, decimal karung)>();
                var warnings = new List<string>();
                foreach (var l in r.Lines)
                {
                    if (!docs.Contains(l.BaseDocEntry)) return Bad("Baris dari dokumen yang tidak dipilih");
                    if (!seen.Add((l.BaseDocEntry, l.BaseLineNum))) return Bad("Baris dobel");
                    if (l.QtyPlan <= 0 || l.QtyPlan > 10_000_000) return Bad("Qty plan harus lebih dari 0");
                    var colsBl = src == "SO" ? "NULL AS ShipToCode, NULL AS StgDesc, NULL AS SerialNum, NULL AS BaseAtCard, NULL AS BlockNum" : "ShipToCode, StgDesc, SerialNum, BaseAtCard, BlockNum";
                    var sap = await db.QueryFirstOrDefaultAsync($"SELECT ItemCode, Dscription, Quantity, OpenQty, U_IDU_QtyPack, FreeTxt, {colsBl} FROM {t.L} WHERE DocEntry = @d AND LineNum = @n AND OpenQty > 0", new { d = l.BaseDocEntry, n = l.BaseLineNum }, tx);
                    if (sap is null) return Bad($"Baris {l.BaseLineNum + 1} dokumen {l.BaseDocEntry} sudah tidak terbuka");
                    var alok = await db.ExecuteScalarAsync<decimal?>("SELECT Teralokasi FROM vw_WHS_PlanAlokasi WITH (UPDLOCK, HOLDLOCK) WHERE BaseType = @s AND BaseDocEntry = @d AND BaseLineNum = @n", new { s = src, d = l.BaseDocEntry, n = l.BaseLineNum }, tx) ?? 0;
                    var tersedia = (decimal)sap.OpenQty - alok;
                    if (l.QtyPlan > tersedia) return Bad($"{sap.ItemCode}: qty {l.QtyPlan:N0} melebihi tersedia {tersedia:N0}");

                    var lineRoom = Clean(l.KodeRuangan) ?? r.KodeRuangan;
                    var lr = await db.QueryFirstOrDefaultAsync<(string WhsCode, bool Titipan, bool Aktif)?>("SELECT WhsCode, Titipan, Aktif FROM WHS_MasterRuangan WHERE KodeRuangan = @k", new { k = lineRoom }, tx);
                    if (lr is null || lr.Value.WhsCode != r.WhsCode || !lr.Value.Aktif) return Bad($"{sap.ItemCode}: ruangan tidak valid");
                    if (lr.Value.Titipan != titipan) return Bad($"{sap.ItemCode}: titipan dan non-titipan tidak boleh dicampur dalam satu dokumen");

                    if (jenis == "SPBB")
                    {
                        if (string.IsNullOrWhiteSpace(l.PaletCode) || await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_MasterPalet WHERE PaletCode = @p AND Aktif = 1", new { p = l.PaletCode }, tx) == 0)
                            return Bad($"{sap.ItemCode}: jenis palet wajib dipilih dari master");
                        if (src == "BL")
                        {
                            var c = NormCont((string?)sap.ShipToCode);
                            if (!Iso6346(c)) return Bad($"{sap.ItemCode}: nomor container BL tidak valid (ISO 6346)");
                        }
                        else if (Clean(l.ContainerNo) is { } cc && !Iso6346(NormCont(cc))) return Bad($"{sap.ItemCode}: nomor container tidak valid (ISO 6346)");
                    }
                    var pack = sap.U_IDU_QtyPack is null ? 0m : (decimal)sap.U_IDU_QtyPack;
                    var quantity = (decimal)sap.Quantity;
                    var karung = quantity > 0 ? Math.Round(l.QtyPlan * pack / quantity) : 0;
                    rows.Add((l, sap, lineRoom, karung));
                }

                var total = rows.Sum(x => x.q.QtyPlan);
                if (batas is not null && total > batas) warnings.Add($"Total {total:N0} kg melebihi batas muatan {batas:N0} kg");

                // nomor dokumen: SPBB/yymm/####
                var prefix = $"{jenis}/{DateTime.Today:yyMM}/";
                var last = await db.ExecuteScalarAsync<string?>("SELECT TOP 1 PlanNo FROM WHS_Plan WITH (UPDLOCK, HOLDLOCK) WHERE PlanNo LIKE @p ORDER BY PlanNo DESC", new { p = prefix + "%" }, tx);
                var no = prefix + ((last is null ? 0 : int.Parse(last[prefix.Length..])) + 1).ToString("0000");

                var h0 = heads[0];
                var planId = await db.ExecuteScalarAsync<long>(@"
INSERT WHS_Plan (PlanNo, Jenis, WhsCode, BplId, BaseType, JenisContainer, BatasMuatanKg, TotalPlanKg, CardCode, CardName, U_IDU_Kode_PT, Status, CreatedBy,
                 TglJadwal, EtaDatang, KodeRuangan, CardCodeTitipan, CardNameTitipan)
OUTPUT INSERTED.PlanId
VALUES (@no, @jenis, @whs, @bpl, @src, @jc, @batas, @total, @cc, @cn, @pt, 'Terbit', @uid, @tgl, @eta, @room, @tc, @tn)",
                    new { no, jenis, whs = r.WhsCode, bpl = u.BplId(), src, jc, batas, total, cc = h0.CardCode, cn = h0.CardName, pt, uid = u.UserId(), tgl = r.TglJadwal?.Date, eta, room = r.KodeRuangan, tc = titCode, tn = titName }, tx);

                foreach (var h in heads)
                    await db.ExecuteAsync("INSERT WHS_PlanDoc (PlanId, BaseType, BaseDocEntry, BaseObjType, BaseDocNum, CardCode, CardName, NumAtCard, BaseDocDate) VALUES (@planId, @src, @de, NULL, @dn, @cc, @cn, @na, @dd)",
                        new { planId, src, de = h.DocEntry, dn = h.DocNum, cc = h.CardCode, cn = h.CardName, na = h.NumAtCard, dd = h.DocDate }, tx);

                var line = 0;
                foreach (var (q, sap, lineRoom, karung) in rows)
                {
                    line++;
                    await db.ExecuteAsync(@"
INSERT WHS_Plan1 (PlanId, PlanLine, BaseType, BaseDocEntry, BaseLineNum, ContainerNo, ItemCode, Dscription, FreeTxt, BrandName, Size, [Type], Crop,
                  QtyBase, OpenQtyBase, QtyPlan, Qty2Plan, PaletCode, PaletPlan, KodeRuangan)
VALUES (@planId, @line, @src, @de, @ln, @cont, @item, @desc, @free, @brand, @size, @type, @crop, @qb, @oq, @qp, @q2, @pal, @palN, @room)",
                        new
                        {
                            planId, line, src, de = q.BaseDocEntry, ln = q.BaseLineNum,
                            cont = src == "BL" ? NormCont((string?)sap.ShipToCode) : Clean(q.ContainerNo) is { } c ? NormCont(c) : null,
                            item = (string)sap.ItemCode, desc = (string?)sap.Dscription, free = Clean(q.FreeTxt) ?? (string?)sap.FreeTxt,
                            brand = (string?)sap.StgDesc, size = (string?)sap.SerialNum, type = (string?)sap.BaseAtCard, crop = (string?)sap.BlockNum,
                            qb = (decimal)sap.Quantity, oq = (decimal)sap.OpenQty, qp = q.QtyPlan, q2 = karung,
                            pal = jenis == "SPBB" ? q.PaletCode : null, palN = jenis == "SPBB" ? q.PaletPlan : null, room = lineRoom,
                        }, tx);
                }

                foreach (var k in (r.Kranis ?? new()).Distinct())
                {
                    if (!await PunyaAkses(db, tx, k, r.WhsCode)) return Bad("Krani tidak punya akses ke warehouse ini");
                    await db.ExecuteAsync("INSERT WHS_PlanKrani (PlanId, UserId) VALUES (@planId, @k)", new { planId, k }, tx);
                }

                await Audit.Write(db, tx, u, ctx, "PLAN_TERBIT", jenis, planId, $"{no} {src} {string.Join(",", heads.Select(h => h.DocNum))} {total:N0} kg ruangan={r.KodeRuangan}");
                await tx.CommitAsync();
                return Results.Ok(new { planId, planNo = no, warnings });
            }
            catch (SqlException e) when (e.Number == 50000 || e.Class == 16)
            {
                try { await tx.RollbackAsync(); } catch { }
                return Bad(e.Message); // pesan dari trigger (titipan/customer/ruangan)
            }
            catch
            {
                try { await tx.RollbackAsync(); } catch { }
                throw;
            }
        });

        cms.MapPut("/plan/{id:long}/krani", async (long id, PlanKraniReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync();
            var p = await db.QueryFirstOrDefaultAsync<(string WhsCode, string Status)?>("SELECT WhsCode, Status FROM WHS_Plan WHERE PlanId = @id", new { id }, tx);
            if (p is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan" });
            if (!await PunyaAkses(db, tx, u.UserId(), p.Value.WhsCode)) return Results.Forbid();
            if (p.Value.Status is "Selesai" or "SelesaiKurang" or "Batal") return Bad("Dokumen sudah selesai");
            await db.ExecuteAsync("DELETE FROM WHS_PlanKrani WHERE PlanId = @id", new { id }, tx);
            foreach (var k in (r.Kranis ?? new()).Distinct())
            {
                if (!await PunyaAkses(db, tx, k, p.Value.WhsCode)) return Bad("Krani tidak punya akses ke warehouse ini");
                await db.ExecuteAsync("INSERT WHS_PlanKrani (PlanId, UserId) VALUES (@id, @k)", new { id, k }, tx);
            }
            await Audit.Write(db, tx, u, ctx, "PLAN_KRANI", "PLAN", id, $"{(r.Kranis ?? new()).Count} krani");
            await tx.CommitAsync();
            return Results.Ok();
        });

        // Tutup sisa outstanding (Partial -> SelesaiKurang)
        cms.MapPost("/plan/{id:long}/tutup-sisa", async (long id, PlanTutupReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var alasan = (r.Alasan ?? "").Trim();
            var ok = new[] { "Supplier kurang kirim", "Barang rusak/ditolak", "Sisa dibatalkan Admin" };
            if (!ok.Contains(alasan)) return Bad("Pilih alasan penutupan");
            await using var db = dbf();
            var p = await db.QueryFirstOrDefaultAsync<(string WhsCode, string Status)?>("SELECT WhsCode, Status FROM WHS_Plan WHERE PlanId = @id", new { id });
            if (p is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan" });
            if (!await PunyaAkses(db, null, u.UserId(), p.Value.WhsCode)) return Results.Forbid();
            if (p.Value.Status != "Partial") return Bad("Hanya dokumen Partial yang bisa ditutup sisanya");
            await db.ExecuteAsync("UPDATE WHS_Plan SET Status = 'SelesaiKurang', CloseReason = @a, ClosedBy = @u, ClosedAt = SYSDATETIME() WHERE PlanId = @id", new { id, a = alasan, u = u.UserId() });
            await Audit.Safe(db, u, ctx, "PLAN_TUTUP", "PLAN", id, alasan);
            return Results.Ok();
        });

        cms.MapPost("/plan/{id:long}/batal", async (long id, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            var p = await db.QueryFirstOrDefaultAsync<(string WhsCode, string Status)?>("SELECT WhsCode, Status FROM WHS_Plan WHERE PlanId = @id", new { id });
            if (p is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan" });
            if (!await PunyaAkses(db, null, u.UserId(), p.Value.WhsCode)) return Results.Forbid();
            if (p.Value.Status is not ("Draft" or "Terbit")) return Bad("Hanya dokumen yang belum diproses yang bisa dibatalkan");
            if (await db.ExecuteScalarAsync<decimal>("SELECT ISNULL(SUM(QtyDone), 0) FROM WHS_Plan1 WHERE PlanId = @id", new { id }) > 0) return Bad("Sudah ada penerimaan/pengiriman, tidak bisa dibatalkan");
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_SuratJalanPlan WHERE PlanId = @id AND Aktif = 1", new { id }) > 0) return Bad("Sudah ada di Surat Jalan aktif");
            await db.ExecuteAsync("UPDATE WHS_Plan SET Status = 'Batal', ClosedBy = @u, ClosedAt = SYSDATETIME() WHERE PlanId = @id", new { id, u = u.UserId() });
            await Audit.Safe(db, u, ctx, "PLAN_BATAL", "PLAN", id, null);
            return Results.Ok();
        });
    }

    // ------------------------------------------------------------ untuk krani (hanya baca)
    public static void MapPlanKrani(this RouteGroupBuilder api, Func<SqlConnection> dbf)
    {
        api.MapGet("/plan/saya", async (string? jenis, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            return Results.Ok(await db.QueryAsync(@"
SELECT p.PlanId AS planId, p.PlanNo AS planNo, p.Jenis AS jenis, p.WhsCode AS whsCode, p.CardName AS cardName, p.Status AS status,
       p.KodeRuangan AS kodeRuangan, r.Titipan AS titipan, p.TglJadwal AS tglJadwal, p.EtaDatang AS etaDatang, p.DockCode AS dockCode, p.JadwalMulai AS jadwalMulai,
       (SELECT SUM(QtyPlan) FROM WHS_Plan1 WHERE PlanId = p.PlanId) AS qtyPlan, (SELECT SUM(QtyDone) FROM WHS_Plan1 WHERE PlanId = p.PlanId) AS qtyDone
FROM WHS_Plan p JOIN WHS_PlanKrani k ON k.PlanId = p.PlanId AND k.UserId = @uid
LEFT JOIN WHS_MasterRuangan r ON r.KodeRuangan = p.KodeRuangan
WHERE p.Status IN ('Terbit','Proses','Partial') AND (@jenis IS NULL OR p.Jenis = @jenis)
ORDER BY p.PlanId DESC", new { uid = u.UserId(), jenis = Clean(jenis) }));
        });

        api.MapGet("/plan/{id:long}", async (long id, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var p = await db.QueryFirstOrDefaultAsync(@"SELECT p.PlanId AS planId, p.PlanNo AS planNo, p.Jenis AS jenis, p.WhsCode AS whsCode, p.CardName AS cardName, p.Status AS status,
                p.KodeRuangan AS kodeRuangan, r.Titipan AS titipan, p.CardCodeTitipan AS cardCodeTitipan, p.CardNameTitipan AS cardNameTitipan, p.U_IDU_Kode_PT AS ptCode
                FROM WHS_Plan p JOIN WHS_PlanKrani k ON k.PlanId = p.PlanId AND k.UserId = @uid LEFT JOIN WHS_MasterRuangan r ON r.KodeRuangan = p.KodeRuangan WHERE p.PlanId = @id", new { id, uid = u.UserId() });
            if (p is null) return Results.NotFound(new { message = "Dokumen tidak ditemukan atau bukan tugas Anda" });
            var lines = await db.QueryAsync(@"SELECT PlanLine AS planLine, ItemCode AS itemCode, Dscription AS dscription, ContainerNo AS containerNo, BrandName AS brandName, Size AS size, [Type] AS [type], Crop AS crop,
                QtyPlan AS qtyPlan, Qty2Plan AS qty2Plan, PaletCode AS paletCode, PaletPlan AS paletPlan, KodeRuangan AS kodeRuangan, QtyDone AS qtyDone, QtyOutstanding AS qtyOutstanding, FreeTxt AS freeTxt
                FROM WHS_Plan1 WHERE PlanId = @id ORDER BY PlanLine", new { id });
            return Results.Ok(new { header = p, lines });
        });
    }
}
