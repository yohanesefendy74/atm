/* Gudang ATM - tambahan v2 (jalankan SETELAH gudang_atm_v2_struktur.sql dan gateway.sql). Aman dijalankan ulang. */
USE WORKSHOP_STAGING;
GO

/* Origin (asal barang) per baris krani. DistNumber = batch SAP, tidak dipakai untuk origin. */
IF COL_LENGTH('dbo.KRN1','Origin') IS NULL ALTER TABLE dbo.KRN1 ADD Origin NVARCHAR(100) NULL;
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

/* ============================================================================================
   Penimbangan per KONTAINER (bongkar). Kepala truk bisa berbeda saat masuk dan saat ditarik.
     T1 truk + kontainer isi   T2 kepala saja (kontainer dilepas di dock)   -> isi   = T1 - T2
     T3 kepala (lain) saja     T4 kepala + kontainer kosong                   -> kosong = T4 - T3
     Net barang = (T1 - T2) - (T4 - T3); dibagi ke tiap barang memakai sampling berat (prorata).
   ============================================================================================ */
DECLARE @ck NVARCHAR(MAX);
SELECT @ck = 'ALTER TABLE dbo.WHS_Kontainer DROP CONSTRAINT ' + QUOTENAME(cc.name)
FROM sys.check_constraints cc WHERE cc.parent_object_id = OBJECT_ID('dbo.WHS_Kontainer') AND cc.definition LIKE '%Di yard%';
IF @ck IS NOT NULL EXEC (@ck);
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_WHS_Kontainer_Status2')
    ALTER TABLE dbo.WHS_Kontainer ADD CONSTRAINT CK_WHS_Kontainer_Status2 CHECK (Status IN ('Di yard','Di dock','Keluar'));
IF COL_LENGTH('dbo.WHS_Kontainer','SesiId') IS NULL ALTER TABLE dbo.WHS_Kontainer ADD SesiId BIGINT NULL;
GO

IF OBJECT_ID('dbo.WHS_KontainerSesi') IS NULL
CREATE TABLE dbo.WHS_KontainerSesi (
    SesiId       BIGINT IDENTITY(1,1) PRIMARY KEY,
    WhsCode      NVARCHAR(8) NOT NULL,
    ContainerNo  NVARCHAR(11) NOT NULL,
    PlanId       BIGINT NULL REFERENCES dbo.WHS_Plan(PlanId),          -- SPBB
    Status       NVARCHAR(10) NOT NULL DEFAULT 'ISI_MASUK'
                 CHECK (Status IN ('ISI_MASUK','DI_DOCK','KOSONG','SELESAI','BATAL')),
    RegId1 BIGINT NULL, Plat1 NVARCHAR(15) NULL, T1Kg NUMERIC(12,2) NULL, T1Id BIGINT NULL, T1At DATETIME2(0) NULL,   -- truk + kontainer isi
    T2Kg NUMERIC(12,2) NULL, T2Id BIGINT NULL, T2At DATETIME2(0) NULL,                                                 -- kepala yang sama, kontainer dilepas
    RegId3 BIGINT NULL, Plat3 NVARCHAR(15) NULL, T3Kg NUMERIC(12,2) NULL, T3Id BIGINT NULL, T3At DATETIME2(0) NULL,   -- kepala penarik saja
    T4Kg NUMERIC(12,2) NULL, T4Id BIGINT NULL, T4At DATETIME2(0) NULL,                                                 -- kepala penarik + kontainer kosong
    BeratIsiKg    AS (T1Kg - T2Kg),
    BeratKosongKg AS (T4Kg - T3Kg),
    NetKg         AS ((T1Kg - T2Kg) - (T4Kg - T3Kg)),
    NetInputKrani NUMERIC(12,2) NULL, SelisihPersen NUMERIC(6,2) NULL, KodeAdminOleh INT NULL,
    Peringatan   NVARCHAR(300) NULL,
    CreatedAt    DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(), SelesaiAt DATETIME2(0) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_WHS_KontainerSesi_Aktif')
    CREATE UNIQUE INDEX UX_WHS_KontainerSesi_Aktif ON dbo.WHS_KontainerSesi (ContainerNo) WHERE Status IN ('ISI_MASUK','DI_DOCK','KOSONG');
GO

/* Sampling berat per barang di dalam kontainer (krani menimbang beberapa karung, jumlah bebas >= 1) */
IF OBJECT_ID('dbo.WHS_Sampling') IS NULL
CREATE TABLE dbo.WHS_Sampling (
    SesiId    BIGINT NOT NULL REFERENCES dbo.WHS_KontainerSesi(SesiId),
    PlanLine  INT NOT NULL,
    ItemCode  NVARCHAR(50) NOT NULL,
    SakSampel INT NOT NULL CHECK (SakSampel >= 1),
    KgSampel  NUMERIC(12,2) NOT NULL CHECK (KgSampel > 0),
    UserId    INT NOT NULL, UpdatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_WHS_Sampling PRIMARY KEY (SesiId, PlanLine)
);
GO

/* Hasil pembagian berat timbangan ke tiap barang (baris baru; input krani di KRN1 tidak diubah) */
IF OBJECT_ID('dbo.WHS_KontainerAlokasi') IS NULL
CREATE TABLE dbo.WHS_KontainerAlokasi (
    SesiId         BIGINT NOT NULL REFERENCES dbo.WHS_KontainerSesi(SesiId),
    PlanLine       INT NOT NULL,
    ItemCode       NVARCHAR(50) NOT NULL,
    SakTotal       NUMERIC(12,2) NOT NULL,      -- jumlah karung input krani
    KgKrani        NUMERIC(12,2) NOT NULL,      -- KG input krani
    SakSampel      INT NOT NULL, KgSampel NUMERIC(12,2) NOT NULL,
    EstimasiSisaKg NUMERIC(12,2) NOT NULL,      -- (SakTotal - SakSampel) x rata-rata kg/karung sampel
    AlokasiSisaKg  NUMERIC(12,2) NOT NULL,      -- (Net - total sampel) x estimasi / total estimasi
    KgTimbang      NUMERIC(12,2) NOT NULL,      -- KgSampel + AlokasiSisaKg
    CONSTRAINT PK_WHS_KontainerAlokasi PRIMARY KEY (SesiId, PlanLine)
);
GO

IF COL_LENGTH('dbo.OKRN','SesiId') IS NULL ALTER TABLE dbo.OKRN ADD SesiId BIGINT NULL;   -- input krani untuk kontainer ini
GO
