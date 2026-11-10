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

/* Muat: palet ikut tertimbang di truk. Setelah selesai muat krani menimbang SEMUA palet; total ini dikurangkan dari net muatan. */
IF COL_LENGTH('dbo.WHS_Kendaraan','JumlahPalet')   IS NULL ALTER TABLE dbo.WHS_Kendaraan ADD JumlahPalet INT NULL;
IF COL_LENGTH('dbo.WHS_Kendaraan','BeratPaletKg')  IS NULL ALTER TABLE dbo.WHS_Kendaraan ADD BeratPaletKg NUMERIC(12,2) NULL;
IF COL_LENGTH('dbo.WHS_Kendaraan','PaletTimbangId') IS NULL ALTER TABLE dbo.WHS_Kendaraan ADD PaletTimbangId BIGINT NULL;
GO

/* Sampling per KARUNG (gudang dengan timbangan mobil / bongkar kontainer).
   Krani menimbang 1 karung per kali, boleh berkali-kali per barang. Sampel hanya untuk rata-rata kg/karung,
   TIDAK ikut dihitung: berat per barang = net kontainer x (karung x rata2) / total (karung x rata2). */
IF OBJECT_ID('dbo.WHS_SamplingSak') IS NULL
CREATE TABLE dbo.WHS_SamplingSak (
    SampId    BIGINT IDENTITY(1,1) PRIMARY KEY,
    SesiId    BIGINT NOT NULL REFERENCES dbo.WHS_KontainerSesi(SesiId),
    PlanLine  INT NOT NULL,
    ItemCode  NVARCHAR(50) NOT NULL,
    KgSak     NUMERIC(10,2) NOT NULL CHECK (KgSak > 0 AND KgSak <= 200),
    Sumber    NVARCHAR(8) NULL,             -- BLE / GATEWAY / MANUAL
    UserId    INT NOT NULL, CreatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WHS_SamplingSak' AND object_id = OBJECT_ID('dbo.WHS_SamplingSak'))
    CREATE INDEX IX_WHS_SamplingSak ON dbo.WHS_SamplingSak (SesiId, PlanLine);
GO
-- GRANT SELECT, INSERT, DELETE ON dbo.WHS_SamplingSak TO gudang_app;

/* SPMB: PT tidak diisi Admin; krani memilih PT per baris (boleh campur) -> PT disimpan di detail */
IF COL_LENGTH('dbo.KRN1','U_IDU_Kode_PT') IS NULL ALTER TABLE dbo.KRN1 ADD U_IDU_Kode_PT NVARCHAR(30) NULL;
GO

/* No. BL per baris SPBB: sumber info BL stok (non-titipan). Sumber BL = NumAtCard dokumen BL; sumber DO = diisi Admin. */
IF COL_LENGTH('dbo.WHS_Plan1','NoBL') IS NULL ALTER TABLE dbo.WHS_Plan1 ADD NoBL NVARCHAR(50) NULL;
GO

/* Surat Jalan = dasar DO: baris per item + BL (+ PT) dari transaksi keluar SPMB, supaya retur bisa menelusuri BL */
IF COL_LENGTH('dbo.WHS_SuratJalan1','PlanLine') IS NULL ALTER TABLE dbo.WHS_SuratJalan1 ADD PlanLine INT NULL;
IF COL_LENGTH('dbo.WHS_SuratJalan1','NoBL')     IS NULL ALTER TABLE dbo.WHS_SuratJalan1 ADD NoBL NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.WHS_SuratJalan1','PtCode')   IS NULL ALTER TABLE dbo.WHS_SuratJalan1 ADD PtCode NVARCHAR(30) NULL;
GO

/* Catatan krani bila no. mobil di lapangan berbeda; Admin bisa mengoreksi OKRN.VehicleNo di CMS */
IF COL_LENGTH('dbo.OKRN','NoMobilKrani') IS NULL ALTER TABLE dbo.OKRN ADD NoMobilKrani NVARCHAR(20) NULL;   -- no. mobil menurut krani
IF COL_LENGTH('dbo.OKRN','CatatanKrani') IS NULL ALTER TABLE dbo.OKRN ADD CatatanKrani NVARCHAR(300) NULL;
GO

/* Repacking: SUMBER (keluar), HASIL (masuk), SCRAP (masuk, kode item khusus yang didefinisikan user, tidak harus ada di OITM) */
IF OBJECT_ID('dbo.WHS_ItemScrap') IS NULL
CREATE TABLE dbo.WHS_ItemScrap (
    ItemCode  NVARCHAR(50)  NOT NULL PRIMARY KEY,
    ItemName  NVARCHAR(200) NOT NULL,
    Aktif     BIT NOT NULL DEFAULT 1,
    CreatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO
-- GRANT SELECT, INSERT, UPDATE ON dbo.WHS_ItemScrap TO gudang_app;

/* ===================================================================================================
   Titipan = sifat BARANG, bukan ruangan.
   - Ruangan titipan (WHS_MasterRuangan.Titipan = 1) boleh berisi barang titipan DAN non-titipan.
     Ruangan non-titipan hanya untuk barang non-titipan.
   - Per baris transaksi: KRN1.Titipan; per rencana: WHS_Plan.Titipan; saldo per ruangan dipisah titipan / non-titipan.
   - Satu dokumen / satu rencana / satu Surat Jalan tetap tidak boleh mencampur titipan dan non-titipan.
   Setelah script ini: jalankan ulang saldo.sql lalu EXEC dbo.usp_WHS_SaldoRebuild.
   =================================================================================================== */
IF COL_LENGTH('dbo.KRN1','Titipan') IS NULL ALTER TABLE dbo.KRN1 ADD Titipan BIT NULL;
IF COL_LENGTH('dbo.WHS_Plan','Titipan') IS NULL ALTER TABLE dbo.WHS_Plan ADD Titipan BIT NULL;
GO
-- Data lama: dulu titipan ditentukan ruangan / warehouse / TrxCode BT
UPDATE p SET Titipan = ISNULL(r.Titipan, 0)
FROM dbo.WHS_Plan p LEFT JOIN dbo.WHS_MasterRuangan r ON r.KodeRuangan = p.KodeRuangan
WHERE p.Titipan IS NULL;
UPDATE d SET Titipan = CASE WHEN h.TrxCode = 'BT' OR ISNULL(r.Titipan, 0) = 1 OR w.[External] = 'Y' THEN 1 ELSE 0 END
FROM dbo.KRN1 d
JOIN dbo.OKRN h ON h.ObjType = d.ObjType AND h.DocEntry = d.DocEntry
LEFT JOIN dbo.WHS_MasterRuangan r ON r.KodeRuangan = d.KodeRuangan
LEFT JOIN dbo.OWHS w ON w.WhsCode = h.WhsCode
WHERE d.Titipan IS NULL;
GO
CREATE OR ALTER TRIGGER dbo.TR_WHS_Plan_Titipan ON dbo.WHS_Plan AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted i WHERE ISNULL(i.Titipan, 0) = 1 AND i.Status <> 'Batal' AND NULLIF(LTRIM(RTRIM(i.CardCodeTitipan)), '') IS NULL)
    BEGIN
        RAISERROR('Barang titipan: kode customer titipan wajib diisi pada SPBB/SPMB.', 16, 1);
        ROLLBACK TRANSACTION; RETURN;
    END
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.WHS_MasterRuangan r ON r.KodeRuangan = i.KodeRuangan WHERE ISNULL(i.Titipan, 0) = 1 AND r.Titipan = 0)
    BEGIN
        RAISERROR('Barang titipan hanya boleh di ruangan titipan.', 16, 1);
        ROLLBACK TRANSACTION; RETURN;
    END
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.WHS_MasterRuangan r ON r.KodeRuangan = i.KodeRuangan WHERE r.WhsCode <> i.WhsCode)
    BEGIN
        RAISERROR('Ruangan bukan milik warehouse dokumen ini.', 16, 1);
        ROLLBACK TRANSACTION;
    END
END
GO
/* Baris: barang titipan wajib di ruangan titipan; baris rencana harus sama sifatnya dengan rencana */
CREATE OR ALTER TRIGGER dbo.TR_KRN1_TitipanCampur ON dbo.KRN1 AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.WHS_MasterRuangan ri ON ri.KodeRuangan = i.KodeRuangan
               WHERE ISNULL(i.Titipan, 0) = 1 AND ri.Titipan = 0)
    BEGIN
        RAISERROR('Barang titipan hanya boleh di ruangan titipan.', 16, 1);
        ROLLBACK TRANSACTION; RETURN;
    END
    IF EXISTS (SELECT 1 FROM inserted i
               JOIN dbo.OKRN h ON h.ObjType = i.ObjType AND h.DocEntry = i.DocEntry
               JOIN dbo.WHS_Plan p ON p.PlanId = h.PlanId
               WHERE p.Titipan IS NOT NULL AND i.Titipan IS NOT NULL AND p.Titipan <> i.Titipan)
    BEGIN
        RAISERROR('Titipan dan non-titipan tidak boleh dicampur: baris tidak sesuai rencana.', 16, 1);
        ROLLBACK TRANSACTION;
    END
END
GO
CREATE OR ALTER TRIGGER dbo.TR_KRN1_TitipanSatuDokumen ON dbo.KRN1 AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT DISTINCT ObjType, DocEntry FROM inserted) d
               JOIN dbo.KRN1 k ON k.ObjType = d.ObjType AND k.DocEntry = d.DocEntry
               GROUP BY d.ObjType, d.DocEntry
               HAVING COUNT(DISTINCT ISNULL(k.Titipan, 0)) > 1)
    BEGIN
        RAISERROR('Titipan dan non-titipan tidak boleh dicampur dalam satu dokumen.', 16, 1);
        ROLLBACK TRANSACTION;
    END
END
GO
CREATE OR ALTER TRIGGER dbo.TR_WHS_SuratJalanPlan_TitipanCampur ON dbo.WHS_SuratJalanPlan AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM dbo.WHS_SuratJalanPlan a
               JOIN dbo.WHS_Plan pa ON pa.PlanId = a.PlanId
               JOIN dbo.WHS_SuratJalanPlan b ON b.SjId = a.SjId AND b.PlanId <> a.PlanId
               JOIN dbo.WHS_Plan pb ON pb.PlanId = b.PlanId
               WHERE ISNULL(pa.Titipan, 0) <> ISNULL(pb.Titipan, 0)
                 AND a.SjId IN (SELECT SjId FROM inserted))
    BEGIN
        RAISERROR('Titipan dan non-titipan tidak boleh dicampur dalam satu Surat Jalan.', 16, 1);
        ROLLBACK TRANSACTION;
    END
END
GO
