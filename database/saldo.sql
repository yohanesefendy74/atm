/* Gudang ATM - tabel saldo stok WHS_Saldo + index transaksi.
   Saldo diperbarui saat Admin POSTING dokumen di CMS (transaksi yang sama). Laporan stok & cek stok membaca tabel ini.
   Kartu stok tetap dari transaksi (OKRN/KRN1). Jalankan sekali dengan akun admin; aman diulang.
   Setelah membuat tabel, jalankan:  EXEC dbo.usp_WHS_SaldoRebuild;   (isi awal dari semua dokumen yang sudah diposting) */
USE WORKSHOP_STAGING;
GO

/* 1. Index transaksi (kartu stok, pengecekan, rebuild) */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_OKRN_Status_Whs' AND object_id = OBJECT_ID('dbo.OKRN'))
    CREATE INDEX IX_OKRN_Status_Whs ON dbo.OKRN (DocStatus, WhsCode) INCLUDE (ContainerNo, DocDate, TrxCode, BPLId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_KRN1_Item_Ruang' AND object_id = OBJECT_ID('dbo.KRN1'))
    CREATE INDEX IX_KRN1_Item_Ruang ON dbo.KRN1 (ItemCode, KodeRuangan) INCLUDE (qty, Qty2, QtyPalet, flags, ContainerNo);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_KRN1_Doc' AND object_id = OBJECT_ID('dbo.KRN1'))
    CREATE INDEX IX_KRN1_Doc ON dbo.KRN1 (ObjType, DocEntry) INCLUDE (ItemCode, KodeRuangan, qty, Qty2, QtyPalet, flags, ContainerNo, brand_name);
GO

/* 2. Saldo: satu baris per gudang + ruangan + item + container. '' = tanpa ruangan / tanpa container (data lama). */
IF OBJECT_ID('dbo.WHS_Saldo') IS NULL
CREATE TABLE dbo.WHS_Saldo (
    WhsCode     NVARCHAR(8)   NOT NULL,
    KodeRuangan NVARCHAR(30)  NOT NULL,
    ItemCode    NVARCHAR(50)  NOT NULL,
    ContainerNo NVARCHAR(20)  NOT NULL,
    Kg          NUMERIC(19,6) NOT NULL DEFAULT 0,
    Sak         NUMERIC(19,6) NOT NULL DEFAULT 0,
    Palet       NUMERIC(19,6) NOT NULL DEFAULT 0,
    Brand       NVARCHAR(100) NULL,           -- merek terakhir yang masuk
    TglMasuk    DATE          NULL,           -- tanggal masuk pertama (umur stok)
    UpdatedAt   DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_WHS_Saldo PRIMARY KEY (WhsCode, KodeRuangan, ItemCode, ContainerNo)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WHS_Saldo_Item' AND object_id = OBJECT_ID('dbo.WHS_Saldo'))
    CREATE INDEX IX_WHS_Saldo_Item ON dbo.WHS_Saldo (ItemCode, ContainerNo) INCLUDE (Kg, Sak, Palet);
GO

/* 3. Posting satu dokumen ke saldo (dipanggil API saat Admin posting di CMS, dalam transaksi yang sama) */
CREATE OR ALTER PROCEDURE dbo.usp_WHS_SaldoPosting @ObjType NVARCHAR(20), @DocEntry BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dbo.WHS_Saldo WITH (HOLDLOCK) AS s
    USING (
        SELECT h.WhsCode, ISNULL(d.KodeRuangan, '') AS KodeRuangan, d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '') AS ContainerNo,
               SUM(d.qty * d.flags) AS Kg, SUM(ISNULL(d.Qty2, 0) * d.flags) AS Sak, SUM(ISNULL(d.QtyPalet, 0) * d.flags) AS Palet,
               MAX(CASE WHEN d.flags = 1 THEN d.brand_name END) AS Brand,
               MIN(CASE WHEN d.flags = 1 THEN CAST(h.DocDate AS DATE) END) AS TglMasuk
        FROM dbo.OKRN h JOIN dbo.KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
        WHERE h.ObjType = @ObjType AND h.DocEntry = @DocEntry
        GROUP BY h.WhsCode, ISNULL(d.KodeRuangan, ''), d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '')
    ) AS m
    ON s.WhsCode = m.WhsCode AND s.KodeRuangan = m.KodeRuangan AND s.ItemCode = m.ItemCode AND s.ContainerNo = m.ContainerNo
    WHEN MATCHED THEN UPDATE SET Kg = s.Kg + m.Kg, Sak = s.Sak + m.Sak, Palet = s.Palet + m.Palet,
        Brand = COALESCE(m.Brand, s.Brand),
        TglMasuk = CASE WHEN s.TglMasuk IS NULL OR m.TglMasuk < s.TglMasuk THEN COALESCE(m.TglMasuk, s.TglMasuk) ELSE s.TglMasuk END,
        UpdatedAt = SYSDATETIME()
    WHEN NOT MATCHED THEN INSERT (WhsCode, KodeRuangan, ItemCode, ContainerNo, Kg, Sak, Palet, Brand, TglMasuk)
        VALUES (m.WhsCode, m.KodeRuangan, m.ItemCode, m.ContainerNo, m.Kg, m.Sak, m.Palet, m.Brand, m.TglMasuk);
    -- baris yang habis tidak perlu disimpan
    DELETE s FROM dbo.WHS_Saldo s
    WHERE s.Kg = 0 AND s.Sak = 0 AND s.Palet = 0
      AND EXISTS (SELECT 1 FROM dbo.OKRN h JOIN dbo.KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
                  WHERE h.ObjType = @ObjType AND h.DocEntry = @DocEntry AND h.WhsCode = s.WhsCode AND d.ItemCode = s.ItemCode);
END
GO

/* 4. Bangun ulang saldo dari semua dokumen yang sudah diposting (isi awal / koreksi bila ada selisih) */
CREATE OR ALTER PROCEDURE dbo.usp_WHS_SaldoRebuild
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRAN;
    DELETE dbo.WHS_Saldo WITH (TABLOCKX);
    INSERT dbo.WHS_Saldo (WhsCode, KodeRuangan, ItemCode, ContainerNo, Kg, Sak, Palet, Brand, TglMasuk)
    SELECT h.WhsCode, ISNULL(d.KodeRuangan, ''), d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), ''),
           SUM(d.qty * d.flags), SUM(ISNULL(d.Qty2, 0) * d.flags), SUM(ISNULL(d.QtyPalet, 0) * d.flags),
           MAX(CASE WHEN d.flags = 1 THEN d.brand_name END), MIN(CASE WHEN d.flags = 1 THEN CAST(h.DocDate AS DATE) END)
    FROM dbo.OKRN h JOIN dbo.KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
    WHERE h.DocStatus = 'C'
    GROUP BY h.WhsCode, ISNULL(d.KodeRuangan, ''), d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '')
    HAVING SUM(d.qty * d.flags) <> 0 OR SUM(ISNULL(d.Qty2, 0) * d.flags) <> 0 OR SUM(ISNULL(d.QtyPalet, 0) * d.flags) <> 0;
    COMMIT;
END
GO

/* 5. Cek: saldo vs jumlah transaksi (harus kosong) */
CREATE OR ALTER VIEW dbo.vw_WHS_SaldoSelisih AS
SELECT COALESCE(s.WhsCode, t.WhsCode) AS WhsCode, COALESCE(s.KodeRuangan, t.KodeRuangan) AS KodeRuangan,
       COALESCE(s.ItemCode, t.ItemCode) AS ItemCode, COALESCE(s.ContainerNo, t.ContainerNo) AS ContainerNo,
       ISNULL(s.Kg, 0) AS SaldoKg, ISNULL(t.Kg, 0) AS TransaksiKg
FROM dbo.WHS_Saldo s
FULL JOIN (
    SELECT h.WhsCode, ISNULL(d.KodeRuangan, '') AS KodeRuangan, d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '') AS ContainerNo, SUM(d.qty * d.flags) AS Kg
    FROM dbo.OKRN h JOIN dbo.KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
    WHERE h.DocStatus = 'C'
    GROUP BY h.WhsCode, ISNULL(d.KodeRuangan, ''), d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '')
) t ON t.WhsCode = s.WhsCode AND t.KodeRuangan = s.KodeRuangan AND t.ItemCode = s.ItemCode AND t.ContainerNo = s.ContainerNo
WHERE ABS(ISNULL(s.Kg, 0) - ISNULL(t.Kg, 0)) > 0.001;
GO

-- Hak akses aplikasi
-- GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.WHS_Saldo TO gudang_app;
-- GRANT EXECUTE ON dbo.usp_WHS_SaldoPosting TO gudang_app; GRANT EXECUTE ON dbo.usp_WHS_SaldoRebuild TO gudang_app;
-- GRANT SELECT ON dbo.vw_WHS_SaldoSelisih TO gudang_app;
