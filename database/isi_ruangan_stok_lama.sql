/* Gudang ATM - semua stok & transaksi WAJIB punya ruangan.
   1) Lihat baris lama yang belum punya ruangan.
   2) Isi ruangan default per gudang (ubah pemetaan di @Peta), jalankan sekali.
   3) Kunci: baris KRN1 baru wajib KodeRuangan (constraint WITH NOCHECK, data lama yang belum terisi tidak divalidasi).
   Jalankan dengan akun admin (bukan gudang_app). Aman diulang. */
USE WORKSHOP_STAGING;
GO

-- 1) Ringkasan baris tanpa ruangan per gudang
SELECT h.WhsCode, COUNT(*) AS baris, SUM(d.qty * d.flags) AS saldoKg
FROM OKRN h JOIN KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
WHERE d.KodeRuangan IS NULL
GROUP BY h.WhsCode ORDER BY h.WhsCode;
GO

-- 2) Pemetaan gudang -> ruangan default untuk data lama. ISI DULU sesuai kondisi fisik, lalu jalankan blok ini.
DECLARE @Peta TABLE (WhsCode NVARCHAR(8) PRIMARY KEY, KodeRuangan NVARCHAR(30) NOT NULL);
-- INSERT @Peta VALUES ('ATM', 'RG-A1'), ('ATM-T', 'RG-T1');

IF EXISTS (SELECT 1 FROM @Peta p LEFT JOIN dbo.WHS_MasterRuangan r ON r.KodeRuangan = p.KodeRuangan AND r.WhsCode = p.WhsCode WHERE r.KodeRuangan IS NULL)
    RAISERROR('Ada ruangan di @Peta yang tidak ada di Master Ruangan gudang tsb.', 16, 1);
ELSE
BEGIN
    UPDATE d SET d.KodeRuangan = p.KodeRuangan
    FROM dbo.KRN1 d JOIN dbo.OKRN h ON h.ObjType = d.ObjType AND h.DocEntry = d.DocEntry
    JOIN @Peta p ON p.WhsCode = h.WhsCode
    WHERE d.KodeRuangan IS NULL;
    PRINT CONCAT(@@ROWCOUNT, ' baris diisi ruangan default');
END
GO

-- 3) Kunci: transaksi baru wajib ruangan
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_KRN1_KodeRuangan')
    ALTER TABLE dbo.KRN1 WITH NOCHECK ADD CONSTRAINT CK_KRN1_KodeRuangan CHECK (KodeRuangan IS NOT NULL);
GO
