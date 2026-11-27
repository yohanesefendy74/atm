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

/* Lot QR untuk SPBB: label disiapkan Admin SEBELUM barang datang, jadi lot = nomor SPBB tanpa baris
   (contoh SPBB/2611/0012 -> lot 26110012; item & container sudah ada di QR). Barang yang diterima krani dari SPBB memakai lot ini.
   Transaksi krani tanpa rencana (inbound bebas, hasil KR/RP) memakai lot = ObjType + DocEntry. */
IF COL_LENGTH('dbo.WHS_Plan1','NoLot') IS NULL ALTER TABLE dbo.WHS_Plan1 ADD NoLot NVARCHAR(20) NULL;
GO
-- baris transaksi krani yang sempat memakai format lama (nomor SPBB + 3 digit baris) disamakan
UPDATE d SET NoLot = REPLACE(SUBSTRING(p.PlanNo, 6, 20), '/', '')
FROM dbo.KRN1 d
JOIN dbo.OKRN h ON h.ObjType = d.ObjType AND h.DocEntry = d.DocEntry
JOIN dbo.WHS_Plan p ON p.PlanId = h.PlanId AND p.Jenis = 'SPBB'
WHERE d.NoLot = REPLACE(SUBSTRING(p.PlanNo, 6, 20), '/', '') + RIGHT('000' + CAST(d.PlanLine AS VARCHAR(10)), 3);
UPDATE l SET NoLot = REPLACE(SUBSTRING(p.PlanNo, 6, 20), '/', '')
FROM dbo.WHS_Plan1 l JOIN dbo.WHS_Plan p ON p.PlanId = l.PlanId
WHERE p.Jenis = 'SPBB' AND ISNULL(l.NoLot, '') <> REPLACE(SUBSTRING(p.PlanNo, 6, 20), '/', '');
GO

/* Muat langsung (cross-dock) di gudang timbangan mobil: sebagian barang SPBB dari kontainer yang sedang dibongkar
   langsung dimuat ke truk SPMB (tidak masuk ruangan). Dicatat berpasangan: baris masuk SPBB + baris keluar SPMB.
   Berat final = net timbang keluar truk SPMB (truk hanya membawa barang SPBB tsb).
   Sisa SPBB saat kontainer ditimbang kosong = net kontainer - berat muat langsung. */
IF COL_LENGTH('dbo.KRN1','CrossDockSesiId') IS NULL ALTER TABLE dbo.KRN1 ADD CrossDockSesiId BIGINT NULL;   -- kontainer SPBB asal
IF COL_LENGTH('dbo.KRN1','CrossDockRegId') IS NULL ALTER TABLE dbo.KRN1 ADD CrossDockRegId BIGINT NULL;     -- truk SPMB
IF COL_LENGTH('dbo.KRN1','CrossDockKey') IS NULL ALTER TABLE dbo.KRN1 ADD CrossDockKey NVARCHAR(40) NULL;   -- pasangan baris masuk & keluar
IF COL_LENGTH('dbo.KRN1','CrossDockFinal') IS NULL ALTER TABLE dbo.KRN1 ADD CrossDockFinal BIT NULL;        -- 1 = kg sudah dari timbang keluar
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_KRN1_CrossDock' AND object_id = OBJECT_ID('dbo.KRN1'))
    CREATE INDEX IX_KRN1_CrossDock ON dbo.KRN1 (CrossDockRegId, CrossDockSesiId) INCLUDE (CrossDockKey, flags, qty) WHERE CrossDockKey IS NOT NULL;
GO

/* SPBB barang titipan tanpa dokumen ERP (tidak ada BL/DO): sumber 'TT', item diisi Admin */
DECLARE @ck SYSNAME = (SELECT TOP 1 cc.name FROM sys.check_constraints cc
                       JOIN sys.columns c ON c.object_id = cc.parent_object_id AND c.column_id = cc.parent_column_id
                       WHERE cc.parent_object_id = OBJECT_ID('dbo.WHS_Plan') AND c.name = 'BaseType');
IF @ck IS NOT NULL AND (SELECT definition FROM sys.check_constraints WHERE name = @ck) NOT LIKE '%TT%'
BEGIN
    EXEC('ALTER TABLE dbo.WHS_Plan DROP CONSTRAINT ' + @ck);
    ALTER TABLE dbo.WHS_Plan ADD CONSTRAINT CK_WHS_Plan_BaseType CHECK (BaseType IN ('BL','DO','SO','TT'));
END
GO

/* Gudang timbangan mobil: truk memuat beberapa SPMB harus kembali ke timbangan setiap selesai memuat 1 SPMB.
   Net SPMB = berat setelah memuat SPMB ini - berat timbang sebelumnya - berat palet SPMB ini. */
IF OBJECT_ID('dbo.WHS_KendaraanMuat') IS NULL
CREATE TABLE dbo.WHS_KendaraanMuat (
    RegId        BIGINT NOT NULL,
    Urut         INT NOT NULL,
    PlanId       BIGINT NOT NULL,
    JumlahPalet  INT NULL,
    BeratPaletKg NUMERIC(12,2) NULL,
    BeratAwalKg  NUMERIC(12,2) NOT NULL,     -- timbang sebelum memuat SPMB ini
    BeratAkhirKg NUMERIC(12,2) NOT NULL,     -- timbang setelah memuat SPMB ini
    NetKg        NUMERIC(12,2) NOT NULL,
    InputKraniKg NUMERIC(12,2) NULL,
    SelisihPersen NUMERIC(6,2) NULL,
    TimbangId    BIGINT NULL,
    UserId       INT NULL,
    CreatedAt    DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_WHS_KendaraanMuat PRIMARY KEY (RegId, Urut)
);
GO
-- WHS_Timbang.Jenis: tambah 'ANTARA' (timbang antara SPMB pada truk multi SPMB)
DECLARE @ckT SYSNAME = (SELECT TOP 1 cc.name FROM sys.check_constraints cc
                        JOIN sys.columns c ON c.object_id = cc.parent_object_id AND c.column_id = cc.parent_column_id
                        WHERE cc.parent_object_id = OBJECT_ID('dbo.WHS_Timbang') AND c.name = 'Jenis');
IF @ckT IS NOT NULL AND (SELECT definition FROM sys.check_constraints WHERE name = @ckT) NOT LIKE '%ANTARA%'
BEGIN
    EXEC('ALTER TABLE dbo.WHS_Timbang DROP CONSTRAINT ' + @ckT);
    ALTER TABLE dbo.WHS_Timbang ADD CONSTRAINT CK_WHS_Timbang_Jenis CHECK (Jenis IN ('BRUTO','TARA','ANTARA'));
END
GO

/* Perbaikan: SPBB titipan tanpa dokumen ERP (sumber 'TT') juga harus lolos constraint tabel CK_WHS_Plan_Jenis */
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_WHS_Plan_Jenis' AND definition NOT LIKE '%TT%')
BEGIN
    ALTER TABLE dbo.WHS_Plan DROP CONSTRAINT CK_WHS_Plan_Jenis;
    ALTER TABLE dbo.WHS_Plan ADD CONSTRAINT CK_WHS_Plan_Jenis CHECK ((Jenis = 'SPBB' AND BaseType IN ('BL','DO','TT')) OR (Jenis = 'SPMB' AND BaseType = 'SO'));
END
GO

/* ===================================================================================================
   STOCK OPNAME
   - Admin memilih gudang, tanggal, ruangan; tiap ruangan dibagi per rak, tiap rak dihitung krani ke-1 dan ke-2 (berbeda).
   - Freeze = snapshot saldo dari dokumen terposting bertanggal < tanggal opname (per ruangan, item, container, BL, titipan, PT, lot).
     Freeze ulang boleh sebelum posting (hitungan krani tetap).
   - Transaksi bertanggal >= tanggal opname di ruangan yang di-opname ditahan sampai opname diposting / dibatalkan.
   - Hitungan semua rak dijumlah per kunci saldo; Admin memilih nilai final (H1 / H2 / saldo) atau minta hitung ulang rak.
   - Posting: dokumen OP (ObjType 6720, TrxCode 'OP') berisi selisih final - saldo freeze, lalu saldo diperbarui.
   Saldo TIDAK dicatat per rak; rak hanya pembagian kerja opname. Barcode rak = 'RAK-' + KodeRuangan + '-' + KodeRak.
   Ruangan tanpa master rak dihitung sebagai satu rak 'ALL'.
   =================================================================================================== */
IF OBJECT_ID('dbo.WHS_MasterRak') IS NULL
CREATE TABLE dbo.WHS_MasterRak (
    KodeRuangan NVARCHAR(30) NOT NULL,
    KodeRak     NVARCHAR(30) NOT NULL,
    NamaRak     NVARCHAR(100) NULL,
    Aktif       BIT NOT NULL DEFAULT 1,
    CreatedAt   DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_WHS_MasterRak PRIMARY KEY (KodeRuangan, KodeRak)
);
GO
IF OBJECT_ID('dbo.WHS_Opname') IS NULL
CREATE TABLE dbo.WHS_Opname (
    OpnameId    BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    OpnameNo    NVARCHAR(20) NOT NULL UNIQUE,
    WhsCode     NVARCHAR(8) NOT NULL,
    BplId       INT NOT NULL,
    TglOpname   DATE NOT NULL,
    Status      NVARCHAR(10) NOT NULL DEFAULT 'Hitung' CHECK (Status IN ('Hitung','Posted','Batal')),
    FreezeKe    INT NOT NULL DEFAULT 0,
    FreezeAt    DATETIME2(0) NULL,
    FreezeBy    INT NULL,
    PostObjType NVARCHAR(20) NULL,
    PostDocEntry BIGINT NULL,
    PostedAt    DATETIME2(0) NULL,
    CreatedBy   INT NOT NULL,
    CreatedAt   DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    Catatan     NVARCHAR(250) NULL
);
GO
IF OBJECT_ID('dbo.WHS_OpnameRak') IS NULL
CREATE TABLE dbo.WHS_OpnameRak (
    OpnameId    BIGINT NOT NULL,
    KodeRuangan NVARCHAR(30) NOT NULL,
    KodeRak     NVARCHAR(30) NOT NULL,
    Krani1      INT NOT NULL,
    Krani2      INT NOT NULL,
    Selesai1    BIT NOT NULL DEFAULT 0,
    Selesai2    BIT NOT NULL DEFAULT 0,
    CONSTRAINT PK_WHS_OpnameRak PRIMARY KEY (OpnameId, KodeRuangan, KodeRak),
    CONSTRAINT CK_WHS_OpnameRak_Krani CHECK (Krani1 <> Krani2)
);
GO
IF OBJECT_ID('dbo.WHS_OpnameSaldo') IS NULL
CREATE TABLE dbo.WHS_OpnameSaldo (
    OpnameId    BIGINT NOT NULL,
    KodeRuangan NVARCHAR(30) NOT NULL,
    ItemCode    NVARCHAR(50) NOT NULL,
    ContainerNo NVARCHAR(20) NOT NULL,
    NoBL        NVARCHAR(50) NOT NULL,
    Titipan     BIT NOT NULL,
    PtCode      NVARCHAR(30) NOT NULL,
    NoLot       NVARCHAR(20) NOT NULL,
    Kg          NUMERIC(19,6) NOT NULL,
    Sak         NUMERIC(19,6) NOT NULL,
    Palet       NUMERIC(19,6) NOT NULL,
    CONSTRAINT PK_WHS_OpnameSaldo PRIMARY KEY (OpnameId, KodeRuangan, ItemCode, ContainerNo, NoBL, Titipan, PtCode, NoLot)
);
GO
IF OBJECT_ID('dbo.WHS_OpnameHitung') IS NULL
CREATE TABLE dbo.WHS_OpnameHitung (
    HitungId    BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    OpnameId    BIGINT NOT NULL,
    KodeRuangan NVARCHAR(30) NOT NULL,
    KodeRak     NVARCHAR(30) NOT NULL,
    Ke          TINYINT NOT NULL CHECK (Ke IN (1,2)),
    UserId      INT NOT NULL,
    Qr          NVARCHAR(120) NOT NULL,
    ItemCode    NVARCHAR(50) NOT NULL,
    ContainerNo NVARCHAR(20) NOT NULL,
    NoBL        NVARCHAR(50) NOT NULL,
    Titipan     BIT NOT NULL,
    PtCode      NVARCHAR(30) NOT NULL,
    NoLot       NVARCHAR(20) NOT NULL,
    Kg          NUMERIC(19,6) NOT NULL,
    Sak         NUMERIC(19,6) NOT NULL,
    Palet       NUMERIC(19,6) NOT NULL,
    CreatedAt   DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WHS_OpnameHitung_Rak' AND object_id = OBJECT_ID('dbo.WHS_OpnameHitung'))
    CREATE INDEX IX_WHS_OpnameHitung_Rak ON dbo.WHS_OpnameHitung (OpnameId, KodeRuangan, KodeRak, Ke);
GO
IF OBJECT_ID('dbo.WHS_OpnameFinal') IS NULL
CREATE TABLE dbo.WHS_OpnameFinal (
    OpnameId    BIGINT NOT NULL,
    Kunci       NVARCHAR(260) NOT NULL,    -- ruangan|item|container|BL|titipan|PT|lot
    Pilihan     NVARCHAR(6) NOT NULL CHECK (Pilihan IN ('h1','h2','saldo')),
    UserId      INT NOT NULL,
    UpdatedAt   DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_WHS_OpnameFinal PRIMARY KEY (OpnameId, Kunci)
);
GO
/* Tahan transaksi: selama opname aktif (Status 'Hitung'), dokumen bertanggal >= tanggal opname di ruangan yang di-opname
   tidak boleh dibuat (baris KRN1 baru) dan tidak boleh diposting. Dokumen bertanggal sebelumnya tetap boleh (lalu freeze ulang).
   Dokumen hasil opname sendiri (TrxCode 'OP') dikecualikan. */
CREATE OR ALTER TRIGGER dbo.TR_KRN1_OpnameTahan ON dbo.KRN1 AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID('dbo.WHS_Opname') IS NULL RETURN;
    DECLARE @no NVARCHAR(20), @tgl DATE;
    SELECT TOP 1 @no = o.OpnameNo, @tgl = o.TglOpname
    FROM inserted i
    JOIN dbo.OKRN h ON h.ObjType = i.ObjType AND h.DocEntry = i.DocEntry
    JOIN dbo.WHS_Opname o ON o.WhsCode = h.WhsCode AND o.Status = 'Hitung' AND CAST(h.DocDate AS DATE) >= o.TglOpname
    WHERE ISNULL(h.TrxCode, '') <> 'OP'
      AND EXISTS (SELECT 1 FROM dbo.WHS_OpnameRak r WHERE r.OpnameId = o.OpnameId AND r.KodeRuangan = i.KodeRuangan);
    IF @no IS NOT NULL
    BEGIN
        DECLARE @m NVARCHAR(300) = CONCAT('Ruangan sedang stock opname ', @no, ': transaksi bertanggal ', CONVERT(char(10), @tgl, 103), ' atau sesudahnya ditahan sampai opname diposting / dibatalkan.');
        RAISERROR(@m, 16, 1);
        ROLLBACK TRANSACTION;
    END
END
GO
CREATE OR ALTER TRIGGER dbo.TR_OKRN_OpnameTahan ON dbo.OKRN AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID('dbo.WHS_Opname') IS NULL OR NOT UPDATE(DocStatus) RETURN;
    DECLARE @no NVARCHAR(20), @tgl DATE;
    SELECT TOP 1 @no = o.OpnameNo, @tgl = o.TglOpname
    FROM inserted h
    JOIN deleted d0 ON d0.ObjType = h.ObjType AND d0.DocEntry = h.DocEntry
    JOIN dbo.WHS_Opname o ON o.WhsCode = h.WhsCode AND o.Status = 'Hitung' AND CAST(h.DocDate AS DATE) >= o.TglOpname
    WHERE h.DocStatus = 'C' AND ISNULL(d0.DocStatus, '') <> 'C' AND ISNULL(h.TrxCode, '') <> 'OP'
      AND EXISTS (SELECT 1 FROM dbo.KRN1 l JOIN dbo.WHS_OpnameRak r ON r.OpnameId = o.OpnameId AND r.KodeRuangan = l.KodeRuangan
                  WHERE l.ObjType = h.ObjType AND l.DocEntry = h.DocEntry);
    IF @no IS NOT NULL
    BEGIN
        DECLARE @m NVARCHAR(300) = CONCAT('Ruangan sedang stock opname ', @no, ': dokumen bertanggal ', CONVERT(char(10), @tgl, 103), ' atau sesudahnya belum boleh diposting.');
        RAISERROR(@m, 16, 1);
        ROLLBACK TRANSACTION;
    END
END
GO
-- GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.WHS_MasterRak, dbo.WHS_Opname, dbo.WHS_OpnameRak, dbo.WHS_OpnameSaldo, dbo.WHS_OpnameHitung, dbo.WHS_OpnameFinal TO gudang_app;

/* Anti dobel pengambilan dokumen sumber (BL / DO / SO) oleh SPBB / SPMB.
   Teralokasi = outstanding rencana aktif (QtyPlan - QtyDone), termasuk Draft.
   Terpakai   = qty rencana aktif + qty yang sudah diterima/dikirim rencana yang selesai/ditutup (rencana Batal tidak dihitung).
   Tersedia   = MIN(OpenQty - Teralokasi, Quantity - Terpakai): tetap aman walau dokumen ERP penerimaan/pengiriman belum dibuat. */
CREATE OR ALTER VIEW dbo.vw_WHS_PlanAlokasi AS
SELECT d.BaseType, d.BaseDocEntry, d.BaseLineNum,
       SUM(CASE WHEN p.Status IN ('Draft','Terbit','Proses','Partial') AND d.QtyPlan > d.QtyDone THEN d.QtyPlan - d.QtyDone ELSE 0 END) AS Teralokasi,
       SUM(CASE WHEN p.Status IN ('Draft','Terbit','Proses','Partial') THEN CASE WHEN d.QtyPlan > d.QtyDone THEN d.QtyPlan ELSE d.QtyDone END ELSE d.QtyDone END) AS Terpakai
FROM   dbo.WHS_Plan p JOIN dbo.WHS_Plan1 d ON d.PlanId = p.PlanId
WHERE  p.Status <> 'Batal' AND d.BaseType IS NOT NULL AND d.BaseType <> 'TT'
GROUP BY d.BaseType, d.BaseDocEntry, d.BaseLineNum;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WHS_Plan1_Base' AND object_id = OBJECT_ID('dbo.WHS_Plan1'))
    CREATE INDEX IX_WHS_Plan1_Base ON dbo.WHS_Plan1 (BaseType, BaseDocEntry, BaseLineNum) INCLUDE (PlanId, QtyPlan, QtyDone);
GO
