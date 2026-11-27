using System.Data;
using System.Security.Claims;
using Dapper;
using Microsoft.Data.SqlClient;

namespace GudangAtm.Api;

/// Stock opname.
/// - Admin: pilih gudang, tanggal, ruangan, bagi per rak; tiap rak dihitung 2 krani berbeda (hitung buta).
/// - Freeze = snapshot saldo dari dokumen terposting bertanggal &lt; tanggal opname. Freeze ulang boleh sebelum posting.
/// - Transaksi bertanggal &gt;= tanggal opname di ruangan opname ditahan (trigger TR_KRN1_OpnameTahan / TR_OKRN_OpnameTahan).
/// - Validasi: hitungan semua rak dijumlah per kunci saldo; Admin pilih H1 / H2 / saldo atau minta hitung ulang rak.
/// - Posting: dokumen OP (ObjType 6720) berisi selisih final - saldo freeze, tanggal = tanggal opname.
public static class OpnameEndpoints
{
    static IResult Bad(string message) => Results.BadRequest(new { message });

    public record RakReq(string KodeRuangan, string KodeRak, string? NamaRak, bool? Aktif);
    public record OpnameRakReq(string KodeRuangan, string KodeRak, int Krani1, int Krani2);
    public record OpnameCreateReq(string WhsCode, DateTime TglOpname, List<OpnameRakReq>? Raks, string? Catatan);
    public record FinalReq(string Kunci, string? Pilihan);
    public record UlangReq(string? Kunci, string? KodeRuangan, string? KodeRak, int? Ke);
    public record HitungLine(string Qr, string? NoBL, bool Titipan, string? PtCode, decimal Sak, decimal Kg, decimal Palet);
    public record HitungReq(string KodeRuangan, string KodeRak, string BarcodeRak, bool Selesai, List<HitungLine>? Lines);

    public static string Barcode(string ruangan, string rak) => $"RAK-{ruangan}-{rak}";

    const string BL = "ISNULL(COALESCE(NULLIF(d.NoBL, ''), CASE WHEN d.flags = 1 THEN NULLIF(h.U_NoBL, '') END), '')";
    const string TIT = "CAST(ISNULL(d.Titipan, CASE WHEN h.TrxCode = 'BT' THEN 1 ELSE 0 END) AS BIT)";
    const string PT = "ISNULL(COALESCE(NULLIF(d.U_IDU_Kode_PT, ''), NULLIF(h.U_IDU_Kode_PT, '')), '')";
    const string CONT = "ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '')";

    /// Saldo per kunci di ruangan opname dari dokumen terposting bertanggal sebelum tanggal opname.
    static readonly string SaldoSaatIni = $@"
SELECT  d.KodeRuangan, d.ItemCode, {CONT} AS ContainerNo, {BL} AS NoBL, {TIT} AS Titipan, {PT} AS PtCode, ISNULL(d.NoLot, '') AS NoLot,
        SUM(d.qty * d.flags) AS Kg, SUM(ISNULL(d.Qty2, 0) * d.flags) AS Sak, SUM(ISNULL(d.QtyPalet, 0) * d.flags) AS Palet
FROM    OKRN h JOIN KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
WHERE   h.DocStatus = 'C' AND h.WhsCode = @whs AND CAST(h.DocDate AS DATE) < @tgl
  AND   d.KodeRuangan IN (SELECT KodeRuangan FROM WHS_OpnameRak WHERE OpnameId = @id)
GROUP BY d.KodeRuangan, d.ItemCode, {CONT}, {BL}, {TIT}, {PT}, ISNULL(d.NoLot, '')
HAVING SUM(d.qty * d.flags) <> 0 OR SUM(ISNULL(d.Qty2, 0) * d.flags) <> 0 OR SUM(ISNULL(d.QtyPalet, 0) * d.flags) <> 0";

    public class Head
    {
        public long OpnameId { get; set; }
        public string OpnameNo { get; set; } = "";
        public string WhsCode { get; set; } = "";
        public int BplId { get; set; }
        public DateTime TglOpname { get; set; }
        public string Status { get; set; } = "";
        public int FreezeKe { get; set; }
        public DateTime? FreezeAt { get; set; }
        public string? FreezeByCode { get; set; }
        public string? PostObjType { get; set; }
        public long? PostDocEntry { get; set; }
        public DateTime? PostedAt { get; set; }
        public string? Catatan { get; set; }
        public string? CreatedByCode { get; set; }
        public DateTime CreatedAt { get; set; }
    }

    public class KeyRow
    {
        public string KodeRuangan { get; set; } = "";
        public string KodeRak { get; set; } = "";
        public byte Ke { get; set; }
        public string Qr { get; set; } = "";
        public string ItemCode { get; set; } = "";
        public string ContainerNo { get; set; } = "";
        public string NoBL { get; set; } = "";
        public bool Titipan { get; set; }
        public string PtCode { get; set; } = "";
        public string NoLot { get; set; } = "";
        public decimal Kg { get; set; }
        public decimal Sak { get; set; }
        public decimal Palet { get; set; }
        public string Kunci => string.Join('|', KodeRuangan, ItemCode, ContainerNo, NoBL, Titipan ? "1" : "0", PtCode, NoLot);
    }

    const string HeadSql = @"
SELECT o.OpnameId, o.OpnameNo, o.WhsCode, o.BplId, o.TglOpname, o.Status, o.FreezeKe, o.FreezeAt, fu.USER_CODE AS FreezeByCode,
       o.PostObjType, o.PostDocEntry, o.PostedAt, o.Catatan, cu.USER_CODE AS CreatedByCode, o.CreatedAt
FROM WHS_Opname o LEFT JOIN OUSR fu ON fu.USERID = o.FreezeBy LEFT JOIN OUSR cu ON cu.USERID = o.CreatedBy
WHERE o.OpnameId = @id AND o.BplId = @bpl";

    /// QR palet: yymmdd-itemcode-container[-L&lt;lot&gt;]; label lama tanpa lot = lot ''.
    public static (string Item, string Container, string Lot, string Yymmdd)? ParseQr(string? qr)
    {
        if (string.IsNullOrWhiteSpace(qr) || qr.Length > 80) return null;
        var parts = qr.Trim().Split('-');
        if (parts.Length < 3 || parts[0].Length != 6 || !parts[0].All(char.IsDigit)) return null;
        var lot = "";
        if (parts.Length >= 4 && parts[^1].Length > 1 && parts[^1][0] == 'L' && parts[^1][1..].All(char.IsDigit))
        {
            lot = parts[^1][1..];
            parts = parts[..^1];
        }
        var item = string.Join('-', parts[1..^1]);
        if (item.Length == 0) return null;
        return (item, parts[^1], lot, parts[0]);
    }

    static async Task Freeze(SqlConnection db, SqlTransaction tx, Head h, int userId)
    {
        await db.ExecuteAsync("DELETE WHS_OpnameSaldo WHERE OpnameId = @id", new { id = h.OpnameId }, tx);
        await db.ExecuteAsync($@"
INSERT WHS_OpnameSaldo (OpnameId, KodeRuangan, ItemCode, ContainerNo, NoBL, Titipan, PtCode, NoLot, Kg, Sak, Palet)
SELECT @id, KodeRuangan, ItemCode, ContainerNo, NoBL, Titipan, PtCode, NoLot, Kg, Sak, Palet FROM ({SaldoSaatIni}) x",
            new { id = h.OpnameId, whs = h.WhsCode, tgl = h.TglOpname.Date }, tx, commandTimeout: 300);
        await db.ExecuteAsync("UPDATE WHS_Opname SET FreezeKe = FreezeKe + 1, FreezeAt = SYSDATETIME(), FreezeBy = @userId WHERE OpnameId = @id",
            new { id = h.OpnameId, userId }, tx);
    }

    /// Jumlah kunci yang berbeda antara snapshot freeze dan saldo saat ini (dokumen bertanggal sebelum tgl opname diposting sesudah freeze).
    static Task<int> Stale(SqlConnection db, SqlTransaction? tx, Head h) => db.ExecuteScalarAsync<int>($@"
SELECT COUNT(*) FROM (SELECT * FROM WHS_OpnameSaldo WHERE OpnameId = @id) s
FULL JOIN ({SaldoSaatIni}) c ON c.KodeRuangan = s.KodeRuangan AND c.ItemCode = s.ItemCode AND c.ContainerNo = s.ContainerNo AND c.NoBL = s.NoBL
     AND c.Titipan = s.Titipan AND c.PtCode = s.PtCode AND c.NoLot = s.NoLot
WHERE (s.OpnameId IS NULL OR c.ItemCode IS NULL OR c.Kg <> s.Kg OR c.Sak <> s.Sak OR c.Palet <> s.Palet)",
        new { id = h.OpnameId, whs = h.WhsCode, tgl = h.TglOpname.Date }, tx, commandTimeout: 300);

    static bool RakOk(string? rak) => rak is not null && System.Text.RegularExpressions.Regex.IsMatch(rak, @"^[A-Z0-9][A-Z0-9\-]{0,29}$");

    /// No. rak fleksibel: boleh rak lama dari master atau no. baru yang ditentukan saat opname.
    /// No. baru otomatis disimpan ke master (supaya barcode bisa dicetak & dipakai lagi); rak lama yang nonaktif diaktifkan lagi.
    static async Task TambahRak(SqlConnection db, SqlTransaction tx, long id, OpnameRakReq x)
    {
        if (x.KodeRak != "ALL")
            await db.ExecuteAsync(@"
IF EXISTS (SELECT 1 FROM WHS_MasterRak WHERE KodeRuangan = @ru AND KodeRak = @rk)
    UPDATE WHS_MasterRak SET Aktif = 1 WHERE KodeRuangan = @ru AND KodeRak = @rk AND Aktif = 0
ELSE
    INSERT WHS_MasterRak (KodeRuangan, KodeRak, Aktif) VALUES (@ru, @rk, 1)", new { ru = x.KodeRuangan, rk = x.KodeRak }, tx);
        await db.ExecuteAsync("INSERT WHS_OpnameRak (OpnameId, KodeRuangan, KodeRak, Krani1, Krani2) VALUES (@id, @ru, @rk, @k1, @k2)",
            new { id, ru = x.KodeRuangan, rk = x.KodeRak, k1 = x.Krani1, k2 = x.Krani2 }, tx);
    }

    public static void MapOpnameCms(this RouteGroupBuilder cms, Func<SqlConnection> dbf, IConfiguration cfg)
    {
        // ------------------------------------------------------------ Master rak
        cms.MapGet("/master/rak", async (string? whs, string? ruangan) =>
        {
            await using var db = dbf();
            var rows = await db.QueryAsync(@"
SELECT k.KodeRuangan AS kodeRuangan, r.NamaRuangan AS namaRuangan, r.WhsCode AS whsCode, k.KodeRak AS kodeRak, k.NamaRak AS namaRak, k.Aktif AS aktif,
       CONCAT('RAK-', k.KodeRuangan, '-', k.KodeRak) AS barcode,
       (SELECT COUNT(*) FROM WHS_OpnameRak o WHERE o.KodeRuangan = k.KodeRuangan AND o.KodeRak = k.KodeRak) AS dipakai
FROM WHS_MasterRak k JOIN WHS_MasterRuangan r ON r.KodeRuangan = k.KodeRuangan
WHERE (@whs IS NULL OR r.WhsCode = @whs) AND (@ruangan IS NULL OR k.KodeRuangan = @ruangan)
ORDER BY r.WhsCode, k.KodeRuangan, k.KodeRak", new { whs = Helpers.Empty(whs), ruangan = Helpers.Empty(ruangan) });
            return Results.Ok(rows);
        });

        cms.MapPost("/master/rak", async (RakReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var ruang = (r.KodeRuangan ?? "").Trim().ToUpperInvariant();
            var rak = (r.KodeRak ?? "").Trim().ToUpperInvariant();
            if (!System.Text.RegularExpressions.Regex.IsMatch(rak, @"^[A-Z0-9][A-Z0-9\-]{0,29}$")) return Bad("Kode rak 1-30 karakter: huruf besar, angka, strip");
            if ((r.NamaRak?.Length ?? 0) > 100) return Bad("Nama rak maks 100 karakter");
            await using var db = dbf();
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_MasterRuangan WHERE KodeRuangan = @ruang", new { ruang }) == 0) return Bad("Ruangan tidak ditemukan");
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_MasterRak WHERE KodeRuangan = @ruang AND KodeRak = @rak", new { ruang, rak }) > 0) return Bad("Kode rak sudah ada di ruangan ini");
            await db.ExecuteAsync("INSERT WHS_MasterRak (KodeRuangan, KodeRak, NamaRak, Aktif) VALUES (@ruang, @rak, @nama, 1)", new { ruang, rak, nama = Helpers.Empty(r.NamaRak) });
            await Audit.Safe(db, u, ctx, "RAK_ADD", "RAK", null, $"{ruang} {rak}");
            return Results.Ok(new { kodeRuangan = ruang, kodeRak = rak, barcode = Barcode(ruang, rak) });
        });

        cms.MapPut("/master/rak/{ruang}/{rak}", async (string ruang, string rak, RakReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            if ((r.NamaRak?.Length ?? 0) > 100) return Bad("Nama rak maks 100 karakter");
            await using var db = dbf();
            var n = await db.ExecuteAsync("UPDATE WHS_MasterRak SET NamaRak = @nama, Aktif = @aktif WHERE KodeRuangan = @ruang AND KodeRak = @rak",
                new { ruang, rak, nama = Helpers.Empty(r.NamaRak), aktif = r.Aktif ?? true });
            if (n == 0) return Results.NotFound(new { message = "Rak tidak ditemukan" });
            await Audit.Safe(db, u, ctx, "RAK_EDIT", "RAK", null, $"{ruang} {rak}");
            return Results.Ok(new { ok = true });
        });

        cms.MapDelete("/master/rak/{ruang}/{rak}", async (string ruang, string rak, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_OpnameRak WHERE KodeRuangan = @ruang AND KodeRak = @rak", new { ruang, rak }) > 0)
                return Bad("Rak sudah dipakai di opname, nonaktifkan saja");
            await db.ExecuteAsync("DELETE WHS_MasterRak WHERE KodeRuangan = @ruang AND KodeRak = @rak", new { ruang, rak });
            await Audit.Safe(db, u, ctx, "RAK_DEL", "RAK", null, $"{ruang} {rak}");
            return Results.Ok(new { ok = true });
        });

        // ------------------------------------------------------------ Opname
        cms.MapGet("/opname", async (string? whs, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var rows = await db.QueryAsync(@"
SELECT o.OpnameId AS opnameId, o.OpnameNo AS opnameNo, o.WhsCode AS whsCode, w.WhsName AS whsName, o.TglOpname AS tglOpname, o.Status AS status,
       o.FreezeKe AS freezeKe, o.FreezeAt AS freezeAt, o.PostObjType AS postObjType, o.PostDocEntry AS postDocEntry, o.CreatedAt AS createdAt,
       (SELECT COUNT(*) FROM WHS_OpnameRak r WHERE r.OpnameId = o.OpnameId) AS jumlahRak,
       (SELECT COUNT(*) FROM WHS_OpnameRak r WHERE r.OpnameId = o.OpnameId AND r.Selesai1 = 1 AND r.Selesai2 = 1) AS rakSelesai,
       STUFF((SELECT DISTINCT ', ' + r.KodeRuangan FROM WHS_OpnameRak r WHERE r.OpnameId = o.OpnameId FOR XML PATH('')), 1, 2, '') AS ruangan,
       STUFF((SELECT DISTINCT ', ' + x.USER_CODE FROM WHS_OpnameRak r JOIN OUSR x ON x.USERID IN (r.Krani1, r.Krani2) WHERE r.OpnameId = o.OpnameId FOR XML PATH('')), 1, 2, '') AS krani
FROM WHS_Opname o LEFT JOIN OWHS w ON w.WhsCode = o.WhsCode
WHERE o.BplId = @bpl AND (@whs IS NULL OR o.WhsCode = @whs)
ORDER BY o.OpnameId DESC", new { bpl = u.BplId(), whs = Helpers.Empty(whs) });
            return Results.Ok(rows);
        });

        // Data form buat opname: ruangan gudang + stok + rak master + krani yang punya akses gudang
        cms.MapGet("/opname/form", async (string whs) =>
        {
            await using var db = dbf();
            var rooms = await db.QueryAsync(@"
SELECT r.KodeRuangan AS kodeRuangan, r.NamaRuangan AS namaRuangan, r.Titipan AS titipan,
       ISNULL((SELECT SUM(s.Kg) FROM WHS_Saldo s WHERE s.KodeRuangan = r.KodeRuangan), 0) AS stokKg,
       (SELECT COUNT(DISTINCT s.ItemCode) FROM WHS_Saldo s WHERE s.KodeRuangan = r.KodeRuangan AND s.Kg <> 0) AS jumlahItem,
       (SELECT TOP 1 o.OpnameNo FROM WHS_Opname o JOIN WHS_OpnameRak x ON x.OpnameId = o.OpnameId WHERE o.Status = 'Hitung' AND x.KodeRuangan = r.KodeRuangan) AS opnameAktif
FROM WHS_MasterRuangan r WHERE r.WhsCode = @whs AND r.Aktif = 1 ORDER BY r.KodeRuangan", new { whs });
            var raks = await db.QueryAsync(@"
SELECT k.KodeRuangan AS kodeRuangan, k.KodeRak AS kodeRak, k.NamaRak AS namaRak, k.Aktif AS aktif
FROM WHS_MasterRak k JOIN WHS_MasterRuangan r ON r.KodeRuangan = k.KodeRuangan
WHERE r.WhsCode = @whs ORDER BY k.KodeRuangan, k.KodeRak", new { whs });
            var kranis = await db.QueryAsync("SELECT u.USERID AS userId, u.USER_CODE AS userCode, u.U_NAME AS name FROM OUSR u JOIN USR9 a ON a.UserId = u.USERID WHERE a.WhsCode = @whs ORDER BY u.USER_CODE", new { whs });
            return Results.Ok(new { rooms, raks, kranis });
        });

        cms.MapPost("/opname", async (OpnameCreateReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var raks = (r.Raks ?? new()).Select(x => x with { KodeRuangan = (x.KodeRuangan ?? "").Trim(), KodeRak = (x.KodeRak ?? "").Trim().ToUpperInvariant() }).ToList();
            if (string.IsNullOrWhiteSpace(r.WhsCode)) return Bad("Pilih warehouse");
            if (raks.Count == 0) return Bad("Pilih minimal satu ruangan / rak");
            if (raks.Count > 500) return Bad("Terlalu banyak rak");
            var tgl = r.TglOpname.Date;
            if (tgl > DateTime.Today.AddDays(30) || tgl < DateTime.Today.AddDays(-30)) return Bad("Tanggal opname maksimal 30 hari dari hari ini");
            if (raks.Any(x => !RakOk(x.KodeRak))) return Bad("Kode rak 1-30 karakter: huruf besar, angka, strip");
            if (raks.Any(x => x.Krani1 <= 0 || x.Krani2 <= 0)) return Bad("Setiap rak wajib punya krani hitung ke-1 dan ke-2");
            if (raks.Any(x => x.Krani1 == x.Krani2)) return Bad("Di setiap rak, krani hitung ke-1 dan ke-2 harus orang yang berbeda");
            if (raks.GroupBy(x => (x.KodeRuangan, x.KodeRak)).Any(g => g.Count() > 1)) return Bad("Rak dobel di daftar");
            if ((r.Catatan?.Length ?? 0) > 250) return Bad("Catatan maks 250 karakter");

            await using var db = dbf();
            await db.OpenAsync();
            var whs = r.WhsCode.Trim();
            var (err, _) = await Helpers.CekRuangan(db, whs, raks.Select(x => (string?)x.KodeRuangan), "opname");
            if (err is not null) return Bad(err);
            var akses = (await db.QueryAsync<int>("SELECT UserId FROM USR9 WHERE WhsCode = @whs", new { whs })).ToHashSet();
            if (raks.Any(x => !akses.Contains(x.Krani1) || !akses.Contains(x.Krani2))) return Bad("Ada krani yang tidak punya akses ke gudang ini");

            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.Serializable);
            try
            {
                var bentrok = await db.QueryFirstOrDefaultAsync<string>(@"
SELECT TOP 1 CONCAT(o.OpnameNo, ' (', x.KodeRuangan, ')') FROM WHS_Opname o WITH (UPDLOCK) JOIN WHS_OpnameRak x ON x.OpnameId = o.OpnameId
WHERE o.Status = 'Hitung' AND x.KodeRuangan IN @rooms", new { rooms = raks.Select(x => x.KodeRuangan).Distinct().ToList() }, tx);
                if (bentrok is not null) { await tx.RollbackAsync(); return Bad($"Ruangan masih dalam opname aktif {bentrok}"); }

                var prefix = $"OPN/{tgl:yyMM}/";
                var last = await db.ExecuteScalarAsync<string?>("SELECT MAX(OpnameNo) FROM WHS_Opname WITH (UPDLOCK, HOLDLOCK) WHERE OpnameNo LIKE @p", new { p = prefix + "%" }, tx);
                var seq = last is null ? 1 : int.Parse(last[prefix.Length..]) + 1;
                var no = $"{prefix}{seq:0000}";
                var id = await db.ExecuteScalarAsync<long>(@"
INSERT WHS_Opname (OpnameNo, WhsCode, BplId, TglOpname, Status, CreatedBy, Catatan) OUTPUT INSERTED.OpnameId
VALUES (@no, @whs, @bpl, @tgl, 'Hitung', @uid, @cat)", new { no, whs, bpl = u.BplId(), tgl, uid = u.UserId(), cat = Helpers.Empty(r.Catatan) }, tx);
                foreach (var x in raks) await TambahRak(db, tx, id, x);
                var h = await db.QueryFirstAsync<Head>(HeadSql, new { id, bpl = u.BplId() }, tx);
                await Freeze(db, tx, h, u.UserId());
                await Audit.Write(db, tx, u, ctx, "OPNAME_ADD", "OPNAME", id, $"{no} {whs} {tgl:yyyy-MM-dd} {raks.Count} rak");
                await tx.CommitAsync();
                return Results.Ok(new { opnameId = id, opnameNo = no });
            }
            catch
            {
                try { await tx.RollbackAsync(); } catch { }
                throw;
            }
        });

        cms.MapGet("/opname/{id:long}", async (long id, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var h = await db.QueryFirstOrDefaultAsync<Head>(HeadSql, new { id, bpl = u.BplId() });
            if (h is null) return Results.NotFound(new { message = "Opname tidak ditemukan" });
            var raks = await db.QueryAsync(@"
SELECT r.KodeRuangan AS kodeRuangan, mr.NamaRuangan AS namaRuangan, r.KodeRak AS kodeRak, k.NamaRak AS namaRak,
       CONCAT('RAK-', r.KodeRuangan, '-', r.KodeRak) AS barcode,
       r.Krani1 AS krani1, u1.USER_CODE AS krani1Code, r.Krani2 AS krani2, u2.USER_CODE AS krani2Code, r.Selesai1 AS selesai1, r.Selesai2 AS selesai2,
       (SELECT COUNT(*) FROM WHS_OpnameHitung x WHERE x.OpnameId = r.OpnameId AND x.KodeRuangan = r.KodeRuangan AND x.KodeRak = r.KodeRak AND x.Ke = 1) AS baris1,
       (SELECT COUNT(*) FROM WHS_OpnameHitung x WHERE x.OpnameId = r.OpnameId AND x.KodeRuangan = r.KodeRuangan AND x.KodeRak = r.KodeRak AND x.Ke = 2) AS baris2
FROM WHS_OpnameRak r
LEFT JOIN WHS_MasterRuangan mr ON mr.KodeRuangan = r.KodeRuangan
LEFT JOIN WHS_MasterRak k ON k.KodeRuangan = r.KodeRuangan AND k.KodeRak = r.KodeRak
LEFT JOIN OUSR u1 ON u1.USERID = r.Krani1 LEFT JOIN OUSR u2 ON u2.USERID = r.Krani2
WHERE r.OpnameId = @id ORDER BY r.KodeRuangan, r.KodeRak", new { id });
            var rows = await Rows(db, null, h);
            var stale = h.Status == "Hitung" ? await Stale(db, null, h) : 0;
            return Results.Ok(new { header = h, raks, rows, stale });
        });

        // Tambah rak saat opname berjalan (rak baru ditemukan di lapangan, atau ruangan tambahan -> saldo di-freeze ulang)
        cms.MapPost("/opname/{id:long}/rak", async (long id, OpnameRakReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var x = r with { KodeRuangan = (r.KodeRuangan ?? "").Trim(), KodeRak = (r.KodeRak ?? "").Trim().ToUpperInvariant() };
            if (!RakOk(x.KodeRak)) return Bad("Kode rak 1-30 karakter: huruf besar, angka, strip");
            if (x.Krani1 <= 0 || x.Krani2 <= 0) return Bad("Pilih krani hitung ke-1 dan ke-2");
            if (x.Krani1 == x.Krani2) return Bad("Krani hitung ke-1 dan ke-2 harus orang yang berbeda");
            await using var db = dbf();
            await db.OpenAsync();
            var whs = await db.ExecuteScalarAsync<string?>("SELECT WhsCode FROM WHS_Opname WHERE OpnameId = @id AND BplId = @bpl", new { id, bpl = u.BplId() });
            if (whs is null) return Bad("Opname tidak ditemukan");
            var (err, _) = await Helpers.CekRuangan(db, whs, new[] { (string?)x.KodeRuangan }, "opname");
            if (err is not null) return Bad(err);
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.Serializable);
            try
            {
                var h = await db.QueryFirstOrDefaultAsync<Head>(HeadSql + " AND o.Status = 'Hitung'", new { id, bpl = u.BplId() }, tx);
                if (h is null) { await tx.RollbackAsync(); return Bad("Opname tidak ditemukan atau sudah selesai"); }
                var akses = (await db.QueryAsync<int>("SELECT UserId FROM USR9 WHERE WhsCode = @whs", new { whs = h.WhsCode }, tx)).ToHashSet();
                if (!akses.Contains(x.Krani1) || !akses.Contains(x.Krani2)) { await tx.RollbackAsync(); return Bad("Krani tidak punya akses ke gudang ini"); }
                if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_OpnameRak WHERE OpnameId = @id AND KodeRuangan = @ru AND KodeRak = @rk", new { id, ru = x.KodeRuangan, rk = x.KodeRak }, tx) > 0)
                { await tx.RollbackAsync(); return Bad("Rak sudah ada di opname ini"); }
                var ruangBaru = await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_OpnameRak WHERE OpnameId = @id AND KodeRuangan = @ru", new { id, ru = x.KodeRuangan }, tx) == 0;
                if (ruangBaru)
                {
                    var lain = await db.QueryFirstOrDefaultAsync<string>(@"SELECT TOP 1 o.OpnameNo FROM WHS_Opname o JOIN WHS_OpnameRak r ON r.OpnameId = o.OpnameId
WHERE o.Status = 'Hitung' AND o.OpnameId <> @id AND r.KodeRuangan = @ru", new { id, ru = x.KodeRuangan }, tx);
                    if (lain is not null) { await tx.RollbackAsync(); return Bad($"Ruangan masih dalam opname aktif {lain}"); }
                }
                await TambahRak(db, tx, id, x);
                if (ruangBaru) await Freeze(db, tx, h, u.UserId());
                await Audit.Write(db, tx, u, ctx, "OPNAME_RAK_ADD", "OPNAME", id, $"{x.KodeRuangan}/{x.KodeRak}{(ruangBaru ? " (ruangan baru, freeze ulang)" : "")}");
                await tx.CommitAsync();
                return Results.Ok(new { kodeRuangan = x.KodeRuangan, kodeRak = x.KodeRak, barcode = Barcode(x.KodeRuangan, x.KodeRak), freezeUlang = ruangBaru });
            }
            catch
            {
                try { await tx.RollbackAsync(); } catch { }
                throw;
            }
        });

        // Hapus rak dari opname (hanya bila belum ada hitungan). Ruangan yang tidak punya rak lagi keluar dari opname -> freeze ulang.
        cms.MapDelete("/opname/{id:long}/rak/{ruang}/{rak}", async (long id, string ruang, string rak, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync();
            var h = await db.QueryFirstOrDefaultAsync<Head>(HeadSql + " AND o.Status = 'Hitung'", new { id, bpl = u.BplId() }, tx);
            if (h is null) { await tx.RollbackAsync(); return Bad("Opname tidak ditemukan atau sudah selesai"); }
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_OpnameHitung WHERE OpnameId = @id AND KodeRuangan = @ruang AND KodeRak = @rak", new { id, ruang, rak }, tx) > 0)
            { await tx.RollbackAsync(); return Bad("Rak sudah ada hitungannya. Minta hitung ulang dulu bila ingin dihapus."); }
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_OpnameRak WHERE OpnameId = @id", new { id }, tx) <= 1)
            { await tx.RollbackAsync(); return Bad("Opname minimal punya satu rak. Batalkan opname bila tidak jadi."); }
            var n = await db.ExecuteAsync("DELETE WHS_OpnameRak WHERE OpnameId = @id AND KodeRuangan = @ruang AND KodeRak = @rak", new { id, ruang, rak }, tx);
            if (n == 0) { await tx.RollbackAsync(); return Results.NotFound(new { message = "Rak tidak ada di opname ini" }); }
            var ruangKeluar = await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_OpnameRak WHERE OpnameId = @id AND KodeRuangan = @ruang", new { id, ruang }, tx) == 0;
            if (ruangKeluar) await Freeze(db, tx, h, u.UserId());
            await Audit.Write(db, tx, u, ctx, "OPNAME_RAK_DEL", "OPNAME", id, $"{ruang}/{rak}");
            await tx.CommitAsync();
            return Results.Ok(new { ok = true, freezeUlang = ruangKeluar });
        });

        cms.MapPost("/opname/{id:long}/freeze", async (long id, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync();
            var h = await db.QueryFirstOrDefaultAsync<Head>(HeadSql + " AND o.Status = 'Hitung'", new { id, bpl = u.BplId() }, tx);
            if (h is null) { await tx.RollbackAsync(); return Bad("Opname tidak ditemukan atau sudah selesai"); }
            await Freeze(db, tx, h, u.UserId());
            await Audit.Write(db, tx, u, ctx, "OPNAME_FREEZE", "OPNAME", id, $"freeze ke-{h.FreezeKe + 1}");
            await tx.CommitAsync();
            return Results.Ok(new { freezeKe = h.FreezeKe + 1 });
        });

        cms.MapPut("/opname/{id:long}/final", async (long id, FinalReq r, ClaimsPrincipal u) =>
        {
            if (string.IsNullOrWhiteSpace(r.Kunci) || r.Kunci.Length > 260) return Bad("Kunci tidak valid");
            if (r.Pilihan is not null and not ("h1" or "h2" or "saldo")) return Bad("Pilihan harus h1, h2 atau saldo");
            await using var db = dbf();
            if (await db.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM WHS_Opname WHERE OpnameId = @id AND BplId = @bpl AND Status = 'Hitung'", new { id, bpl = u.BplId() }) == 0)
                return Bad("Opname tidak ditemukan atau sudah selesai");
            await db.ExecuteAsync("DELETE WHS_OpnameFinal WHERE OpnameId = @id AND Kunci = @k", new { id, k = r.Kunci });
            if (r.Pilihan is not null)
                await db.ExecuteAsync("INSERT WHS_OpnameFinal (OpnameId, Kunci, Pilihan, UserId) VALUES (@id, @k, @p, @uid)", new { id, k = r.Kunci, p = r.Pilihan, uid = u.UserId() });
            return Results.Ok(new { ok = true });
        });

        // Hitung ulang: per rak (ke 1/2/0 = keduanya) atau per baris validasi (semua rak tempat kunci itu dihitung)
        cms.MapPost("/opname/{id:long}/ulang", async (long id, UlangReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync();
            var h = await db.QueryFirstOrDefaultAsync<Head>(HeadSql + " AND o.Status = 'Hitung'", new { id, bpl = u.BplId() }, tx);
            if (h is null) { await tx.RollbackAsync(); return Bad("Opname tidak ditemukan atau sudah selesai"); }
            var target = new List<(string Ru, string Rak)>();
            if (!string.IsNullOrWhiteSpace(r.Kunci))
            {
                var all = await db.QueryAsync<KeyRow>("SELECT * FROM WHS_OpnameHitung WHERE OpnameId = @id", new { id }, tx);
                target = all.Where(x => x.Kunci == r.Kunci).Select(x => (x.KodeRuangan, x.KodeRak)).Distinct().ToList();
                if (target.Count == 0)
                {
                    // tidak ditemukan krani: hitung ulang semua rak di ruangan itu
                    var ru = r.Kunci.Split('|')[0];
                    target = (await db.QueryAsync<(string, string)>("SELECT KodeRuangan, KodeRak FROM WHS_OpnameRak WHERE OpnameId = @id AND KodeRuangan = @ru", new { id, ru }, tx)).ToList();
                }
                await db.ExecuteAsync("DELETE WHS_OpnameFinal WHERE OpnameId = @id AND Kunci = @k", new { id, k = r.Kunci }, tx);
            }
            else if (!string.IsNullOrWhiteSpace(r.KodeRuangan) && !string.IsNullOrWhiteSpace(r.KodeRak))
                target.Add((r.KodeRuangan, r.KodeRak));
            if (target.Count == 0) { await tx.RollbackAsync(); return Bad("Pilih rak yang dihitung ulang"); }
            var ke = r.Ke ?? 0;
            foreach (var (ru, rak) in target)
            {
                await db.ExecuteAsync(@"
UPDATE WHS_OpnameRak SET Selesai1 = CASE WHEN @ke IN (0,1) THEN 0 ELSE Selesai1 END, Selesai2 = CASE WHEN @ke IN (0,2) THEN 0 ELSE Selesai2 END
WHERE OpnameId = @id AND KodeRuangan = @ru AND KodeRak = @rak", new { id, ru, rak, ke }, tx);
                await db.ExecuteAsync("DELETE WHS_OpnameHitung WHERE OpnameId = @id AND KodeRuangan = @ru AND KodeRak = @rak AND (@ke = 0 OR Ke = @ke)", new { id, ru, rak, ke }, tx);
            }
            await Audit.Write(db, tx, u, ctx, "OPNAME_ULANG", "OPNAME", id, string.Join(", ", target.Select(t => $"{t.Item1}/{t.Item2}")) + $" ke {ke}");
            await tx.CommitAsync();
            return Results.Ok(new { rak = target.Count });
        });

        cms.MapPost("/opname/{id:long}/batal", async (long id, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            var n = await db.ExecuteAsync("UPDATE WHS_Opname SET Status = 'Batal' WHERE OpnameId = @id AND BplId = @bpl AND Status = 'Hitung'", new { id, bpl = u.BplId() });
            if (n == 0) return Bad("Opname tidak ditemukan atau sudah selesai");
            await Audit.Safe(db, u, ctx, "OPNAME_BATAL", "OPNAME", id, null);
            return Results.Ok(new { status = "Batal" });
        });

        cms.MapPost("/opname/{id:long}/post", async (long id, ClaimsPrincipal u, HttpContext ctx) =>
        {
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync(IsolationLevel.ReadCommitted);
            try
            {
                var h = await db.QueryFirstOrDefaultAsync<Head>(HeadSql.Replace("FROM WHS_Opname o", "FROM WHS_Opname o WITH (UPDLOCK)") + " AND o.Status = 'Hitung'", new { id, bpl = u.BplId() }, tx);
                if (h is null) { await tx.RollbackAsync(); return Bad("Opname tidak ditemukan atau sudah selesai"); }
                var errors = new List<string>();
                var belum = (await db.QueryAsync<string>(@"
SELECT CONCAT(KodeRuangan, '/', KodeRak, CASE WHEN Selesai1 = 0 THEN ' hitung 1' ELSE '' END, CASE WHEN Selesai2 = 0 THEN ' hitung 2' ELSE '' END)
FROM WHS_OpnameRak WHERE OpnameId = @id AND (Selesai1 = 0 OR Selesai2 = 0)", new { id }, tx)).ToList();
                if (belum.Count > 0) errors.Add("Rak belum selesai dihitung: " + string.Join(", ", belum.Take(10)) + (belum.Count > 10 ? " ..." : ""));
                var stale = await Stale(db, tx, h);
                if (stale > 0) errors.Add($"Saldo berubah setelah freeze ({stale} baris). Lakukan freeze ulang dulu.");
                var rows = await Rows(db, tx, h);
                var open = rows.Count(x => x.Final is null);
                if (open > 0) errors.Add($"{open} baris beda antar krani belum diputuskan");
                if (errors.Count > 0) { await tx.RollbackAsync(); return Results.BadRequest(new { message = "Opname belum bisa diposting", errors }); }

                var diffs = rows.Select(x => (x.Key, dKg: x.Final!.Kg - x.Saldo.Kg, dSak: x.Final.Sak - x.Saldo.Sak, dPlt: x.Final.Palet - x.Saldo.Palet))
                    .Where(x => x.dKg != 0 || x.dSak != 0 || x.dPlt != 0).ToList();
                var docs = new List<object>();
                long? firstDoc = null;
                // satu dokumen per sifat titipan (titipan & non-titipan tidak boleh dicampur dalam satu dokumen)
                foreach (var grp in diffs.GroupBy(x => x.Key.Titipan))
                {
                    var dp = new DynamicParameters();
                    dp.Add("@ObjType", "6720"); dp.Add("@DocDate", h.TglOpname.Date, DbType.Date);
                    dp.Add("@DocEntry", dbType: DbType.Int64, direction: ParameterDirection.Output);
                    await db.ExecuteAsync(Sql.NextDocEntry, dp, tx, commandType: CommandType.StoredProcedure);
                    var docEntry = dp.Get<long>("@DocEntry");
                    await db.ExecuteAsync(Sql.InsertHeader, new { objType = "6720", docEntry, docDate = h.TglOpname.Date, bplId = h.BplId, whsCode = h.WhsCode, userId = u.UserId(), trxCode = "OP", noMobil = "", containerNo = (string?)null }, tx);
                    await db.ExecuteAsync("UPDATE OKRN SET Catatan = @c WHERE ObjType = '6720' AND DocEntry = @docEntry", new { c = $"Stock opname {h.OpnameNo}", docEntry }, tx);
                    var ln = 0;
                    foreach (var d in grp)
                    {
                        var flag = d.dKg != 0 ? Math.Sign(d.dKg) : d.dSak != 0 ? Math.Sign(d.dSak) : Math.Sign(d.dPlt);
                        await db.ExecuteAsync(@"
INSERT INTO KRN1 (ObjType, DocEntry, LineNum, ItemCode, qty, Qty2, QtyPalet, flags, LineStatus, KodeRuangan, ContainerNo, NoBL, Titipan, U_IDU_Kode_PT, NoLot)
VALUES ('6720', @docEntry, @ln, @item, @kg, @sak, @plt, @flag, 'O', @ru, @cont, @bl, @tit, @pt, @lot)", new
                        {
                            docEntry, ln = ln++, item = d.Key.ItemCode, kg = d.dKg * flag, sak = d.dSak * flag, plt = d.dPlt * flag, flag,
                            ru = d.Key.KodeRuangan, cont = Helpers.Empty(d.Key.ContainerNo), bl = Helpers.Empty(d.Key.NoBL), tit = d.Key.Titipan,
                            pt = Helpers.Empty(d.Key.PtCode), lot = d.Key.NoLot,
                        }, tx);
                    }
                    await db.ExecuteAsync(Sql.UpdateTotals, new { objType = "6720", docEntry }, tx);
                    await db.ExecuteAsync("dbo.usp_WHS_SaldoPosting", new { ObjType = "6720", DocEntry = docEntry }, tx, commandType: CommandType.StoredProcedure);
                    var stockProc = cfg["Posting:StockProcedure"];
                    if (!string.IsNullOrWhiteSpace(stockProc))
                        await db.ExecuteAsync(stockProc, new { ObjType = "6720", DocEntry = docEntry }, tx, commandType: CommandType.StoredProcedure);
                    await db.ExecuteAsync(Sql.CloseLines, new { objType = "6720", docEntry }, tx);
                    await db.ExecuteAsync(Sql.CloseHeader, new { objType = "6720", docEntry, bplId = h.BplId }, tx);
                    docs.Add(new { objType = "6720", docEntry, titipan = grp.Key, baris = ln });
                    firstDoc ??= docEntry;
                }
                await db.ExecuteAsync("UPDATE WHS_Opname SET Status = 'Posted', PostedAt = SYSDATETIME(), PostObjType = @o, PostDocEntry = @d WHERE OpnameId = @id",
                    new { id, o = firstDoc is null ? null : "6720", d = firstDoc }, tx);
                await Audit.Write(db, tx, u, ctx, "OPNAME_POST", "OPNAME", id, $"{h.OpnameNo} {diffs.Count} baris selisih, {docs.Count} dokumen OP");
                await tx.CommitAsync();
                return Results.Ok(new { status = "Posted", docs, selisihBaris = diffs.Count });
            }
            catch
            {
                try { await tx.RollbackAsync(); } catch { }
                throw;
            }
        });
    }

    public record Vec(decimal Kg, decimal Sak, decimal Palet)
    {
        public static readonly Vec Zero = new(0, 0, 0);
        public Vec Add(KeyRow r) => new(Kg + r.Kg, Sak + r.Sak, Palet + r.Palet);
    }

    public class Row
    {
        public string Kunci { get; set; } = "";
        public KeyRow Key { get; set; } = new();
        public string? ItemName { get; set; }
        public string? PtName { get; set; }
        public bool AdaSaldo { get; set; }
        public Vec Saldo { get; set; } = Vec.Zero;
        public Vec? H1 { get; set; }
        public Vec? H2 { get; set; }
        public string? Pilihan { get; set; }
        public string? PilihanDefault { get; set; }
        public Vec? Final { get; set; }
        public List<string> Rak { get; set; } = new();
        public string? Dobel { get; set; }
        public string Status { get; set; } = "";
    }

    static async Task<List<Row>> Rows(SqlConnection db, SqlTransaction? tx, Head h)
    {
        var saldo = (await db.QueryAsync<KeyRow>("SELECT * FROM WHS_OpnameSaldo WHERE OpnameId = @id", new { id = h.OpnameId }, tx)).ToList();
        var hit = (await db.QueryAsync<KeyRow>("SELECT * FROM WHS_OpnameHitung WHERE OpnameId = @id", new { id = h.OpnameId }, tx)).ToList();
        var fin = (await db.QueryAsync<(string Kunci, string Pilihan)>("SELECT Kunci, Pilihan FROM WHS_OpnameFinal WHERE OpnameId = @id", new { id = h.OpnameId }, tx))
            .ToDictionary(x => x.Kunci, x => x.Pilihan);
        var items = saldo.Select(x => x.ItemCode).Concat(hit.Select(x => x.ItemCode)).Distinct().ToList();
        var names = items.Count == 0 ? new Dictionary<string, string>() : (await db.QueryAsync<(string, string)>(
            "SELECT ItemCode, ItemName FROM OITM WHERE ItemCode IN @items UNION ALL SELECT ItemCode, ItemName FROM WHS_ItemScrap WHERE ItemCode IN @items", new { items }, tx))
            .GroupBy(x => x.Item1).ToDictionary(g => g.Key, g => g.First().Item2);
        var pts = saldo.Select(x => x.PtCode).Concat(hit.Select(x => x.PtCode)).Where(x => x != "").Distinct().ToList();
        var ptNames = pts.Count == 0 ? new Dictionary<string, string>() : (await db.QueryAsync<(string, string)>(
            "SELECT PrcCode, PrcName FROM OPRC WHERE PrcCode IN @pts", new { pts }, tx)).ToDictionary(x => x.Item1, x => x.Item2);

        var map = new Dictionary<string, Row>();
        Row Get(KeyRow k)
        {
            if (!map.TryGetValue(k.Kunci, out var r))
            {
                r = new Row { Kunci = k.Kunci, Key = k, ItemName = names.GetValueOrDefault(k.ItemCode), PtName = ptNames.GetValueOrDefault(k.PtCode) };
                map[k.Kunci] = r;
            }
            return r;
        }
        foreach (var s in saldo) { var r = Get(s); r.AdaSaldo = true; r.Saldo = new Vec(s.Kg, s.Sak, s.Palet); }
        foreach (var x in hit)
        {
            var r = Get(x);
            if (x.Ke == 1) r.H1 = (r.H1 ?? Vec.Zero).Add(x); else r.H2 = (r.H2 ?? Vec.Zero).Add(x);
            var rk = $"{x.KodeRak}";
            if (!r.Rak.Contains(rk)) r.Rak.Add(rk);
        }
        foreach (var g in hit.GroupBy(x => (x.Kunci, x.Ke)).Where(g => g.Select(x => x.KodeRak).Distinct().Count() > 1))
        {
            var r = map[g.Key.Kunci];
            r.Dobel = $"Hitung {g.Key.Ke}: ditemukan di rak {string.Join(" & ", g.Select(x => x.KodeRak).Distinct())}";
        }
        foreach (var r in map.Values)
        {
            var h1 = r.H1 ?? Vec.Zero; var h2 = r.H2 ?? Vec.Zero;
            var sama = h1 == h2;
            r.PilihanDefault = sama ? "h1" : null;
            r.Pilihan = fin.GetValueOrDefault(r.Kunci);
            var p = r.Pilihan ?? r.PilihanDefault;
            r.Final = p switch { "h1" => h1, "h2" => h2, "saldo" => r.Saldo, _ => null };
            r.Status = r.Final is null ? "Beda antar krani"
                : !r.AdaSaldo ? "Tidak ada di saldo"
                : r.H1 is null && r.H2 is null && p != "saldo" ? "Tidak ditemukan"
                : r.Final == r.Saldo ? "Cocok" : "Selisih saldo";
        }
        return map.Values.OrderBy(x => x.Key.KodeRuangan).ThenBy(x => x.Key.ItemCode).ThenBy(x => x.Key.ContainerNo).ThenBy(x => x.Key.NoLot).ToList();
    }

    // ================================================================ Krani
    public static void MapOpnameKrani(this RouteGroupBuilder api, Func<SqlConnection> dbf)
    {
        api.MapGet("/opname/tugas", async (ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var rows = (await db.QueryAsync(@"
SELECT o.OpnameId AS opnameId, o.OpnameNo AS opnameNo, o.WhsCode AS whsCode, o.TglOpname AS tglOpname, o.FreezeAt AS freezeAt,
       r.KodeRuangan AS kodeRuangan, mr.NamaRuangan AS namaRuangan, mr.Titipan AS ruanganTitipan, r.KodeRak AS kodeRak, k.NamaRak AS namaRak,
       CAST(CASE WHEN r.Krani1 = @uid THEN 1 ELSE 2 END AS int) AS ke,
       CAST(CASE WHEN r.Krani1 = @uid THEN r.Selesai1 ELSE r.Selesai2 END AS bit) AS selesai,
       (SELECT COUNT(*) FROM WHS_OpnameHitung x WHERE x.OpnameId = r.OpnameId AND x.KodeRuangan = r.KodeRuangan AND x.KodeRak = r.KodeRak AND x.UserId = @uid) AS baris
FROM WHS_Opname o JOIN WHS_OpnameRak r ON r.OpnameId = o.OpnameId
LEFT JOIN WHS_MasterRuangan mr ON mr.KodeRuangan = r.KodeRuangan
LEFT JOIN WHS_MasterRak k ON k.KodeRuangan = r.KodeRuangan AND k.KodeRak = r.KodeRak
WHERE o.Status = 'Hitung' AND o.BplId = @bpl AND @uid IN (r.Krani1, r.Krani2)
ORDER BY o.OpnameId, r.KodeRuangan, r.KodeRak", new { uid = u.UserId(), bpl = u.BplId() })).ToList();
            var list = rows.GroupBy(r => (long)r.opnameId).Select(g => new
            {
                opnameId = g.Key,
                opnameNo = (string)g.First().opnameNo,
                whsCode = (string)g.First().whsCode,
                tglOpname = (DateTime)g.First().tglOpname,
                freezeAt = (DateTime?)g.First().freezeAt,
                raks = g.Select(r => new
                {
                    kodeRuangan = (string)r.kodeRuangan, namaRuangan = (string?)r.namaRuangan, ruanganTitipan = (bool?)r.ruanganTitipan ?? false,
                    kodeRak = (string)r.kodeRak, namaRak = (string?)r.namaRak, ke = (int)r.ke, selesai = (bool)r.selesai, baris = (int)r.baris,
                }).ToList(),
            });
            return Results.Ok(list);
        });

        // Hasil hitung saya di satu rak (untuk melanjutkan). Saldo sistem TIDAK pernah dikirim ke krani (hitung buta).
        api.MapGet("/opname/{id:long}/hitung", async (long id, string ruangan, string rak, ClaimsPrincipal u) =>
        {
            await using var db = dbf();
            var rows = await db.QueryAsync(@"
SELECT x.Qr AS qr, x.ItemCode AS itemCode, COALESCE(i.ItemName, sc.ItemName) AS itemName, x.ContainerNo AS containerNo, NULLIF(x.NoLot, '') AS noLot,
       NULLIF(x.NoBL, '') AS noBL, x.Titipan AS titipan, NULLIF(x.PtCode, '') AS ptCode, pc.PrcName AS ptName, x.Sak AS sak, x.Kg AS kg, x.Palet AS palet
FROM WHS_OpnameHitung x LEFT JOIN OITM i ON i.ItemCode = x.ItemCode LEFT JOIN WHS_ItemScrap sc ON sc.ItemCode = x.ItemCode LEFT JOIN OPRC pc ON pc.PrcCode = x.PtCode
WHERE x.OpnameId = @id AND x.KodeRuangan = @ruangan AND x.KodeRak = @rak AND x.UserId = @uid ORDER BY x.HitungId", new { id, ruangan, rak, uid = u.UserId() });
            return Results.Ok(rows);
        });

        // Scan QR palet: data barang + pilihan sumber stok (BL / titipan / PT) tanpa jumlah saldo.
        api.MapGet("/opname/{id:long}/qr", async (long id, string qr, string ruangan, ClaimsPrincipal u) =>
        {
            var p = ParseQr(qr);
            if (p is null) return Bad("Format QR tidak dikenal (harus yymmdd-itemcode-container)");
            var (item, cont, lot, yymmdd) = p.Value;
            await using var db = dbf();
            var o = await db.QueryFirstOrDefaultAsync<(string WhsCode, int BplId)?>("SELECT WhsCode, BplId FROM WHS_Opname WHERE OpnameId = @id AND Status = 'Hitung' AND BplId = @bpl", new { id, bpl = u.BplId() });
            if (o is null) return Bad("Opname tidak aktif");
            var info = await db.QueryFirstOrDefaultAsync<PalletSourceRow>(Sql.PalletSource, new { itemCode = item, containerNo = cont, yymmdd, bplId = u.BplId(), lot = lot == "" ? null : lot });
            var name = info?.ItemName ?? await db.ExecuteScalarAsync<string?>("SELECT ItemName FROM OITM WHERE ItemCode = @item", new { item });
            if (name is null) return Results.NotFound(new { message = $"Item {item} tidak ditemukan" });
            const string pilihan = @"
SELECT DISTINCT NULLIF(s.NoBL, '') AS noBL, s.Titipan AS titipan, NULLIF(s.PtCode, '') AS ptCode, pc.PrcName AS ptName
FROM WHS_OpnameSaldo s LEFT JOIN OPRC pc ON pc.PrcCode = s.PtCode
WHERE s.OpnameId = @id AND s.ItemCode = @item AND s.ContainerNo = @cont AND s.NoLot = @lot AND (@ruangan IS NULL OR s.KodeRuangan = @ruangan)";
            var sumber = (await db.QueryAsync(pilihan, new { id, item, cont, lot, ruangan })).ToList();
            if (sumber.Count == 0) sumber = (await db.QueryAsync(pilihan, new { id, item, cont, lot, ruangan = (string?)null })).ToList();
            if (sumber.Count == 0)
                // barang tidak ada di saldo freeze: sumber dari baris masuk asal label
                sumber = (await db.QueryAsync($@"
SELECT TOP 1 NULLIF({BL}, '') AS noBL, {TIT} AS titipan, NULLIF({PT}, '') AS ptCode, pc.PrcName AS ptName
FROM OKRN h JOIN KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry LEFT JOIN OPRC pc ON pc.PrcCode = {PT}
WHERE d.flags = 1 AND d.ItemCode = @item AND {CONT} = @cont AND ISNULL(d.NoLot, '') = @lot AND h.BPLId = @bpl
ORDER BY h.DocDate DESC", new { item, cont, lot, bpl = u.BplId() })).ToList();
            decimal kgPerSak = info is not null && info.Qty2 > 0 ? Math.Round(info.Qty / info.Qty2, 2) : 0;
            decimal sakPerPalet = info is not null && info.QtyPalet > 0 ? Math.Ceiling(info.Qty2 / info.QtyPalet) : 0;
            return Results.Ok(new { qr = qr.Trim(), itemCode = item, itemName = name, containerNo = cont, noLot = lot == "" ? null : lot, kgPerSak, sakPerPalet, sumber });
        });

        // Kirim / simpan hitungan satu rak (mengganti hitungan saya sebelumnya di rak itu).
        api.MapPost("/opname/{id:long}/hitung", async (long id, HitungReq r, ClaimsPrincipal u, HttpContext ctx) =>
        {
            var lines = r.Lines ?? new();
            if (lines.Count > 1000) return Bad("Maksimal 1000 baris per rak");
            if (!string.Equals((r.BarcodeRak ?? "").Trim(), Barcode(r.KodeRuangan, r.KodeRak), StringComparison.OrdinalIgnoreCase))
                return Bad("Barcode rak tidak sesuai. Scan barcode rak yang ditugaskan.");
            foreach (var l in lines)
            {
                if (l.Kg < 0 || l.Sak < 0 || l.Palet < 0) return Bad("Qty tidak boleh minus");
                if (l.Kg > 10_000_000 || l.Sak > 1_000_000 || l.Palet > 10_000) return Bad("Qty tidak wajar");
                if (l.Kg == 0 && l.Sak == 0 && l.Palet == 0) return Bad($"Isi qty untuk {l.Qr}");
                if (ParseQr(l.Qr) is null) return Bad($"QR tidak valid: {l.Qr}");
                if ((l.NoBL?.Length ?? 0) > 50 || (l.PtCode?.Length ?? 0) > 30) return Bad("BL / PT terlalu panjang");
            }
            await using var db = dbf();
            await db.OpenAsync();
            await using var tx = (SqlTransaction)await db.BeginTransactionAsync();
            var rak = await db.QueryFirstOrDefaultAsync<(int Krani1, int Krani2, bool Selesai1, bool Selesai2)?>(@"
SELECT r.Krani1, r.Krani2, r.Selesai1, r.Selesai2 FROM WHS_OpnameRak r WITH (UPDLOCK) JOIN WHS_Opname o ON o.OpnameId = r.OpnameId
WHERE r.OpnameId = @id AND r.KodeRuangan = @ru AND r.KodeRak = @rk AND o.Status = 'Hitung' AND o.BplId = @bpl",
                new { id, ru = r.KodeRuangan, rk = r.KodeRak, bpl = u.BplId() }, tx);
            if (rak is null) { await tx.RollbackAsync(); return Bad("Rak tidak ada di opname aktif"); }
            var uid = u.UserId();
            int ke = rak.Value.Krani1 == uid ? 1 : rak.Value.Krani2 == uid ? 2 : 0;
            if (ke == 0) { await tx.RollbackAsync(); return Bad("Anda tidak ditugaskan di rak ini"); }
            if (ke == 1 ? rak.Value.Selesai1 : rak.Value.Selesai2) { await tx.RollbackAsync(); return Bad("Hitungan rak ini sudah dikirim. Minta Admin membuka hitung ulang bila perlu."); }
            var ruangTitipan = await db.ExecuteScalarAsync<bool>("SELECT ISNULL(Titipan, 0) FROM WHS_MasterRuangan WHERE KodeRuangan = @ru", new { ru = r.KodeRuangan }, tx);

            await db.ExecuteAsync("DELETE WHS_OpnameHitung WHERE OpnameId = @id AND KodeRuangan = @ru AND KodeRak = @rk AND Ke = @ke",
                new { id, ru = r.KodeRuangan, rk = r.KodeRak, ke }, tx);
            foreach (var l in lines)
            {
                var (item, cont, lot, _) = ParseQr(l.Qr)!.Value;
                if (l.Titipan && !ruangTitipan) { await tx.RollbackAsync(); return Bad($"{item}: barang titipan hanya boleh di ruangan titipan"); }
                await db.ExecuteAsync(@"
INSERT WHS_OpnameHitung (OpnameId, KodeRuangan, KodeRak, Ke, UserId, Qr, ItemCode, ContainerNo, NoBL, Titipan, PtCode, NoLot, Kg, Sak, Palet)
VALUES (@id, @ru, @rk, @ke, @uid, @qr, @item, @cont, @bl, @tit, @pt, @lot, @kg, @sak, @plt)", new
                {
                    id, ru = r.KodeRuangan, rk = r.KodeRak, ke, uid, qr = l.Qr.Trim(), item, cont, bl = (l.NoBL ?? "").Trim(), tit = l.Titipan,
                    pt = (l.PtCode ?? "").Trim(), lot, kg = l.Kg, sak = l.Sak, plt = l.Palet,
                }, tx);
            }
            if (r.Selesai)
                await db.ExecuteAsync($"UPDATE WHS_OpnameRak SET Selesai{ke} = 1 WHERE OpnameId = @id AND KodeRuangan = @ru AND KodeRak = @rk",
                    new { id, ru = r.KodeRuangan, rk = r.KodeRak }, tx);
            await Audit.Write(db, tx, u, ctx, r.Selesai ? "OPNAME_KIRIM" : "OPNAME_SIMPAN", "OPNAME", id, $"{r.KodeRuangan}/{r.KodeRak} hitung {ke}: {lines.Count} baris");
            await tx.CommitAsync();
            return Results.Ok(new { ke, baris = lines.Count, selesai = r.Selesai });
        });
    }
}
