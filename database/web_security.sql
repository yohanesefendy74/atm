/* =====================================================================
   Gudang ATM – persiapan database untuk Web App (CMS Admin + Krani)
   Jalankan di WORKSHOP_STAGING. Aman dijalankan ulang (cek IF NOT EXISTS).
   ===================================================================== */
USE WORKSHOP_STAGING;
GO

/* 1. Audit log: login, logout, buat dokumen, simpan & posting CMS */
IF OBJECT_ID('dbo.WHS_AuditLog') IS NULL
BEGIN
    CREATE TABLE dbo.WHS_AuditLog (
        LogId     BIGINT IDENTITY(1,1) PRIMARY KEY,
        LogTime   DATETIME2(0)   NOT NULL,
        UserId    INT            NULL,
        UserCode  NVARCHAR(50)   NULL,
        Action    NVARCHAR(30)   NOT NULL,   -- LOGIN_OK, LOGIN_FAIL, LOGIN_LOCKED, LOGOUT, CREATE, CMS_SAVE, CMS_POST
        ObjType   NVARCHAR(20)   NULL,
        DocEntry  BIGINT         NULL,
        Detail    NVARCHAR(1000) NULL,
        IpAddress NVARCHAR(64)   NULL
    );
    CREATE INDEX IX_WHS_AuditLog_Doc ON dbo.WHS_AuditLog (ObjType, DocEntry);
    CREATE INDEX IX_WHS_AuditLog_Time ON dbo.WHS_AuditLog (LogTime);
END
GO

/* 2. Kolom yang dipakai CMS. Hanya ditambahkan bila BELUM ada
      (bila nama kolom di database berbeda, ubah Sql.cs, jangan tambah kolom baru). */
IF COL_LENGTH('dbo.OKRN', 'NumAtCard')     IS NULL ALTER TABLE dbo.OKRN ADD NumAtCard NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.OKRN', 'U_NoBL')        IS NULL ALTER TABLE dbo.OKRN ADD U_NoBL NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.KRN1', 'NumAtCard')     IS NULL ALTER TABLE dbo.KRN1 ADD NumAtCard NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.KRN1', 'qty_scan')      IS NULL ALTER TABLE dbo.KRN1 ADD qty_scan NUMERIC(19,6) NULL;
IF COL_LENGTH('dbo.KRN1', 'qty2_scan')     IS NULL ALTER TABLE dbo.KRN1 ADD qty2_scan NUMERIC(19,6) NULL;
IF COL_LENGTH('dbo.KRN1', 'QtyPalet_scan') IS NULL ALTER TABLE dbo.KRN1 ADD QtyPalet_scan NUMERIC(19,6) NULL;
GO

/* 3. Login SQL khusus aplikasi (jangan pakai sa). Ganti password sebelum dijalankan. */
-- CREATE LOGIN gudang_app WITH PASSWORD = 'GANTI-password-kuat', CHECK_POLICY = ON;
-- CREATE USER gudang_app FOR LOGIN gudang_app;
-- GRANT SELECT ON dbo.OUSR TO gudang_app;  GRANT SELECT ON dbo.USR9 TO gudang_app;
-- GRANT SELECT ON dbo.OWHS TO gudang_app;  GRANT SELECT ON dbo.OITM TO gudang_app;
-- GRANT SELECT ON dbo.OITB TO gudang_app;  GRANT SELECT ON dbo.OPRC TO gudang_app;
-- GRANT SELECT ON dbo.OCRD TO gudang_app;  GRANT SELECT ON dbo.ODLN TO gudang_app;
-- GRANT SELECT ON dbo.SYS_GCM TO gudang_app;
-- GRANT SELECT, INSERT, UPDATE ON dbo.OKRN TO gudang_app;
-- GRANT SELECT, INSERT, UPDATE ON dbo.KRN1 TO gudang_app;
-- GRANT INSERT ON dbo.WHS_AuditLog TO gudang_app; GRANT SELECT ON dbo.WHS_AuditLog TO gudang_app;
-- GRANT EXECUTE ON dbo.usp_WHS_NextDocEntry TO gudang_app;
-- GRANT EXECUTE ON dbo.usp_WHS_PostStock TO gudang_app;   -- bila dipakai

/* 4. (Opsional) Posting ke SaldoWhs / ItemHistoryWhs.
      Isi appsettings "Posting:StockProcedure": "dbo.usp_WHS_PostStock" untuk mengaktifkan.
      Kolom disesuaikan dengan struktur asli SaldoWhs / ItemHistoryWhs (Okt 2026). Belum diuji dengan data. */
-- Stok per ruangan: SaldoWhs & ItemHistoryWhs ikut menyimpan ruangan
IF COL_LENGTH('dbo.ItemHistoryWhs','KodeRuangan') IS NULL ALTER TABLE dbo.ItemHistoryWhs ADD KodeRuangan NVARCHAR(30) NULL;
IF COL_LENGTH('dbo.SaldoWhs','KodeRuangan')       IS NULL ALTER TABLE dbo.SaldoWhs ADD KodeRuangan NVARCHAR(30) NULL;
GO
CREATE OR ALTER PROCEDURE dbo.usp_WHS_PostStock
    @ObjType  NVARCHAR(20),
    @DocEntry BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    -- Riwayat mutasi per baris: Qty bertanda (qty x flags: +masuk / -keluar)
    INSERT INTO dbo.ItemHistoryWhs (ItemCode, BPLId, WhsCode, DocDate, ObjType, DocEntry, DocNum, LineNum, DistNumber,
                                    Qty, Qty2, QtyPalet, CardCode, ItemName, CreateDate, U_IDU_Kode_PT, Brand_name, ContainerNo, KodeRuangan)
    SELECT d.ItemCode, h.BPLId, h.WhsCode, h.DocDate, h.ObjType, h.DocEntry, h.DocEntry, d.LineNum, d.DistNumber,
           d.qty * d.flags, d.Qty2 * d.flags, d.QtyPalet * d.flags, h.cardcode, i.ItemName, GETDATE(), h.U_IDU_Kode_PT, d.brand_name,
           COALESCE(d.ContainerNo, h.ContainerNo), d.KodeRuangan
    FROM   dbo.OKRN h JOIN dbo.KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
           LEFT JOIN dbo.OITM i ON i.ItemCode = d.ItemCode
    WHERE  h.ObjType = @ObjType AND h.DocEntry = @DocEntry;

    -- Saldo per warehouse + item + container + DistNumber
    MERGE dbo.SaldoWhs AS s
    USING (
        SELECT h.WhsCode, d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '') AS ContainerNo, ISNULL(d.DistNumber, '') AS DistNumber, d.KodeRuangan,
               MAX(h.U_IDU_Kode_PT) AS PT, MAX(h.cardcode) AS CardCode,
               SUM(d.qty * d.flags) AS Qty, SUM(d.Qty2 * d.flags) AS Qty2, SUM(d.QtyPalet * d.flags) AS QtyPalet
        FROM   dbo.OKRN h JOIN dbo.KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
        WHERE  h.ObjType = @ObjType AND h.DocEntry = @DocEntry
        GROUP BY h.WhsCode, d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), ''), ISNULL(d.DistNumber, ''), d.KodeRuangan
    ) AS m
    ON s.WhsCode = m.WhsCode AND s.ItemCode = m.ItemCode AND ISNULL(s.ContainerNo, '') = m.ContainerNo AND ISNULL(s.DistNumber, '') = m.DistNumber
       AND ISNULL(s.KodeRuangan, '') = ISNULL(m.KodeRuangan, '')
    WHEN MATCHED THEN UPDATE SET s.Qty = s.Qty + m.Qty, s.Qty2 = s.Qty2 + m.Qty2, s.QtyPalet = s.QtyPalet + m.QtyPalet
    WHEN NOT MATCHED THEN INSERT (ItemCode, DistNumber, WhsCode, Qty, Qty2, QtyPalet, cardcode, DocDate, U_IDU_Kode_PT, ObjType, DocEntry, ContainerNo, KodeRuangan)
                          VALUES (m.ItemCode, NULLIF(m.DistNumber, ''), m.WhsCode, m.Qty, m.Qty2, m.QtyPalet, m.CardCode, GETDATE(), m.PT, @ObjType, @DocEntry, NULLIF(m.ContainerNo, ''), m.KodeRuangan);
END
GO
