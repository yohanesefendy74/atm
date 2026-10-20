/* =====================================================================
   Gudang ATM – query relasi master (database WORKSHOP_STAGING)
   Relasi sesuai arahan user, 09 Okt 2026.
   Kolom bertanda -- ASUMSI belum dicek ke skema asli: sesuaikan.
   Semua query memakai parameter (@...) — jangan gabung string dari input user.
   ===================================================================== */
USE WORKSHOP_STAGING;
GO

/* ---------------------------------------------------------------------
   1. LOGIN
   Aplikasi meng-encode password input ke Base64, lalu dibandingkan
   dengan OUSR.password. Hasilnya dipakai sebagai konteks sesi:
   BPLId (cabang), WhsCode (gudang), status Titipan.
   --------------------------------------------------------------------- */
DECLARE @user_code NVARCHAR(50), @password_b64 NVARCHAR(256), @WhsCode NVARCHAR(8);

SELECT  u.USERID,
        u.USER_CODE,
        u.U_NAME                AS NamaUser,        -- ASUMSI nama kolom nama user
        u.Branch                AS BPLId,
        u.Fax                   AS WhsCode,
        w.WhsName,
        w.[External],
        CASE WHEN w.[External] = 'Y' THEN 1 ELSE 0 END AS IsTitipan
FROM    OUSR u
LEFT JOIN OWHS w ON w.WhsCode = u.Fax
WHERE   u.USER_CODE = @user_code
  AND   u.[password] = @password_b64;


/* ---------------------------------------------------------------------
   1b. PILIHAN WAREHOUSE USER (multi) — OKRN.WhsCode = USR9.WhsCode
   Tampil sebagai pilihan di header Inbound/Outbound; default = OUSR.Fax.
   --------------------------------------------------------------------- */
DECLARE @UserId INT;                                  -- OUSR.USERID dari hasil login

SELECT  w.WhsCode,
        w.WhsName,
        CASE WHEN w.[External] = 'Y' THEN 1 ELSE 0 END AS IsTitipan,
        CASE WHEN w.WhsCode = u.Fax THEN 1 ELSE 0 END AS IsDefault
FROM    USR9 a
JOIN    OWHS w ON w.WhsCode = a.WhsCode
JOIN    OUSR u ON u.USERID  = a.UserId                -- ASUMSI kolom user di USR9
WHERE   a.UserId = @UserId
ORDER BY IsDefault DESC, w.WhsCode;

-- Validasi saat simpan: gudang dokumen harus ada di hak akses user
SELECT  CASE WHEN EXISTS (
          SELECT 1 FROM USR9 a WHERE a.UserId = @UserId AND a.WhsCode = @WhsCode
        ) THEN 1 ELSE 0 END AS WhsAllowed;


/* ---------------------------------------------------------------------
   2. LOOKUP / DROPDOWN
   --------------------------------------------------------------------- */
DECLARE @search NVARCHAR(100);                         -- teks yang diketik user
DECLARE @q NVARCHAR(102) = N'%' + ISNULL(@search, N'') + N'%';

-- 2a. PT (OKRN.U_IDU_Kode_PT = OPRC.PrcCode)
SELECT  p.PrcCode, p.PrcName                         -- ASUMSI PrcName
FROM    OPRC p
WHERE   p.PrcCode LIKE @q OR p.PrcName LIKE @q
ORDER BY p.PrcCode;

-- 2b. Supplier (Inbound Supplier / Titipan)
SELECT  c.CardCode, c.CardName
FROM    OCRD c
WHERE   c.CardType = 'S'
  AND  (c.CardCode LIKE @q OR c.CardName LIKE @q)
ORDER BY c.CardName;

-- 2c. Customer (Outbound, Retur Customer)
SELECT  c.CardCode, c.CardName
FROM    OCRD c
WHERE   c.CardType = 'C'
  AND  (c.CardCode LIKE @q OR c.CardName LIKE @q)
ORDER BY c.CardName;

-- 2d. Item + nama grup (KRN1.ItemCode = OITM.ItemCode)
SELECT  i.ItemCode, i.ItemName, i.ItmsGrpCod, g.ItmsGrpNam
FROM    OITM i
JOIN    OITB g ON g.ItmsGrpCod = i.ItmsGrpCod
WHERE   i.ItemCode LIKE @q OR i.ItemName LIKE @q
ORDER BY i.ItemCode;

-- 2e. Brand (KRN1.brand_name = SYS_GCM.DESCRIPTION)
SELECT  b.DESCRIPTION AS Brand
FROM    SYS_GCM b
WHERE   b.CONDITION = 'MSTBRAND'
ORDER BY b.DESCRIPTION;


/* ---------------------------------------------------------------------
   3. CMS – daftar dokumen untuk dicek (difilter cabang user login)
   --------------------------------------------------------------------- */
DECLARE @BPLId INT;

SELECT  h.*,
        w.WhsName,
        CASE WHEN w.[External] = 'Y' THEN 'Titipan' ELSE 'Milik sendiri' END AS JenisBarang,
        p.PrcName               AS NamaPT,
        c.CardName,
        c.CardType,
        u.USER_CODE             AS Krani
FROM    OKRN h
LEFT JOIN OWHS w ON w.WhsCode  = h.WhsCode
LEFT JOIN OPRC p ON p.PrcCode  = h.U_IDU_Kode_PT
LEFT JOIN OCRD c ON c.CardCode = h.CardCode
LEFT JOIN OUSR u ON u.USERID   = h.UserId
WHERE   h.BPLId = @BPLId;


/* ---------------------------------------------------------------------
   4. CMS – detail dokumen
   --------------------------------------------------------------------- */
DECLARE @DocEntry BIGINT, @ObjType NVARCHAR(20);      -- '6730' Inbound / '6710' Outbound

SELECT  d.*,
        i.ItemName,
        g.ItmsGrpNam,
        CASE WHEN b.DESCRIPTION IS NULL THEN 0 ELSE 1 END AS BrandValid
FROM    OKRN h
JOIN    KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
JOIN    OITM i ON i.ItemCode   = d.ItemCode
JOIN    OITB g ON g.ItmsGrpCod = i.ItmsGrpCod
LEFT JOIN SYS_GCM b ON b.CONDITION = 'MSTBRAND' AND b.DESCRIPTION = d.brand_name
WHERE   h.ObjType = @ObjType AND h.DocEntry = @DocEntry;


/* ---------------------------------------------------------------------
   5. VALIDASI SEBELUM POSTING
   --------------------------------------------------------------------- */
DECLARE @CardCode NVARCHAR(50), @TrxCode NVARCHAR(20), @NumAtCard NVARCHAR(100);

-- 5a. CardType harus cocok dengan TrxCode + ObjType
--     IB, BT di 6730 -> Supplier 'S' ; OB, BT di 6710, RC -> Customer 'C' ; KR, SS -> tanpa CardCode
SELECT  CASE
          WHEN @TrxCode = 'IB' AND c.CardType = 'S' THEN 1
          WHEN @TrxCode = 'BT' AND @ObjType = '6730' AND c.CardType = 'S' THEN 1
          WHEN @TrxCode = 'BT' AND @ObjType = '6710' AND c.CardType = 'C' THEN 1
          WHEN @TrxCode IN ('OB','RC') AND c.CardType = 'C' THEN 1
          ELSE 0 END AS CardTypeValid
FROM    OCRD c
WHERE   c.CardCode = @CardCode;

-- 5c. TrxCode harus cocok dengan ObjType, dan Flag baris harus konsisten
--     6730 Inbound    : IB, BT, RC -> Flag = 1
--     6710 Outbound   : OB, BT     -> Flag = -1
--     6710 Susut      : SS         -> Flag = -1
--     6720 Penyesuaian: KR         -> Flag 1 atau -1
--     6720 Repacking  : RP         -> Flag 1 atau -1  (ASUMSI ObjType 6720)
SELECT  h.ObjType, h.DocEntry, h.TrxCode, d.LineNum, d.flags,   -- ASUMSI LineNum
        'Flag/TrxCode tidak sesuai' AS Masalah
FROM    OKRN h
JOIN    KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
WHERE   h.ObjType = @ObjType AND h.DocEntry = @DocEntry
  AND NOT (
        (h.TrxCode IN ('IB','BT','RC') AND h.ObjType = '6730' AND d.flags = 1)
     OR (h.TrxCode IN ('OB','BT','SS') AND h.ObjType = '6710' AND d.flags = -1)
     OR (h.TrxCode IN ('KR','RP')      AND h.ObjType = '6720' AND d.flags IN (1,-1))
  );

-- 5d. BT otomatis dari warehouse: Whs titipan (OWHS.External = 'Y') wajib BT,
--     Whs biasa tidak boleh BT. KR & RP tidak boleh di Whs titipan.
--     Retur Customer (RC) tidak ikut aturan ini.
SELECT  h.ObjType, h.DocEntry, h.WhsCode, w.[External], h.TrxCode,
        CASE WHEN w.[External] = 'Y' AND h.TrxCode IN ('KR','RP') THEN 'KR/RP tidak boleh di Whs titipan'
             WHEN w.[External] = 'Y' THEN 'BT harus dipakai'
             ELSE 'BT tidak boleh' END AS Masalah
FROM    OKRN h
JOIN    OWHS w ON w.WhsCode = h.WhsCode
WHERE   h.ObjType = @ObjType AND h.DocEntry = @DocEntry
  AND   h.TrxCode IN ('IB','OB','BT','KR','RP')
  AND ( (w.[External] = 'Y' AND h.TrxCode <> 'BT')
     OR (ISNULL(w.[External],'N') <> 'Y' AND h.TrxCode = 'BT') );

-- Nilai TrxCode default saat dokumen dibuat dari HP:
--   SELECT CASE WHEN w.[External] = 'Y' THEN 'BT'
--               WHEN @ObjType = '6730' THEN 'IB' ELSE 'OB' END
--   FROM OWHS w WHERE w.WhsCode = @WhsCode;

-- 5b. Retur: NumAtCard per baris harus ada di ODLN milik customer tsb
SELECT  CASE WHEN EXISTS (
          SELECT 1 FROM ODLN o
          WHERE  o.DocNum   = TRY_CAST(@NumAtCard AS INT)  -- sesuaikan bila format berbeda
            AND  o.CardCode = @CardCode
            AND  o.CANCELED = 'N'
        ) THEN 1 ELSE 0 END AS ReturDOValid;
GO


/* ---------------------------------------------------------------------
   6. PENOMORAN DOKUMEN — OKRN.DocEntry = SYS_NOURUT.Counter
   ObjectCode = ObjType + 'WHS' ('6730WHS' Inbound, '6710WHS' Outbound & Susut,
                '6720WHS' Penyesuaian & Repacking)
   Period     = bulan DocDate (YYMM), counter reset tiap bulan
   Format     = YYMM + 8 digit  -> 2610 00000001 = 261000000001
   PENTING: 12 digit melebihi batas INT (2.147.483.647) — DocEntry di OKRN,
   KRN1 dan SYS_NOURUT.Counter harus BIGINT / NUMERIC(12,0).
   Counter menyimpan nomor lengkap (dikonfirmasi: 261000000001).
   ASUMSI: Period disimpan sebagai teks 'YYMM'.
   Dipanggil di dalam transaksi yang sama dengan INSERT OKRN/KRN1.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_WHS_NextDocEntry
    @ObjType  NVARCHAR(20),
    @DocDate  DATE,
    @DocEntry BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ObjectCode NVARCHAR(30) = @ObjType + N'WHS';
    DECLARE @Period     NVARCHAR(4)  = LEFT(CONVERT(CHAR(6), @DocDate, 12), 4);   -- yyMM
    DECLARE @Base       BIGINT       = CAST(@Period AS BIGINT) * 100000000;        -- YYMM00000000

    BEGIN TRAN;

    -- UPDLOCK + HOLDLOCK: dua krani yang simpan bersamaan tidak dapat nomor sama
    UPDATE SYS_NOURUT WITH (UPDLOCK, HOLDLOCK)
       SET @DocEntry = Counter = CASE WHEN Counter < @Base THEN @Base + 1 ELSE Counter + 1 END
     WHERE ObjectCode = @ObjectCode
       AND Period     = @Period;

    IF @@ROWCOUNT = 0
    BEGIN
        SET @DocEntry = @Base + 1;                    -- nomor pertama di bulan ini
        INSERT INTO SYS_NOURUT (ObjectCode, Period, Counter)
        VALUES (@ObjectCode, @Period, @DocEntry);
    END

    COMMIT;
END
GO

/* Contoh pemakaian saat simpan inbound:
   DECLARE @NewDocEntry BIGINT;
   EXEC dbo.usp_WHS_NextDocEntry @ObjType = '6730', @DocDate = '2026-10-09', @DocEntry = @NewDocEntry OUTPUT;
   -- INSERT OKRN (ObjType, DocEntry, ...) VALUES ('6730', @NewDocEntry, ...);
   -- INSERT KRN1 (ObjType, DocEntry, ..., Flag) VALUES ('6730', @NewDocEntry, ..., 1);
*/


/* ---------------------------------------------------------------------
   7. MUTASI STOCK DARI DOKUMEN CLOSED (dasar ItemHistoryWhs / SaldoWhs)
   Qty bertanda = qty × Flag. ASUMSI nama kolom qty: Quantity, Qty2, QtyPalet;
   status close: DocStatus/LineStatus = 'C'.
   --------------------------------------------------------------------- */
SELECT  h.WhsCode,
        h.ContainerNo,
        d.ItemCode,
        h.U_IDU_Kode_PT          AS PT,
        d.brand_name,
        SUM(d.qty * d.flags) AS QtyKG,
        SUM(d.Qty2     * d.flags) AS QtySak,
        SUM(d.QtyPalet * d.flags) AS QtyPalet
FROM    OKRN h
JOIN    KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
WHERE   h.DocStatus = 'C' AND d.LineStatus = 'C'
GROUP BY h.WhsCode, h.ContainerNo, d.ItemCode, h.U_IDU_Kode_PT, d.brand_name;

-- ============================================================
-- Data cetak label QR (HP krani)
-- Label hanya bisa dicetak bila PT sudah diisi Admin (okrn.U_IDU_Kode_PT)
-- Baris PT di label = OPRC.PrcName. Supplier tidak dicetak.
-- ============================================================
SELECT  h.DocEntry, h.ContainerNo, h.DocDate,
        d.ItemCode, i.ItemName, d.Brand_Name, d.QtyPalet,
        p.PrcName AS NamaPT,
        RIGHT(CONVERT(CHAR(8), h.DocDate, 112), 6) + '-' + d.ItemCode + '-' + h.ContainerNo AS IsiQR  -- yymmdd-itemcode-container
FROM    OKRN h
JOIN    KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
JOIN    OITM i ON i.ItemCode = d.ItemCode
JOIN    OPRC p ON p.PrcCode = h.U_IDU_Kode_PT
WHERE   h.ObjType = @ObjType AND h.DocEntry = @DocEntry
  AND   d.flags = 1                                  -- hanya baris masuk (inbound / Item Inbound KR-RP)
  AND   ISNULL(h.U_IDU_Kode_PT, '') <> '';          -- terkunci sampai PT diisi Admin
