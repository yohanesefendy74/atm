/* Gudang ATM - saldo stok per BL: isi No. BL untuk transaksi lama. Jalankan SETELAH saldo.sql dan isi_ruangan_stok_lama.sql.
   Akun admin. Aman diulang. Selesai -> EXEC dbo.usp_WHS_SaldoRebuild; lalu cek vw_WHS_SaldoSelisih. */
USE WORKSHOP_STAGING;
GO

-- 1) Baris masuk: BL dari header (OKRN.U_NoBL) turun ke baris
UPDATE d SET d.NoBL = h.U_NoBL
FROM dbo.KRN1 d JOIN dbo.OKRN h ON h.ObjType = d.ObjType AND h.DocEntry = d.DocEntry
WHERE d.flags = 1 AND ISNULL(d.NoBL, '') = '' AND ISNULL(h.U_NoBL, '') <> '';
PRINT CONCAT(@@ROWCOUNT, ' baris masuk diisi BL dari header');
GO

-- 2) Baris keluar lama: bila item + container (+ ruangan) hanya pernah masuk dengan SATU BL, pakai BL itu
;WITH masuk AS (
    SELECT h.WhsCode, d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '') AS Cont, ISNULL(d.KodeRuangan, '') AS Ruang,
           MIN(d.NoBL) AS Bl, COUNT(DISTINCT d.NoBL) AS JmlBl
    FROM dbo.OKRN h JOIN dbo.KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
    WHERE d.flags = 1 AND ISNULL(d.NoBL, '') <> ''
    GROUP BY h.WhsCode, d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), ''), ISNULL(d.KodeRuangan, '')
)
UPDATE d SET d.NoBL = m.Bl
FROM dbo.KRN1 d JOIN dbo.OKRN h ON h.ObjType = d.ObjType AND h.DocEntry = d.DocEntry
JOIN masuk m ON m.WhsCode = h.WhsCode AND m.ItemCode = d.ItemCode AND m.Cont = ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '') AND m.Ruang = ISNULL(d.KodeRuangan, '')
WHERE d.flags = -1 AND ISNULL(d.NoBL, '') = '' AND m.JmlBl = 1;
PRINT CONCAT(@@ROWCOUNT, ' baris keluar diisi BL (satu BL per item+container+ruangan)');
GO

-- 3) Sisa yang belum punya BL: isi manual (CMS untuk dokumen open, atau UPDATE KRN1 SET NoBL = '...' WHERE ...)
SELECT h.WhsCode, h.ObjType, h.DocEntry, h.DocDate, h.TrxCode, d.LineNum, d.ItemCode, ISNULL(COALESCE(d.ContainerNo, h.ContainerNo), '') AS ContainerNo,
       d.KodeRuangan, d.flags, d.qty
FROM dbo.OKRN h JOIN dbo.KRN1 d ON d.ObjType = h.ObjType AND d.DocEntry = h.DocEntry
WHERE h.DocStatus = 'C' AND ISNULL(d.NoBL, '') = '' AND NOT (d.flags = 1 AND ISNULL(h.U_NoBL, '') <> '')
ORDER BY h.WhsCode, d.ItemCode, h.DocDate;
GO

-- 4) Bangun ulang saldo
-- EXEC dbo.usp_WHS_SaldoRebuild;
-- SELECT * FROM dbo.vw_WHS_SaldoSelisih;
