/* Gudang ATM - tambahan v2 (jalankan SETELAH gudang_atm_v2_struktur.sql dan gateway.sql). Aman dijalankan ulang. */
USE WORKSHOP_STAGING;
GO

/* Kode persetujuan Admin (6 digit, berlaku 15 menit, sekali pakai): untuk berat manual, selisih net > batas, dll. */
IF OBJECT_ID('dbo.WHS_KodeAdmin') IS NULL
CREATE TABLE dbo.WHS_KodeAdmin (
    Id         BIGINT IDENTITY(1,1) PRIMARY KEY,
    KodeHash   CHAR(64) NOT NULL,                  -- SHA-256 dari kode 6 digit (kode asli tidak disimpan)
    WhsCode    NVARCHAR(8) NOT NULL,
    Tujuan     NVARCHAR(40) NULL,                  -- mis. 'TIMBANG_MANUAL', 'SELISIH_NET'
    CreatedBy  INT NOT NULL, CreatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    ExpiresAt  DATETIME2(0) NOT NULL,
    UsedBy     INT NULL, UsedAt DATETIME2(0) NULL
);
CREATE INDEX IX_WHS_KodeAdmin ON dbo.WHS_KodeAdmin (WhsCode, KodeHash) WHERE UsedAt IS NULL;
GO

/* Sumber timbangan: tambah BLE (dibaca aplikasi lewat Bluetooth) di samping LAN/GATEWAY dan MANUAL */
DECLARE @sql NVARCHAR(MAX);
SELECT @sql = 'ALTER TABLE dbo.WHS_Timbang DROP CONSTRAINT ' + QUOTENAME(cc.name)
FROM sys.check_constraints cc WHERE cc.parent_object_id = OBJECT_ID('dbo.WHS_Timbang') AND cc.definition LIKE '%Sumber%';
IF @sql IS NOT NULL EXEC (@sql);
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_WHS_Timbang_Sumber2')
    ALTER TABLE dbo.WHS_Timbang ADD CONSTRAINT CK_WHS_Timbang_Sumber2 CHECK (Sumber IN ('LAN','GATEWAY','BLE','MANUAL'));
IF COL_LENGTH('dbo.WHS_Timbang','TeksMentah') IS NULL ALTER TABLE dbo.WHS_Timbang ADD TeksMentah NVARCHAR(200) NULL;   -- baris mentah dari indikator (audit)
IF COL_LENGTH('dbo.WHS_Timbang','Peringatan') IS NULL ALTER TABLE dbo.WHS_Timbang ADD Peringatan NVARCHAR(300) NULL;
GO
/* Riwayat: perluas nilai Sumber yang sama */
DECLARE @s1 NVARCHAR(MAX), @s2 NVARCHAR(MAX);
SELECT @s1 = 'ALTER TABLE dbo.WHS_RiwayatBeratMobil DROP CONSTRAINT ' + QUOTENAME(cc.name) FROM sys.check_constraints cc WHERE cc.parent_object_id = OBJECT_ID('dbo.WHS_RiwayatBeratMobil') AND cc.definition LIKE '%Sumber%';
IF @s1 IS NOT NULL EXEC (@s1);
SELECT @s2 = 'ALTER TABLE dbo.WHS_RiwayatBeratKontainer DROP CONSTRAINT ' + QUOTENAME(cc.name) FROM sys.check_constraints cc WHERE cc.parent_object_id = OBJECT_ID('dbo.WHS_RiwayatBeratKontainer') AND cc.definition LIKE '%Sumber%';
IF @s2 IS NOT NULL EXEC (@s2);
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_WHS_RiwMobil_Sumber2')
    ALTER TABLE dbo.WHS_RiwayatBeratMobil ADD CONSTRAINT CK_WHS_RiwMobil_Sumber2 CHECK (Sumber IN ('LAN','GATEWAY','BLE','MANUAL'));
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_WHS_RiwKont_Sumber2')
    ALTER TABLE dbo.WHS_RiwayatBeratKontainer ADD CONSTRAINT CK_WHS_RiwKont_Sumber2 CHECK (Sumber IN ('LAN','GATEWAY','BLE','MANUAL'));
GO

/* Kendaraan: bruto/tara masuk, catatan peringatan, kebutuhan kontainer bawaan */
IF COL_LENGTH('dbo.WHS_Kendaraan','KontainerBawaan') IS NULL ALTER TABLE dbo.WHS_Kendaraan ADD KontainerBawaan BIT NOT NULL CONSTRAINT DF_WHS_Kendaraan_KB DEFAULT 0;
IF COL_LENGTH('dbo.WHS_Kendaraan','Peringatan')      IS NULL ALTER TABLE dbo.WHS_Kendaraan ADD Peringatan NVARCHAR(300) NULL;
IF COL_LENGTH('dbo.WHS_Kendaraan','CatatanKeluar')   IS NULL ALTER TABLE dbo.WHS_Kendaraan ADD CatatanKeluar NVARCHAR(300) NULL;
GO

/* Yard kontainer: area + reservasi */
IF COL_LENGTH('dbo.WHS_Kontainer','Dialokasikan') IS NULL ALTER TABLE dbo.WHS_Kontainer ADD Dialokasikan NVARCHAR(30) NULL;  -- PlanNo yang akan mengambil
GO
