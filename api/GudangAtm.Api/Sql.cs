namespace GudangAtm.Api;

/// <summary>
/// Semua query SQL ada di file ini supaya mudah disesuaikan dengan skema asli WORKSHOP_STAGING.
///
/// Kolom yang SUDAH dikonfirmasi user:
///   OUSR.USER_CODE, OUSR.password (base64), OUSR.USERID, OUSR.Branch, OUSR.Fax
///   OKRN.BPLId, OKRN.WhsCode, OKRN.UserId, OKRN.CardCode, OKRN.U_IDU_Kode_PT, OKRN.ObjType, OKRN.DocEntry, OKRN.TrxCode
///   KRN1.ObjType, KRN1.DocEntry, KRN1.ItemCode, KRN1.brand_name, KRN1.flags
///   USR9.WhsCode, OWHS.External, OCRD.CardType/CardName, OITM/OITB, SYS_GCM (CONDITION='MSTBRAND'), SYS_NOURUT
///
/// Kolom ASUMSI (cek & ganti bila nama di database berbeda):
///   OUSR.U_NAME                      nama user
///   USR9.UserId                      kolom user di USR9
///   OKRN.DocDate, VehicleNo (no. mobil), ContainerNo, DocStatus ('O'/'C'), DateCrt, total_qty/total_Sak/Total_Palet
///   KRN1.LineNum, Origin (asal barang, kolom tambahan), DistNumber (batch, tidak diisi aplikasi), qty (KG), Qty2 (sak), QtyPalet, flags (+1 masuk / -1 keluar), LineStatus ('O'/'C')
///   OITM.InvntryUom, OPRC.PrcName
///   OUSR.SUPERUSER ('Y' = Admin CMS)
///   OKRN.NumAtCard, OKRN.U_NoBL      (diisi Admin di CMS)
///   KRN1.NumAtCard                   (No DO per baris untuk Retur Customer)
///   KRN1.qty_scan, qty2_scan, QtyPalet_scan  (backup nilai input krani saat Admin mengedit)
///   Tabel baru WHS_AuditLog (lihat database/web_security.sql)
/// </summary>
public static class Sql
{
    public const string Login = @"
SELECT  u.USERID      AS userId,
        u.USER_CODE   AS userCode,
        u.U_NAME      AS name,
        u.Branch      AS bplId,
        u.Fax         AS defaultWhs,
        CAST(CASE WHEN u.SUPERUSER = 'Y' THEN 1 ELSE 0 END AS bit) AS superUser
FROM    OUSR u
WHERE   u.USER_CODE = @userCode AND u.[password] COLLATE Latin1_General_BIN2 = @passwordB64";  // Base64 peka huruf besar/kecil: jangan pakai collation CI database

    public const string Warehouses = @"
SELECT  w.WhsCode  AS whsCode,
        w.WhsName  AS whsName,
        CAST(CASE WHEN w.[External] = 'Y' THEN 1 ELSE 0 END AS bit) AS isTitipan,
        CAST(CASE WHEN w.WhsCode = u.Fax THEN 1 ELSE 0 END AS bit) AS isDefault
FROM    USR9 a
JOIN    OWHS w ON w.WhsCode = a.WhsCode
JOIN    OUSR u ON u.USERID  = a.UserId
WHERE   a.UserId = @userId
ORDER BY isDefault DESC, w.WhsCode";

    public const string WarehouseAccess = @"
SELECT  CAST(CASE WHEN w.[External] = 'Y' THEN 1 ELSE 0 END AS bit) AS isTitipan
FROM    USR9 a
JOIN    OWHS w ON w.WhsCode = a.WhsCode
WHERE   a.UserId = @userId AND a.WhsCode = @whsCode";

    public const string Items = @"
SELECT  TOP 30
        i.ItemCode    AS itemCode,
        i.ItemName    AS itemName,
        g.ItmsGrpNam  AS groupName,
        ISNULL(i.InvntryUom, 'KG') AS uom
FROM    OITM i
JOIN    OITB g ON g.ItmsGrpCod = i.ItmsGrpCod
WHERE   i.ItemCode LIKE @q OR i.ItemName LIKE @q
ORDER BY i.ItemCode";

    public const string Brands = @"
SELECT  b.DESCRIPTION AS brand
FROM    SYS_GCM b
WHERE   b.CONDITION = 'MSTBRAND'
ORDER BY b.DESCRIPTION";

    /// Daftar dokumen milik cabang user. @objTypes: '6730' untuk inbound; '6710','6720' untuk outbound.
    /// Status:
    ///   Selesai     : DocStatus = 'C' (sudah diposting admin di CMS)
    ///   Menunggu PT : ada baris masuk (Flag 1) tapi PT belum diisi admin  -> label terkunci
    ///   Siap cetak  : ada baris masuk dan PT sudah diisi                  -> label boleh dicetak
    ///   Menunggu DO : outbound tanpa baris masuk, belum diposting
    public const string DocList = @"
SELECT  TOP 60
        h.ObjType      AS objType,
        h.DocEntry     AS docEntry,
        h.DocDate      AS docDate,
        h.TrxCode      AS trxCode,
        h.WhsCode      AS whsCode,
        h.VehicleNo      AS noMobil,
        h.ContainerNo  AS containerNo,
        h.U_IDU_Kode_PT AS ptCode,
        COUNT(d.ItemCode)                                         AS lineCount,
        SUM(CASE WHEN d.flags =  1 THEN 1 ELSE 0 END)              AS inLines,
        SUM(ABS(d.qty))                                      AS qtyKg,
        SUM(ABS(d.Qty2))                                          AS qtySak,
        SUM(ABS(d.QtyPalet))                                      AS qtyPalet,
        SUM(CASE WHEN d.flags = 1 THEN d.QtyPalet ELSE 0 END)      AS labelCount,
        CASE WHEN h.DocStatus = 'C' THEN 'Selesai'
             WHEN SUM(CASE WHEN d.flags = 1 THEN 1 ELSE 0 END) = 0 THEN 'Menunggu DO'
             WHEN ISNULL(h.U_IDU_Kode_PT, '') = '' THEN 'Menunggu PT'
             ELSE 'Siap cetak' END                                AS status
FROM    OKRN h
LEFT JOIN KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
WHERE   h.BPLId = @bplId
  AND   h.ObjType IN @objTypes
  AND   EXISTS (SELECT 1 FROM USR9 a WHERE a.UserId = @userId AND a.WhsCode = h.WhsCode)
  AND   h.DocDate >= DATEADD(day, -45, CAST(GETDATE() AS date))
GROUP BY h.ObjType, h.DocEntry, h.DocDate, h.TrxCode, h.WhsCode, h.VehicleNo, h.ContainerNo, h.U_IDU_Kode_PT, h.DocStatus
ORDER BY h.DocEntry DESC";

    public const string DocHeader = @"
SELECT  h.ObjType AS objType, h.DocEntry AS docEntry, h.DocDate AS docDate, h.TrxCode AS trxCode,
        h.WhsCode AS whsCode, h.VehicleNo AS noMobil, h.ContainerNo AS containerNo,
        h.U_IDU_Kode_PT AS ptCode, p.PrcName AS ptName, h.DocStatus AS docStatus
FROM    OKRN h
LEFT JOIN OPRC p ON p.PrcCode = h.U_IDU_Kode_PT
WHERE   h.ObjType = @objType AND h.DocEntry = @docEntry AND h.BPLId = @bplId
  AND   EXISTS (SELECT 1 FROM USR9 a WHERE a.UserId = @userId AND a.WhsCode = h.WhsCode)";

    public const string DocLines = @"
SELECT  d.LineNum AS lineNum, d.ItemCode AS itemCode, i.ItemName AS itemName, 'KG' AS uom,
        d.brand_name AS brand, d.Origin AS origin, d.KodeRuangan AS kodeRuangan, d.qty AS qty, d.Qty2 AS qty2,
        d.QtyPalet AS qtyPalet, d.flags AS flag
FROM    KRN1 d
JOIN    OITM i ON i.ItemCode = d.ItemCode
WHERE   d.ObjType = @objType AND d.DocEntry = @docEntry
ORDER BY d.LineNum";

    /// Penomoran: SYS_NOURUT.Counter = YYMM + 8 digit (lihat dbo.usp_WHS_NextDocEntry di gudang_atm_relasi.sql)
    public const string NextDocEntry = "dbo.usp_WHS_NextDocEntry";

    public const string InsertHeader = @"
INSERT INTO OKRN (ObjType, DocEntry, DocDate, BPLId, WhsCode, UserId, TrxCode, VehicleNo, ContainerNo, DocStatus, DateCrt, total_qty, total_Sak, Total_Palet)
VALUES (@objType, @docEntry, @docDate, @bplId, @whsCode, @userId, @trxCode, @noMobil, @containerNo, 'O', GETDATE(), 0, 0, 0)";

    /// Total header dari baris (dipanggil setelah semua baris disimpan / diubah).
    public const string UpdateTotals = @"
UPDATE  h SET total_qty = ISNULL(t.q, 0), total_Sak = ISNULL(t.s, 0), Total_Palet = ISNULL(t.p, 0)
FROM    OKRN h OUTER APPLY (SELECT SUM(d.qty) q, SUM(d.Qty2) s, SUM(d.QtyPalet) p FROM KRN1 d WHERE d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry) t
WHERE   h.ObjType = @objType AND h.DocEntry = @docEntry";

    public const string InsertLine = @"
INSERT INTO KRN1 (ObjType, DocEntry, LineNum, ItemCode, brand_name, Origin, qty, Qty2, QtyPalet, flags, LineStatus, KodeRuangan)
VALUES (@objType, @docEntry, @lineNum, @itemCode, @brand, @origin, @qty, @qty2, @qtyPalet, @flag, 'O', @ruang)";

    /// Stok per ruangan untuk item + container di warehouse (dokumen yang sudah diposting).
    public const string StockPerRuangan = @"
SELECT  d.KodeRuangan AS kodeRuangan, r.NamaRuangan AS namaRuangan, CAST(ISNULL(r.Titipan, 0) AS bit) AS titipan,
        SUM(d.qty * d.flags) AS stockKg, SUM(d.Qty2 * d.flags) AS stockSak, SUM(d.QtyPalet * d.flags) AS stockPalet
FROM    OKRN h
JOIN    KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
LEFT JOIN WHS_MasterRuangan r ON r.KodeRuangan = d.KodeRuangan
WHERE   h.DocStatus = 'C' AND h.WhsCode = @whsCode AND d.ItemCode = @itemCode
  AND   ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '') = @containerNo
GROUP BY d.KodeRuangan, r.NamaRuangan, r.Titipan
HAVING  SUM(d.qty * d.flags) > 0
ORDER BY d.KodeRuangan";

    /// Baris inbound asal untuk QR yymmdd-itemcode-container (sumber brand, origin, isi per sak / per palet).
    public const string PalletSource = @"
SELECT  TOP 1
        d.ItemCode AS itemCode, i.ItemName AS itemName, d.brand_name AS brand, d.Origin AS origin,
        h.ContainerNo AS containerNo, h.DocDate AS inboundDate, h.WhsCode AS whsCode,
        d.qty AS qty, d.Qty2 AS qty2, d.QtyPalet AS qtyPalet
FROM    OKRN h
JOIN    KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
JOIN    OITM i ON i.ItemCode = d.ItemCode
WHERE   d.flags = 1 AND d.ItemCode = @itemCode AND ISNULL(h.ContainerNo, '') = @containerNo AND h.BPLId = @bplId
ORDER BY CASE WHEN CONVERT(char(6), h.DocDate, 12) = @yymmdd THEN 0 ELSE 1 END, h.DocDate";

    /// Stok = jumlah qty × Flag dari dokumen yang sudah diposting (Close).
    public const string StockForPallet = @"
SELECT  ISNULL(SUM(d.qty * d.flags), 0) AS stockKg,
        ISNULL(SUM(d.Qty2     * d.flags), 0) AS stockSak,
        ISNULL(SUM(d.QtyPalet * d.flags), 0) AS stockPalet
FROM    OKRN h
JOIN    KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
WHERE   h.DocStatus = 'C' AND h.WhsCode = @whsCode AND d.ItemCode = @itemCode AND ISNULL(h.ContainerNo, '') = @containerNo";

    /// Data label: hanya baris masuk (Flag 1). PT dicetak dari OPRC.PrcName.
    public const string LabelLines = @"
SELECT  d.ItemCode AS itemCode, i.ItemName AS itemName, d.brand_name AS brand,
        d.qty AS qty, d.Qty2 AS qty2, d.QtyPalet AS qtyPalet
FROM    KRN1 d
JOIN    OITM i ON i.ItemCode = d.ItemCode
WHERE   d.ObjType = @objType AND d.DocEntry = @docEntry AND d.flags = 1
ORDER BY d.LineNum";

    public const string StockPerItem = @"
SELECT  d.ItemCode AS itemCode, i.ItemName AS itemName,
        SUM(d.qty * d.flags) AS kg, SUM(d.Qty2 * d.flags) AS sak, SUM(d.QtyPalet * d.flags) AS palet,
        COUNT(DISTINCT h.ContainerNo) AS containers
FROM    OKRN h
JOIN    KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
JOIN    OITM i ON i.ItemCode = d.ItemCode
WHERE   h.DocStatus = 'C' AND h.BPLId = @bplId AND (@whsCode IS NULL OR h.WhsCode = @whsCode)
  AND   EXISTS (SELECT 1 FROM USR9 a WHERE a.UserId = @userId AND a.WhsCode = h.WhsCode)
GROUP BY d.ItemCode, i.ItemName
HAVING  SUM(d.qty * d.flags) <> 0
ORDER BY d.ItemCode";

    public const string StockPerContainer = @"
SELECT  h.ContainerNo AS containerNo, d.ItemCode AS itemCode, i.ItemName AS itemName, MAX(d.brand_name) AS brand,
        MIN(CASE WHEN d.flags = 1 THEN h.DocDate END) AS inboundDate,
        SUM(d.qty * d.flags) AS kg, SUM(d.Qty2 * d.flags) AS sak, SUM(d.QtyPalet * d.flags) AS palet
FROM    OKRN h
JOIN    KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
JOIN    OITM i ON i.ItemCode = d.ItemCode
WHERE   h.DocStatus = 'C' AND h.BPLId = @bplId AND (@whsCode IS NULL OR h.WhsCode = @whsCode)
  AND   EXISTS (SELECT 1 FROM USR9 a WHERE a.UserId = @userId AND a.WhsCode = h.WhsCode)
GROUP BY h.ContainerNo, d.ItemCode, i.ItemName
HAVING  SUM(d.qty * d.flags) <> 0
ORDER BY h.ContainerNo, d.ItemCode";

    public const string StockCard = @"
SELECT  h.DocDate AS docDate, h.ObjType AS objType, h.DocEntry AS docEntry, h.TrxCode AS trxCode,
        h.ContainerNo AS containerNo, d.flags AS flag,
        d.qty * d.flags AS kg, d.Qty2 * d.flags AS sak, d.QtyPalet * d.flags AS palet
FROM    OKRN h
JOIN    KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
WHERE   h.DocStatus = 'C' AND h.BPLId = @bplId AND d.ItemCode = @itemCode
  AND   (@whsCode IS NULL OR h.WhsCode = @whsCode)
  AND   (@containerNo IS NULL OR h.ContainerNo = @containerNo)
  AND   EXISTS (SELECT 1 FROM USR9 a WHERE a.UserId = @userId AND a.WhsCode = h.WhsCode)
ORDER BY h.DocDate, h.DocEntry, d.LineNum";

    public const string Kpi = @"
SELECT  SUM(CASE WHEN h.ObjType = '6730' THEN 1 ELSE 0 END)                       AS inboundDocs,
        SUM(CASE WHEN h.ObjType <> '6730' THEN 1 ELSE 0 END)                      AS outboundDocs,
        SUM(CASE WHEN h.DocStatus <> 'C' THEN 1 ELSE 0 END)                       AS openDocs,
        SUM(CASE WHEN h.DocStatus <> 'C' AND ISNULL(h.U_IDU_Kode_PT,'') = '' THEN 1 ELSE 0 END) AS waitingPt,
        ISNULL(SUM(x.kgIn), 0)    AS kgIn,
        ISNULL(SUM(x.kgOut), 0)   AS kgOut,
        ISNULL(SUM(x.palIn), 0)   AS paletIn,
        ISNULL(SUM(x.palOut), 0)  AS paletOut
FROM    OKRN h
OUTER APPLY (
    SELECT SUM(CASE WHEN d.flags =  1 THEN d.qty ELSE 0 END) AS kgIn,
           SUM(CASE WHEN d.flags = -1 THEN d.qty ELSE 0 END) AS kgOut,
           SUM(CASE WHEN d.flags =  1 THEN d.QtyPalet ELSE 0 END) AS palIn,
           SUM(CASE WHEN d.flags = -1 THEN d.QtyPalet ELSE 0 END) AS palOut
    FROM KRN1 d WHERE d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
) x
WHERE   h.BPLId = @bplId AND h.DocDate BETWEEN @from AND @to
  AND   (@whsCode IS NULL OR h.WhsCode = @whsCode)
  AND   EXISTS (SELECT 1 FROM USR9 a WHERE a.UserId = @userId AND a.WhsCode = h.WhsCode)";

    // ================================================================ CMS (Admin)

    /// Antrian dokumen untuk dicek Admin. @status: 'O' open, 'C' close, NULL semua.
    public const string CmsList = @"
SELECT  TOP 200
        h.ObjType AS objType, h.DocEntry AS docEntry, h.DocDate AS docDate, h.TrxCode AS trxCode,
        h.WhsCode AS whsCode, w.WhsName AS whsName,
        CAST(CASE WHEN w.[External] = 'Y' THEN 1 ELSE 0 END AS bit) AS isTitipan,
        h.VehicleNo AS noMobil, h.ContainerNo AS containerNo,
        h.U_IDU_Kode_PT AS ptCode, p.PrcName AS ptName,
        h.CardCode AS cardCode, c.CardName AS cardName, h.NumAtCard AS numAtCard, h.U_NoBL AS blNo,
        u.USER_CODE AS krani, h.DocStatus AS docStatus,
        x.lineCount, x.qtyKg, x.qtySak, x.qtyPalet, x.editedLines
FROM    OKRN h
LEFT JOIN OWHS w ON w.WhsCode = h.WhsCode
LEFT JOIN OPRC p ON p.PrcCode = h.U_IDU_Kode_PT
LEFT JOIN OCRD c ON c.CardCode = h.CardCode
LEFT JOIN OUSR u ON u.USERID = h.UserId
OUTER APPLY (
    SELECT COUNT(*) AS lineCount, SUM(d.qty) AS qtyKg, SUM(d.Qty2) AS qtySak, SUM(d.QtyPalet) AS qtyPalet,
           SUM(CASE WHEN d.qty_scan IS NOT NULL OR d.qty2_scan IS NOT NULL OR d.QtyPalet_scan IS NOT NULL THEN 1 ELSE 0 END) AS editedLines
    FROM KRN1 d WHERE d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
) x
WHERE   h.BPLId = @bplId
  AND   (@status IS NULL OR h.DocStatus = @status)
  AND   (@objType IS NULL OR h.ObjType = @objType)
ORDER BY CASE WHEN h.DocStatus = 'O' THEN 0 ELSE 1 END, h.DocDate DESC, h.DocEntry DESC";

    public const string CmsHeader = @"
SELECT  h.ObjType AS objType, h.DocEntry AS docEntry, h.DocDate AS docDate, h.TrxCode AS trxCode,
        h.WhsCode AS whsCode, w.WhsName AS whsName,
        CAST(CASE WHEN w.[External] = 'Y' THEN 1 ELSE 0 END AS bit) AS isTitipan,
        h.VehicleNo AS noMobil, h.ContainerNo AS containerNo,
        h.U_IDU_Kode_PT AS ptCode, p.PrcName AS ptName,
        h.CardCode AS cardCode, c.CardName AS cardName, c.CardType AS cardType,
        h.NumAtCard AS numAtCard, h.U_NoBL AS blNo, u.USER_CODE AS krani, h.DocStatus AS docStatus
FROM    OKRN h
LEFT JOIN OWHS w ON w.WhsCode = h.WhsCode
LEFT JOIN OPRC p ON p.PrcCode = h.U_IDU_Kode_PT
LEFT JOIN OCRD c ON c.CardCode = h.CardCode
LEFT JOIN OUSR u ON u.USERID = h.UserId
WHERE   h.ObjType = @objType AND h.DocEntry = @docEntry AND h.BPLId = @bplId";

    public const string CmsLines = @"
SELECT  d.LineNum AS lineNum, d.ItemCode AS itemCode, i.ItemName AS itemName, g.ItmsGrpNam AS groupName,
        'KG' AS uom, d.brand_name AS brand, d.Origin AS origin, d.KodeRuangan AS kodeRuangan, d.flags AS flag,
        d.qty AS qty, d.Qty2 AS qty2, d.QtyPalet AS qtyPalet,
        d.qty_scan AS qtyScan, d.qty2_scan AS qty2Scan, d.QtyPalet_scan AS qtyPaletScan,
        d.NumAtCard AS numAtCard, d.LineStatus AS lineStatus
FROM    KRN1 d
JOIN    OITM i ON i.ItemCode = d.ItemCode
JOIN    OITB g ON g.ItmsGrpCod = i.ItmsGrpCod
WHERE   d.ObjType = @objType AND d.DocEntry = @docEntry
ORDER BY d.LineNum";

    public const string PtLookup = @"
SELECT  TOP 30 p.PrcCode AS code, p.PrcName AS name
FROM    OPRC p
WHERE   p.PrcCode LIKE @q OR p.PrcName LIKE @q
ORDER BY p.PrcCode";

    public const string BpLookup = @"
SELECT  TOP 30 c.CardCode AS code, c.CardName AS name
FROM    OCRD c
WHERE   c.CardType = @cardType AND (c.CardCode LIKE @q OR c.CardName LIKE @q)
ORDER BY c.CardName";

    public const string PtExists = "SELECT COUNT(*) FROM OPRC WHERE PrcCode = @ptCode";
    public const string CardType = "SELECT CardType FROM OCRD WHERE CardCode = @cardCode";

    /// Retur Customer: No DO per baris harus ada di ODLN milik customer tsb.
    public const string ReturDoValid = @"
SELECT  COUNT(*) FROM ODLN o
WHERE   o.DocNum = TRY_CAST(@numAtCard AS INT) AND o.CardCode = @cardCode AND o.CANCELED = 'N'";

    /// Backup nilai krani ke *_scan hanya sekali (saat pertama kali diedit Admin), lalu tulis nilai baru.
    public const string CmsUpdateLine = @"
UPDATE  KRN1
SET     qty_scan      = CASE WHEN qty_scan      IS NULL AND qty      <> @qty      THEN qty      ELSE qty_scan END,
        qty2_scan     = CASE WHEN qty2_scan     IS NULL AND Qty2     <> @qty2     THEN Qty2     ELSE qty2_scan END,
        QtyPalet_scan = CASE WHEN QtyPalet_scan IS NULL AND QtyPalet <> @qtyPalet THEN QtyPalet ELSE QtyPalet_scan END,
        qty = @qty, Qty2 = @qty2, QtyPalet = @qtyPalet, NumAtCard = @numAtCard
WHERE   ObjType = @objType AND DocEntry = @docEntry AND LineNum = @lineNum AND LineStatus = 'O'";

    public const string CmsUpdateHeader = @"
UPDATE  OKRN
SET     TrxCode = @trxCode, U_IDU_Kode_PT = @ptCode, CardCode = @cardCode, NumAtCard = @numAtCard, U_NoBL = @blNo
WHERE   ObjType = @objType AND DocEntry = @docEntry AND BPLId = @bplId AND DocStatus = 'O'";

    /// Pindah ObjType (mis. KR 6720 <-> SS 6710): dokumen mendapat nomor baru dari SYS_NOURUT.
    public const string MoveLines = @"
UPDATE KRN1 SET ObjType = @newObjType, DocEntry = @newDocEntry WHERE ObjType = @objType AND DocEntry = @docEntry";
    public const string MoveHeader = @"
UPDATE OKRN SET ObjType = @newObjType, DocEntry = @newDocEntry WHERE ObjType = @objType AND DocEntry = @docEntry AND BPLId = @bplId";

    public const string CloseLines = "UPDATE KRN1 SET LineStatus = 'C' WHERE ObjType = @objType AND DocEntry = @docEntry";
    public const string CloseHeader = @"
UPDATE OKRN SET DocStatus = 'C' WHERE ObjType = @objType AND DocEntry = @docEntry AND BPLId = @bplId AND DocStatus = 'O'";

    public const string Audit = @"
INSERT INTO WHS_AuditLog (LogTime, UserId, UserCode, Action, ObjType, DocEntry, Detail, IpAddress)
VALUES (SYSDATETIME(), @userId, @userCode, @action, @objType, @docEntry, @detail, @ip)";
}
