/* =====================================================================
   Gudang ATM - struktur tabel v2 (menyesuaikan desain canvas, 14 Okt 2026)
   Database : WORKSHOP_STAGING  | Aman dijalankan ulang (cek IF NOT EXISTS)
   Cakupan  : SPBB dari BL/DO, SPMB dari SO, partial + outstanding,
              registrasi & timbang kendaraan, master ruangan & palet,
              label (utama Admin, tambahan krani), ganti brand.
   Kolom/tabel SAP (OPBL, PBL1, ODLN, DLN1, ORDR, RDR1) hanya DIBACA,
   tidak diubah. Tabel baru berawalan WHS_. Nama kolom SAP bertanda
   -- ASUMSI: cek ke skema asli sebelum dipakai.
   ===================================================================== */
USE WORKSHOP_STAGING;
GO

/* 1. Master ruangan = tabel sendiri di Gudang ATM (BUKAN OBIN SAP). Dibuat/diedit Admin di CMS > Master Warehouse & Ruangan.
      Melebihi kapasitas = peringatan saja. Kode ruangan tidak bisa diubah setelah dibuat (dipakai transaksi).
      Ruangan yang masih berisi barang tidak boleh dinonaktifkan (dicek aplikasi). */
IF OBJECT_ID('dbo.WHS_MasterRuangan') IS NULL
CREATE TABLE dbo.WHS_MasterRuangan (
    KodeRuangan  NVARCHAR(30) NOT NULL PRIMARY KEY,   -- contoh WH-JKT01-R-A01
    WhsCode      NVARCHAR(8) NOT NULL,                -- OWHS.WhsCode
    NamaRuangan  NVARCHAR(100) NOT NULL,
    KapasitasTon NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (KapasitasTon >= 0),   -- 0 = tanpa batas (yard)
    Titipan      BIT NOT NULL DEFAULT 0,              -- ruangan titipan: transaksi BT, SPBB/SPMB wajib kode customer titipan
    Aktif        BIT NOT NULL DEFAULT 1,
    CreatedBy    INT NULL, CreatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    UpdatedBy    INT NULL, UpdatedAt DATETIME2(0) NULL
);
CREATE INDEX IX_WHS_MasterRuangan_Whs ON dbo.WHS_MasterRuangan (WhsCode, Aktif);
GO


/* 2. Master palet: ukuran & berat (berat palet = tara untuk hitung net) */
IF OBJECT_ID('dbo.WHS_MasterPalet') IS NULL
CREATE TABLE dbo.WHS_MasterPalet (
    PaletCode  NVARCHAR(20) NOT NULL PRIMARY KEY,
    PanjangCm  NUMERIC(9,1) NOT NULL, LebarCm NUMERIC(9,1) NOT NULL, TinggiCm NUMERIC(9,1) NOT NULL,
    BeratKg    NUMERIC(9,2) NOT NULL,
    Aktif      BIT NOT NULL DEFAULT 1
);
GO

/* 2a. Master jenis container. Batas muatan TIDAK di-hardcode di aplikasi; dibaca dari sini (CMS > Setup). */
IF OBJECT_ID('dbo.WHS_MasterJenisContainer') IS NULL
CREATE TABLE dbo.WHS_MasterJenisContainer (
    Kode        NVARCHAR(10) NOT NULL PRIMARY KEY,   -- 20, 40, 40HC
    Nama        NVARCHAR(60) NOT NULL,
    BatasMuatanKg NUMERIC(12,2) NOT NULL CHECK (BatasMuatanKg > 0),
    Aktif       BIT NOT NULL DEFAULT 1
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.WHS_MasterJenisContainer)
INSERT dbo.WHS_MasterJenisContainer (Kode, Nama, BatasMuatanKg) VALUES
 ('20','Container 20 ft',28000), ('40','Container 40 ft',26500), ('40HC','Container 40 ft HC',26500);
GO

/* 2b. Setup batas toleransi (persen). Dibaca aplikasi krani untuk Penyesuaian/Susut dan Repacking. */
IF OBJECT_ID('dbo.WHS_Setup') IS NULL
CREATE TABLE dbo.WHS_Setup (
    Kode      NVARCHAR(30) NOT NULL PRIMARY KEY,
    Nilai     NUMERIC(12,4) NOT NULL CHECK (Nilai > 0),
    Keterangan NVARCHAR(120) NULL,
    UpdatedBy INT NULL, UpdatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.WHS_Setup)
INSERT dbo.WHS_Setup (Kode, Nilai, Keterangan) VALUES
 ('SUSUT_WARN_PCT',   1,   'Susut (SS) di atas % stok ditandai untuk Admin'),
 ('KOREKSI_WARN_PCT', 5,   'Koreksi kurang (KR) di atas % stok wajib catatan'),
 ('REPACK_OK_PCT',    0.5, 'Repacking: selisih sampai % total sumber = wajar'),
 ('REPACK_WARN_PCT',  2,   'Repacking: di atas OK sampai % = peringatan; lebih dari ini ditolak (pisah dokumen Susut)'),
 ('TARA_DEV_PCT',     2,   'Tara mobil/kontainer kosong menyimpang > % dari rata-rata riwayat = ditandai'),
 ('BRUTO_MAX_KG',     52000, 'Bruto mobil maksimum di pos timbang masuk (overload ditolak)'),
 ('TARA_MAX_KG',      20000, 'Tara mobil maksimum; di atas ini dianggap tidak wajar'),
 ('NET_TOL_PCT',      0.5, 'Selisih net timbang vs input krani wajar sampai % net'),
 ('NET_ADMIN_PCT',    2,   'Selisih net di atas % butuh kode Admin');
GO

/* 3. Dokumen rencana: SPBB (inbound) & SPMB (outbound), header */
IF OBJECT_ID('dbo.WHS_Plan') IS NULL
CREATE TABLE dbo.WHS_Plan (
    PlanId        BIGINT IDENTITY(1,1) PRIMARY KEY,
    PlanNo        NVARCHAR(30) NOT NULL UNIQUE,    -- SPBB/2610/0012, SPMB/2610/0005
    Jenis         CHAR(4) NOT NULL CHECK (Jenis IN ('SPBB','SPMB')),
    WhsCode       NVARCHAR(8) NOT NULL,            -- OWHS.WhsCode
    BplId         INT NULL,
    -- dokumen dasar SAP ada di WHS_PlanDoc: SPBB = 1 BL/DO, SPMB = 1..n SO (semua SO harus satu customer)
    BaseType      CHAR(2) NOT NULL CHECK (BaseType IN ('BL','DO','SO')),  -- OPBL / ODLN / ORDR
    JenisContainer NVARCHAR(10) NULL REFERENCES dbo.WHS_MasterJenisContainer(Kode),  -- SPMB: acuan batas muatan dari master
    BatasMuatanKg  NUMERIC(12,2) NULL,             -- salinan batas master saat SPMB terbit (peringatan saja bila terlewati)
    TotalPlanKg    NUMERIC(12,2) NULL,             -- total qty rencana semua dokumen terpilih
    CardCode      NVARCHAR(15) NULL,               -- SPMB: WAJIB satu customer (semua SO sama CardCode); SPBB: dari BL/DO
    CardName      NVARCHAR(100) NULL,
    U_IDU_Kode_PT NVARCHAR(20) NULL,               -- SPBB: dari U_IDU_KODE_PT, boleh diubah Admin; OPRC.PrcCode
    -- status
    Status        NVARCHAR(15) NOT NULL DEFAULT 'Terbit'
                  CHECK (Status IN ('Draft','Terbit','Proses','Partial','Selesai','SelesaiKurang','Batal')),
    CloseReason   NVARCHAR(40) NULL,               -- Supplier kurang kirim / Barang rusak/ditolak / Sisa dibatalkan Admin
    ClosedBy      INT NULL, ClosedAt DATETIME2(0) NULL,
    CreatedBy     INT NOT NULL, CreatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT CK_WHS_Plan_Jenis CHECK ((Jenis='SPBB' AND BaseType IN ('BL','DO')) OR (Jenis='SPMB' AND BaseType='SO'))
);
CREATE INDEX IX_WHS_Plan_Status ON dbo.WHS_Plan (WhsCode, Status);
GO

/* 3b. Dokumen SAP yang menjadi dasar plan. SPBB: tepat 1 baris (BL atau DO).
       SPMB: 1..n baris (beberapa SO muat dalam satu SPMB karena orderan sedikit) */
IF OBJECT_ID('dbo.WHS_PlanDoc') IS NULL
CREATE TABLE dbo.WHS_PlanDoc (
    PlanId       BIGINT NOT NULL REFERENCES dbo.WHS_Plan(PlanId),
    BaseType     CHAR(2) NOT NULL CHECK (BaseType IN ('BL','DO','SO')),
    BaseDocEntry INT NOT NULL,
    BaseObjType  NVARCHAR(20) NULL,
    BaseDocNum   INT NOT NULL,
    CardCode     NVARCHAR(15) NULL, CardName NVARCHAR(100) NULL,
    NumAtCard    NVARCHAR(100) NULL, BaseDocDate DATE NULL,
    CONSTRAINT PK_WHS_PlanDoc PRIMARY KEY (PlanId, BaseType, BaseDocEntry)
);
CREATE INDEX IX_WHS_PlanDoc_Base ON dbo.WHS_PlanDoc (BaseType, BaseDocEntry);
GO

/* 3b. Jadwal bongkar muat: jalur/dock per warehouse + kolom jadwal di WHS_Plan.
       Lama = CEILING((persiapan + qty/kecepatan*60) / 5) * 5 menit. Kecepatan & jam kerja dari WHS_Setup. */
IF OBJECT_ID('dbo.WHS_MasterDock') IS NULL
CREATE TABLE dbo.WHS_MasterDock (
    DockCode  NVARCHAR(20) NOT NULL PRIMARY KEY,     -- mis. JKT01-J1
    WhsCode   NVARCHAR(8)  NOT NULL,                 -- OWHS.WhsCode
    Nama      NVARCHAR(50) NOT NULL,                 -- Jalur 1
    Aktif     BIT NOT NULL DEFAULT 1,
    UpdatedBy INT NULL, UpdatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX IX_WHS_MasterDock_Whs ON dbo.WHS_MasterDock (WhsCode, Aktif);
GO
INSERT dbo.WHS_Setup (Kode, Nilai, Keterangan)
SELECT v.Kode, v.Nilai, v.Ket FROM (VALUES
 ('KECEPATAN_BONGKAR_KGJAM', 12000, 'Kecepatan bongkar inbound per jalur (KG/jam)'),
 ('KECEPATAN_MUAT_KGJAM',    15000, 'Kecepatan muat outbound per jalur (KG/jam)'),
 ('PERSIAPAN_MENIT',         15,    'Waktu persiapan per kendaraan (menit)'),
 ('JEDA_MENIT',              10,    'Jeda antar kendaraan di jalur yang sama (menit)'),
 ('JAM_KERJA_MULAI',         480,   'Jam kerja mulai, menit sejak 00:00 (480 = 08:00)'),
 ('JAM_KERJA_SELESAI',       1020,  'Jam kerja selesai, menit sejak 00:00 (1020 = 17:00)')
) v(Kode, Nilai, Ket)
WHERE NOT EXISTS (SELECT 1 FROM dbo.WHS_Setup s WHERE s.Kode = v.Kode);
GO
IF COL_LENGTH('dbo.WHS_Plan','TglJadwal')      IS NULL ALTER TABLE dbo.WHS_Plan ADD TglJadwal DATE NULL;             -- tanggal bongkar/muat
IF COL_LENGTH('dbo.WHS_Plan','EtaDatang')      IS NULL ALTER TABLE dbo.WHS_Plan ADD EtaDatang TIME(0) NULL;          -- perkiraan datang kendaraan (input Admin)
IF COL_LENGTH('dbo.WHS_Plan','DurasiMenit')    IS NULL ALTER TABLE dbo.WHS_Plan ADD DurasiMenit INT NULL;            -- hasil hitung, disimpan saat jadwal diterapkan
IF COL_LENGTH('dbo.WHS_Plan','DockCode')       IS NULL ALTER TABLE dbo.WHS_Plan ADD DockCode NVARCHAR(20) NULL REFERENCES dbo.WHS_MasterDock(DockCode);
IF COL_LENGTH('dbo.WHS_Plan','DockDipin')      IS NULL ALTER TABLE dbo.WHS_Plan ADD DockDipin BIT NOT NULL CONSTRAINT DF_WHS_Plan_DockDipin DEFAULT 0; -- 1 = jalur dipilih manual Admin
IF COL_LENGTH('dbo.WHS_Plan','JadwalMulai')    IS NULL ALTER TABLE dbo.WHS_Plan ADD JadwalMulai DATETIME2(0) NULL;
IF COL_LENGTH('dbo.WHS_Plan','JadwalSelesai')  IS NULL ALTER TABLE dbo.WHS_Plan ADD JadwalSelesai DATETIME2(0) NULL;
IF COL_LENGTH('dbo.WHS_Plan','JadwalCatatan')  IS NULL ALTER TABLE dbo.WHS_Plan ADD JadwalCatatan NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.WHS_Plan','JadwalDikirimAt') IS NULL ALTER TABLE dbo.WHS_Plan ADD JadwalDikirimAt DATETIME2(0) NULL; -- saat jadwal diterapkan & dikirim ke krani
GO
/* 3c. Tanda titipan ada di RUANGAN (WHS_MasterRuangan.Titipan), bukan di warehouse.
       SPBB/SPMB memilih ruangan; bila ruangan titipan, kode customer pemilik barang titipan WAJIB. */
IF COL_LENGTH('dbo.WHS_MasterRuangan','Titipan') IS NULL ALTER TABLE dbo.WHS_MasterRuangan ADD Titipan BIT NOT NULL CONSTRAINT DF_WHS_MasterRuangan_Titipan DEFAULT 0;
IF COL_LENGTH('dbo.WHS_Plan','KodeRuangan')     IS NULL ALTER TABLE dbo.WHS_Plan ADD KodeRuangan NVARCHAR(30) NULL REFERENCES dbo.WHS_MasterRuangan(KodeRuangan);
IF COL_LENGTH('dbo.WHS_Plan','CardCodeTitipan') IS NULL ALTER TABLE dbo.WHS_Plan ADD CardCodeTitipan NVARCHAR(15) NULL;  -- OCRD.CardCode pemilik titipan
IF COL_LENGTH('dbo.WHS_Plan','CardNameTitipan') IS NULL ALTER TABLE dbo.WHS_Plan ADD CardNameTitipan NVARCHAR(100) NULL;
GO
CREATE OR ALTER TRIGGER dbo.TR_WHS_Plan_Titipan ON dbo.WHS_Plan AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.WHS_MasterRuangan r ON r.KodeRuangan = i.KodeRuangan
               WHERE r.Titipan = 1 AND i.Status <> 'Batal' AND NULLIF(LTRIM(RTRIM(i.CardCodeTitipan)), '') IS NULL)
    BEGIN
        RAISERROR('Ruangan titipan: kode customer titipan wajib diisi pada SPBB/SPMB.', 16, 1);
        ROLLBACK TRANSACTION;
    END
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.WHS_MasterRuangan r ON r.KodeRuangan = i.KodeRuangan WHERE r.WhsCode <> i.WhsCode)
    BEGIN
        RAISERROR('Ruangan bukan milik warehouse dokumen ini.', 16, 1);
        ROLLBACK TRANSACTION;
    END
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_WHS_Plan_Jadwal')
CREATE INDEX IX_WHS_Plan_Jadwal ON dbo.WHS_Plan (WhsCode, TglJadwal, DockCode, JadwalMulai);
GO

/* 3c. Aturan 1 SPMB = 1 customer: semua WHS_PlanDoc milik satu plan harus punya CardCode sama dengan WHS_Plan.CardCode.
       Beberapa SO boleh digabung selama customer sama. */
CREATE OR ALTER TRIGGER dbo.TR_WHS_PlanDoc_SatuCustomer ON dbo.WHS_PlanDoc
AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM dbo.WHS_PlanDoc d
               JOIN (SELECT DISTINCT PlanId FROM inserted) i ON i.PlanId = d.PlanId
               JOIN dbo.WHS_Plan p ON p.PlanId = d.PlanId AND p.Jenis = 'SPMB'
               GROUP BY d.PlanId HAVING COUNT(DISTINCT d.CardCode) > 1)
    BEGIN
        RAISERROR('1 SPMB hanya boleh berisi SO dari satu customer.', 16, 1);
        ROLLBACK TRANSACTION;
    END
END
GO

/* 3d. Surat Jalan (sementara HANYA di Gudang ATM, tidak dikirim ke SAP): dibuat Admin dari SPMB pada mobil (registrasi) yang sama.
       Satu Surat Jalan boleh memuat >1 SPMB di mobil itu, termasuk beda customer; PO & alamat kirim disimpan per SPMB. */
IF OBJECT_ID('dbo.WHS_SuratJalan') IS NULL
CREATE TABLE dbo.WHS_SuratJalan (
    SjId       BIGINT IDENTITY(1,1) PRIMARY KEY,
    SjNo       NVARCHAR(30) NOT NULL UNIQUE,       -- SJ/2610/0001
    TglSj      DATE NOT NULL,                       -- tidak boleh lewat hari ini
    RegId      BIGINT NULL,                         -- registrasi kendaraan (WHS_Kendaraan.RegId): semua SPMB di surat ini pada mobil yang sama
    NoPolisi   NVARCHAR(15) NULL, ContainerNo NVARCHAR(11) NULL, Sopir NVARCHAR(60) NULL,
    TotalKg    NUMERIC(12,2) NOT NULL, TotalSak INT NULL, TotalPalet INT NULL,
    Catatan    NVARCHAR(200) NULL,
    Status     NVARCHAR(10) NOT NULL DEFAULT 'Draft' CHECK (Status IN ('Draft','Terbit','Batal')),
    CreatedBy  INT NOT NULL, CreatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    BatalBy    INT NULL, BatalAt DATETIME2(0) NULL
);
GO
/* SPMB di dalam Surat Jalan: customer, PO, dan alamat kirim per SPMB */
IF OBJECT_ID('dbo.WHS_SuratJalanPlan') IS NULL
CREATE TABLE dbo.WHS_SuratJalanPlan (
    SjId       BIGINT NOT NULL REFERENCES dbo.WHS_SuratJalan(SjId),
    PlanId     BIGINT NOT NULL REFERENCES dbo.WHS_Plan(PlanId),   -- SPMB: Jenis='SPMB', Status 'Selesai'
    CardCode   NVARCHAR(15) NOT NULL, CardName NVARCHAR(100) NULL,
    NumAtCard  NVARCHAR(100) NULL,                  -- No. PO, default dari SO, boleh diubah Admin
    AlamatKirim NVARCHAR(300) NOT NULL,
    Aktif      BIT NOT NULL DEFAULT 1,              -- 0 saat Surat Jalan dibatalkan (trigger di bawah)
    CONSTRAINT PK_WHS_SuratJalanPlan PRIMARY KEY (SjId, PlanId)
);
-- 1 SPMB hanya boleh ada di 1 Surat Jalan aktif; yang dibatalkan boleh dibuatkan lagi
CREATE UNIQUE INDEX UX_WHS_SuratJalanPlan_Aktif ON dbo.WHS_SuratJalanPlan (PlanId) WHERE Aktif = 1;
GO
CREATE OR ALTER TRIGGER dbo.TR_WHS_SuratJalan_Batal ON dbo.WHS_SuratJalan AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    UPDATE p SET Aktif = 0 FROM dbo.WHS_SuratJalanPlan p JOIN inserted i ON i.SjId = p.SjId WHERE i.Status = 'Batal';
END
GO
/* Baris Surat Jalan = qty yang benar-benar dimuat (hasil scan krani), bukan qty rencana SPMB */
IF OBJECT_ID('dbo.WHS_SuratJalan1') IS NULL
CREATE TABLE dbo.WHS_SuratJalan1 (
    SjId     BIGINT NOT NULL REFERENCES dbo.WHS_SuratJalan(SjId),
    SjLine   INT NOT NULL,
    PlanId   BIGINT NOT NULL,                       -- SPMB asal baris ini
    ItemCode NVARCHAR(50) NOT NULL, Dscription NVARCHAR(200) NULL,
    QtyPlan  NUMERIC(12,2) NOT NULL,                -- dari SPMB
    QtyMuat  NUMERIC(12,2) NOT NULL,                -- dari scan
    QtySak   INT NULL, QtyPalet INT NULL,
    CONSTRAINT PK_WHS_SuratJalan1 PRIMARY KEY (SjId, SjLine),
    CONSTRAINT FK_WHS_SuratJalan1_Plan FOREIGN KEY (SjId, PlanId) REFERENCES dbo.WHS_SuratJalanPlan(SjId, PlanId)
);
GO

/* 4. Dokumen rencana: baris. Satu baris = satu baris SAP (PBL1/DLN1/RDR1) */
IF OBJECT_ID('dbo.WHS_Plan1') IS NULL
CREATE TABLE dbo.WHS_Plan1 (
    PlanId        BIGINT NOT NULL REFERENCES dbo.WHS_Plan(PlanId),
    PlanLine        INT NOT NULL,
    BaseType      CHAR(2) NOT NULL,
    BaseDocEntry  INT NOT NULL,                    -- dokumen asal baris (penting untuk SPMB multi SO)
    BaseLineNum   INT NULL,                        -- LineNum baris SAP
    ContainerNo   NVARCHAR(11) NULL,               -- per item: BL = PBL1.ShipToCode (wajib, ISO 6346); DO opsional; SPMB = ambil dari container
    ItemCode      NVARCHAR(50) NOT NULL,           -- OITM
    Dscription    NVARCHAR(200) NULL,
    FreeTxt       NVARCHAR(200) NULL,
    BrandName     NVARCHAR(100) NULL,              -- PBL1.StgDesc (SYS_GCM MSTBRAND)
    Size          NVARCHAR(50) NULL,               -- PBL1.SerialNum
    [Type]        NVARCHAR(50) NULL,               -- PBL1.BaseAtCard
    Crop          NVARCHAR(50) NULL,               -- PBL1.BlockNum
    QtyBase       NUMERIC(19,6) NOT NULL,          -- Quantity SAP (snapshot)
    OpenQtyBase   NUMERIC(19,6) NOT NULL,          -- OpenQty SAP saat SPBB/SPMB dibuat
    QtyPlan       NUMERIC(19,6) NOT NULL,          -- <= OpenQty - alokasi plan aktif lain
    Qty2Plan      NUMERIC(19,6) NULL,              -- karung, dari U_IDU_QtyPack (proporsional)
    PaletCode     NVARCHAR(20) NULL,               -- jenis palet per item (WHS_MasterPalet.PaletCode), wajib untuk SPBB
    PaletPlan     INT NULL,
    KodeRuangan   NVARCHAR(30) NULL REFERENCES dbo.WHS_MasterRuangan(KodeRuangan),   -- ruangan tujuan
    QtyDone       NUMERIC(19,6) NOT NULL DEFAULT 0,   -- total diterima/dikirim (jumlah semua penerimaan)
    Qty2Done      NUMERIC(19,6) NOT NULL DEFAULT 0,
    PaletDone     INT NOT NULL DEFAULT 0,
    QtyOutstanding AS (QtyPlan - QtyDone) PERSISTED,
    CONSTRAINT PK_WHS_Plan1 PRIMARY KEY (PlanId, PlanLine),
    CONSTRAINT CK_WHS_Plan1_Qty CHECK (QtyPlan > 0 AND QtyDone >= 0)
);
GO

/* 5. Penugasan krani */
IF OBJECT_ID('dbo.WHS_PlanKrani') IS NULL
CREATE TABLE dbo.WHS_PlanKrani (
    PlanId BIGINT NOT NULL REFERENCES dbo.WHS_Plan(PlanId),
    UserId INT NOT NULL,                           -- OUSR.USERID
    AssignedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_WHS_PlanKrani PRIMARY KEY (PlanId, UserId)
);
GO

/* 6. Tabel transaksi krani: kaitkan ke plan. Satu OKRN = satu penerimaan/pengiriman */
IF COL_LENGTH('dbo.OKRN','PlanId')        IS NULL ALTER TABLE dbo.OKRN ADD PlanId BIGINT NULL;
IF COL_LENGTH('dbo.OKRN','PenerimaanKe')  IS NULL ALTER TABLE dbo.OKRN ADD PenerimaanKe INT NULL;   -- partial: 1,2,3...
IF COL_LENGTH('dbo.OKRN','RegId')         IS NULL ALTER TABLE dbo.OKRN ADD RegId BIGINT NULL;       -- kendaraan
IF COL_LENGTH('dbo.OKRN','BaseType')      IS NULL ALTER TABLE dbo.OKRN ADD BaseType CHAR(2) NULL;
IF COL_LENGTH('dbo.OKRN','BaseDocEntry')  IS NULL ALTER TABLE dbo.OKRN ADD BaseDocEntry INT NULL;
IF COL_LENGTH('dbo.OKRN','BaseDocNum')    IS NULL ALTER TABLE dbo.OKRN ADD BaseDocNum INT NULL;
/* Penyesuaian (KR), Susut (SS), Repacking (RP): memakai OKRN/KRN1 yang sudah ada.
   ObjType 6720 = KR/RP, 6710 = SS. KRN1.Flag: -1 = barang keluar (sumber), +1 = masuk (hasil).
   RP boleh banyak baris sumber dan banyak baris hasil dalam SATU dokumen. */
IF COL_LENGTH('dbo.OKRN','AlasanKode')    IS NULL ALTER TABLE dbo.OKRN ADD AlasanKode NVARCHAR(20) NULL;     -- opname, salah, rusak, lain / lembab, tumpah, timbang
IF COL_LENGTH('dbo.OKRN','Catatan')       IS NULL ALTER TABLE dbo.OKRN ADD Catatan NVARCHAR(200) NULL;       -- wajib min. 5 huruf bila AlasanKode = 'lain'
IF COL_LENGTH('dbo.OKRN','FotoPath')      IS NULL ALTER TABLE dbo.OKRN ADD FotoPath NVARCHAR(300) NULL;      -- wajib untuk KR/SS yang mengurangi stok
IF COL_LENGTH('dbo.OKRN','SelisihPersen') IS NULL ALTER TABLE dbo.OKRN ADD SelisihPersen NUMERIC(6,2) NULL; -- RP: (total sumber - total hasil)/total sumber; <=0,5 normal, <=2 dicatat Admin, >2 ditolak
IF COL_LENGTH('dbo.KRN1','Peran')         IS NULL ALTER TABLE dbo.KRN1 ADD Peran NVARCHAR(6) NULL;           -- RP: 'SUMBER' / 'HASIL'
IF COL_LENGTH('dbo.KRN1','PaletCode')     IS NULL ALTER TABLE dbo.KRN1 ADD PaletCode NVARCHAR(20) NULL;      -- jenis palet (SPBB per item, RP hasil)
IF COL_LENGTH('dbo.KRN1','SrcContainerNo') IS NULL ALTER TABLE dbo.KRN1 ADD SrcContainerNo NVARCHAR(11) NULL; -- container stok sumber (RP/KR/SS per baris)
IF COL_LENGTH('dbo.KRN1','ContainerNo')   IS NULL ALTER TABLE dbo.KRN1 ADD ContainerNo NVARCHAR(11) NULL;   -- container per item (SPBB banyak container); dilewati bila kolom sudah ada
IF COL_LENGTH('dbo.KRN1','PlanLine')    IS NULL ALTER TABLE dbo.KRN1 ADD PlanLine INT NULL;
IF COL_LENGTH('dbo.KRN1','Size')          IS NULL ALTER TABLE dbo.KRN1 ADD Size NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.KRN1','Type')          IS NULL ALTER TABLE dbo.KRN1 ADD [Type] NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.KRN1','Crop')          IS NULL ALTER TABLE dbo.KRN1 ADD Crop NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.KRN1','KodeRuangan')   IS NULL ALTER TABLE dbo.KRN1 ADD KodeRuangan NVARCHAR(30) NULL;   -- isi dari WHS_MasterRuangan.KodeRuangan
IF COL_LENGTH('dbo.KRN1','brand_asli')    IS NULL ALTER TABLE dbo.KRN1 ADD brand_asli NVARCHAR(100) NULL;   -- brand awal sebelum diganti krani
IF COL_LENGTH('dbo.KRN1','brand_diubah_oleh') IS NULL ALTER TABLE dbo.KRN1 ADD brand_diubah_oleh INT NULL;
IF COL_LENGTH('dbo.KRN1','brand_diubah_at')   IS NULL ALTER TABLE dbo.KRN1 ADD brand_diubah_at DATETIME2(0) NULL;
GO

/* 5b. Titipan dan non-titipan TIDAK BOLEH dicampur.
       (a) Satu dokumen: ruangan tujuan/asal di KRN1 harus berjenis sama dengan ruangan dokumen (WHS_Plan.KodeRuangan).
       (b) Satu Surat Jalan: semua SPMB di dalamnya harus sama-sama titipan atau sama-sama non-titipan. */
CREATE OR ALTER TRIGGER dbo.TR_KRN1_TitipanCampur ON dbo.KRN1 AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM inserted i
               JOIN dbo.OKRN h ON h.DocEntry = i.DocEntry
               JOIN dbo.WHS_Plan p ON p.PlanId = h.PlanId
               JOIN dbo.WHS_MasterRuangan rp ON rp.KodeRuangan = p.KodeRuangan
               JOIN dbo.WHS_MasterRuangan ri ON ri.KodeRuangan = i.KodeRuangan
               WHERE ri.Titipan <> rp.Titipan)
    BEGIN
        RAISERROR('Titipan dan non-titipan tidak boleh dicampur: ruangan tidak sesuai jenis dokumen.', 16, 1);
        ROLLBACK TRANSACTION;
    END
END
GO
/* (c) Satu dokumen krani (termasuk Repacking RP: baris SUMBER dan HASIL): semua ruangan harus sama jenisnya
       (semua titipan atau semua non-titipan). Berlaku juga untuk dokumen tanpa PlanId (RP, KR, SS). */
CREATE OR ALTER TRIGGER dbo.TR_KRN1_TitipanSatuDokumen ON dbo.KRN1 AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1
               FROM (SELECT DISTINCT DocEntry FROM inserted) d
               JOIN dbo.KRN1 k ON k.DocEntry = d.DocEntry
               JOIN dbo.WHS_MasterRuangan r ON r.KodeRuangan = COALESCE(k.KodeRuangan, '')
               GROUP BY d.DocEntry
               HAVING COUNT(DISTINCT r.Titipan) > 1)
    BEGIN
        RAISERROR('Titipan dan non-titipan tidak boleh dicampur dalam satu dokumen (ruangan sumber/hasil berbeda jenis).', 16, 1);
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
               JOIN dbo.WHS_MasterRuangan ra ON ra.KodeRuangan = pa.KodeRuangan
               JOIN dbo.WHS_SuratJalanPlan b ON b.SjId = a.SjId AND b.PlanId <> a.PlanId
               JOIN dbo.WHS_Plan pb ON pb.PlanId = b.PlanId
               JOIN dbo.WHS_MasterRuangan rb ON rb.KodeRuangan = pb.KodeRuangan
               WHERE ra.Titipan <> rb.Titipan
                 AND a.SjId IN (SELECT SjId FROM inserted))
    BEGIN
        RAISERROR('Titipan dan non-titipan tidak boleh dicampur dalam satu Surat Jalan.', 16, 1);
        ROLLBACK TRANSACTION;
    END
END
GO
/* ContainerNo + PT sudah ada di OKRN/ItemHistoryWhs/SaldoWhs (lihat README) */

/* 7. Registrasi kendaraan (pos timbang atau layar mobile gudang tanpa timbangan) */
IF OBJECT_ID('dbo.WHS_Kendaraan') IS NULL
CREATE TABLE dbo.WHS_Kendaraan (
    RegId        BIGINT IDENTITY(1,1) PRIMARY KEY,
    Tiket        NVARCHAR(20) NOT NULL UNIQUE,     -- TB-261013-0034
    WhsCode      NVARCHAR(8) NOT NULL,
    Keperluan    NVARCHAR(15) NOT NULL CHECK (Keperluan IN ('Bongkar','Muat','AmbilKontainer')),
    PlanId       BIGINT NULL REFERENCES dbo.WHS_Plan(PlanId),
    NoPolisi     NVARCHAR(12) NOT NULL,            -- validasi regex di API
    Sopir        NVARCHAR(60) NOT NULL,
    ContainerNo  NVARCHAR(11) NULL,
    AlasanBedaPlan NVARCHAR(100) NULL,
    JamMasuk     DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    JamKeluar    DATETIME2(0) NULL,
    SelesaiKrani BIT NOT NULL DEFAULT 0,           -- syarat boleh keluar
    Status       NVARCHAR(10) NOT NULL DEFAULT 'Di dalam' CHECK (Status IN ('Di dalam','Keluar','Batal')),
    InUser       INT NOT NULL, OutUser INT NULL
);
CREATE INDEX IX_WHS_Kendaraan_Aktif ON dbo.WHS_Kendaraan (WhsCode, Status, NoPolisi);
GO

/* 7b. Master timbangan. Satu gudang boleh punya BANYAK timbangan palet (dan timbangan kendaraan). Dikelola di CMS > Master Warehouse & Ruangan. */
IF OBJECT_ID('dbo.WHS_MasterTimbangan') IS NULL
CREATE TABLE dbo.WHS_MasterTimbangan (
    KodeTimbangan NVARCHAR(10) NOT NULL PRIMARY KEY,   -- TP-01, TP-02, TB-01
    WhsCode       NVARCHAR(8) NOT NULL,                -- OWHS.WhsCode
    Alat          NVARCHAR(10) NOT NULL CHECK (Alat IN ('KENDARAAN','PALET')),
    Lokasi        NVARCHAR(60) NULL,
    AlamatLan     NVARCHAR(30) NOT NULL,               -- IP:port indikator
    TolOverridePct NUMERIC(5,2) NULL CHECK (TolOverridePct IS NULL OR TolOverridePct > 0),  -- NULL = pakai WHS_Setup.NET_TOL_PCT
    Aktif         BIT NOT NULL DEFAULT 1,
    CONSTRAINT UQ_WHS_MasterTimbangan_Lan UNIQUE (AlamatLan)
);
CREATE INDEX IX_WHS_MasterTimbangan_Whs ON dbo.WHS_MasterTimbangan (WhsCode, Alat, Aktif);
GO

/* 8. Timbangan (kendaraan dan palet): bruto/tara, sumber indikator, foto, persetujuan Admin */
IF OBJECT_ID('dbo.WHS_Timbang') IS NULL
CREATE TABLE dbo.WHS_Timbang (
    TimbangId    BIGINT IDENTITY(1,1) PRIMARY KEY,
    RegId        BIGINT NULL REFERENCES dbo.WHS_Kendaraan(RegId),
    OKRN_DocEntry BIGINT NULL,
    Alat         NVARCHAR(10) NOT NULL CHECK (Alat IN ('KENDARAAN','PALET')),
    KodeTimbangan NVARCHAR(10) NULL REFERENCES dbo.WHS_MasterTimbangan(KodeTimbangan),  -- timbangan yang dipilih krani (NULL bila manual)
    Jenis        NVARCHAR(8) NOT NULL CHECK (Jenis IN ('BRUTO','TARA')),
    BeratKg      NUMERIC(12,2) NOT NULL,
    Sumber       NVARCHAR(8) NOT NULL CHECK (Sumber IN ('LAN','MANUAL')),
    IndikatorStatus NVARCHAR(20) NULL,             -- Normal / Bergoyang / LAN putus / Overload
    TaraKontainer NUMERIC(9,2) NULL, TaraCSC NUMERIC(9,2) NULL,
    NetHitung    NUMERIC(12,2) NULL,               -- bruto - tara - tara kontainer - palet
    NetInputKrani NUMERIC(12,2) NULL,
    SelisihPersen NUMERIC(6,2) NULL,               -- >0,5 tandai Admin, >2 butuh kode Admin
    KodeAdminOleh INT NULL,                        -- user Admin yang menyetujui
    FotoPath     NVARCHAR(300) NULL,
    UserId       INT NOT NULL, WaktuTimbang DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO

/* 8b. Riwayat berat (tidak bisa diubah/dihapus). Tiap penimbangan tara disalin ke sini oleh sistem dari WHS_Timbang.
       Dipakai sebagai acuan: tara baru dibandingkan dengan rata-rata riwayat (batas % di WHS_Setup 'TARA_DEV_PCT'). */
IF OBJECT_ID('dbo.WHS_RiwayatBeratMobil') IS NULL
CREATE TABLE dbo.WHS_RiwayatBeratMobil (
    RiwayatId   BIGINT IDENTITY(1,1) PRIMARY KEY,
    NoPolisi    NVARCHAR(15) NOT NULL,
    WhsCode     NVARCHAR(8) NOT NULL,
    TaraKg      NUMERIC(12,2) NOT NULL CHECK (TaraKg > 0),     -- berat mobil kosong (tanpa kontainer / muatan)
    Sumber      NVARCHAR(8) NOT NULL CHECK (Sumber IN ('LAN','MANUAL')),
    KodeTimbangan NVARCHAR(10) NULL REFERENCES dbo.WHS_MasterTimbangan(KodeTimbangan),
    TimbangId   BIGINT NULL REFERENCES dbo.WHS_Timbang(TimbangId),
    RegId       BIGINT NULL REFERENCES dbo.WHS_Kendaraan(RegId),
    Sopir       NVARCHAR(60) NULL,
    SelisihRataPersen NUMERIC(6,2) NULL,                         -- vs rata-rata riwayat sebelum baris ini
    UserId      INT NOT NULL, WaktuTimbang DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX IX_WHS_RiwayatBeratMobil ON dbo.WHS_RiwayatBeratMobil (NoPolisi, WaktuTimbang DESC);
GO
IF OBJECT_ID('dbo.WHS_RiwayatBeratKontainer') IS NULL
CREATE TABLE dbo.WHS_RiwayatBeratKontainer (
    RiwayatId   BIGINT IDENTITY(1,1) PRIMARY KEY,
    ContainerNo NVARCHAR(11) NOT NULL,
    WhsCode     NVARCHAR(8) NOT NULL,
    TaraKg      NUMERIC(12,2) NOT NULL CHECK (TaraKg > 0),     -- berat kontainer KOSONG
    Peristiwa   NVARCHAR(20) NOT NULL CHECK (Peristiwa IN ('MASUK_YARD','DIBAWA_MOBIL','AMBIL_YARD','KOSONG_SETELAH_BONGKAR')),
    NoPolisi    NVARCHAR(15) NULL,                              -- mobil pengangkut
    Sumber      NVARCHAR(8) NOT NULL CHECK (Sumber IN ('LAN','MANUAL')),
    KodeTimbangan NVARCHAR(10) NULL REFERENCES dbo.WHS_MasterTimbangan(KodeTimbangan),
    TimbangId   BIGINT NULL REFERENCES dbo.WHS_Timbang(TimbangId),
    RegId       BIGINT NULL REFERENCES dbo.WHS_Kendaraan(RegId),
    SelisihRataPersen NUMERIC(6,2) NULL,
    UserId      INT NOT NULL, WaktuTimbang DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX IX_WHS_RiwayatBeratKontainer ON dbo.WHS_RiwayatBeratKontainer (ContainerNo, WaktuTimbang DESC);
GO
/* Riwayat append-only: UPDATE/DELETE ditolak */
CREATE OR ALTER TRIGGER dbo.TR_WHS_RiwayatBeratMobil_Lock ON dbo.WHS_RiwayatBeratMobil AFTER UPDATE, DELETE AS
BEGIN RAISERROR('Riwayat berat tidak boleh diubah atau dihapus.', 16, 1); ROLLBACK TRANSACTION; END
GO
CREATE OR ALTER TRIGGER dbo.TR_WHS_RiwayatBeratKontainer_Lock ON dbo.WHS_RiwayatBeratKontainer AFTER UPDATE, DELETE AS
BEGIN RAISERROR('Riwayat berat tidak boleh diubah atau dihapus.', 16, 1); ROLLBACK TRANSACTION; END
GO
/* Ringkasan per mobil / kontainer: tara terakhir, rata-rata, jumlah timbang */
CREATE OR ALTER VIEW dbo.vw_WHS_TaraMobil AS
SELECT NoPolisi, COUNT(*) AS JumlahTimbang, AVG(TaraKg) AS RataTara, MIN(TaraKg) AS MinTara, MAX(TaraKg) AS MaxTara,
       (SELECT TOP 1 r2.TaraKg FROM dbo.WHS_RiwayatBeratMobil r2 WHERE r2.NoPolisi = r.NoPolisi ORDER BY r2.WaktuTimbang DESC) AS TaraTerakhir
FROM dbo.WHS_RiwayatBeratMobil r GROUP BY NoPolisi;
GO
CREATE OR ALTER VIEW dbo.vw_WHS_TaraKontainer AS
SELECT ContainerNo, COUNT(*) AS JumlahTimbang, AVG(TaraKg) AS RataTara, MIN(TaraKg) AS MinTara, MAX(TaraKg) AS MaxTara,
       (SELECT TOP 1 r2.TaraKg FROM dbo.WHS_RiwayatBeratKontainer r2 WHERE r2.ContainerNo = r.ContainerNo ORDER BY r2.WaktuTimbang DESC) AS TaraTerakhir
FROM dbo.WHS_RiwayatBeratKontainer r GROUP BY ContainerNo;
GO

/* 9. Yard kontainer (kontainer yang ditinggal, bisa diambil mobil lain) */
IF OBJECT_ID('dbo.WHS_Kontainer') IS NULL
CREATE TABLE dbo.WHS_Kontainer (
    ContainerNo  NVARCHAR(11) NOT NULL,
    WhsCode      NVARCHAR(8) NOT NULL,
    Posisi       NVARCHAR(20) NULL,                -- slot yard
    Kondisi      NVARCHAR(10) NULL CHECK (Kondisi IN ('Isi','Kosong')),
    TaraKg       NUMERIC(9,2) NULL,
    Status       NVARCHAR(10) NOT NULL DEFAULT 'Di yard' CHECK (Status IN ('Di yard','Keluar')),
    MasukRegId   BIGINT NULL, KeluarRegId BIGINT NULL,
    CONSTRAINT PK_WHS_Kontainer PRIMARY KEY (ContainerNo, WhsCode)
);
GO

/* 10. Log label: utama (Admin), tambahan & reprint (krani/Admin) */
IF OBJECT_ID('dbo.WHS_LabelLog') IS NULL
CREATE TABLE dbo.WHS_LabelLog (
    LabelLogId   BIGINT IDENTITY(1,1) PRIMARY KEY,
    PlanId       BIGINT NULL, OKRN_DocEntry BIGINT NULL,
    ItemCode     NVARCHAR(50) NOT NULL, ContainerNo NVARCHAR(11) NULL,
    BrandName    NVARCHAR(100) NULL,
    JumlahLabel  INT NOT NULL CHECK (JumlahLabel BETWEEN 1 AND 500),
    Jenis        NVARCHAR(8) NOT NULL CHECK (Jenis IN ('UTAMA','TAMBAHAN','REPRINT')),  -- TAMBAHAN: 1-10/cetak
    Alasan       NVARCHAR(100) NULL,               -- wajib untuk TAMBAHAN & REPRINT
    Printer      NVARCHAR(60) NULL,
    UkuranLabel  NVARCHAR(20) NULL,
    PrintedBy    INT NOT NULL, Role NVARCHAR(10) NOT NULL, PrintedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO

/* 11. Log ganti brand oleh krani (QR tidak berubah: tanggal+item+container) */
IF OBJECT_ID('dbo.WHS_BrandChangeLog') IS NULL
CREATE TABLE dbo.WHS_BrandChangeLog (
    Id BIGINT IDENTITY(1,1) PRIMARY KEY,
    OKRN_DocEntry BIGINT NOT NULL, LineNum INT NOT NULL,
    BrandLama NVARCHAR(100) NULL, BrandBaru NVARCHAR(100) NOT NULL,
    DiterapkanKeBaris BIT NOT NULL DEFAULT 0,
    ChangedBy INT NOT NULL, ChangedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO

/* 12. Alokasi tersedia = OpenQty SAP - qty plan aktif lain (dipakai API & CMS)
       Plan aktif = Status Terbit/Proses/Partial. Dikurangi yang sudah terkirim ke
       SAP akan ikut turun lewat OpenQty, jadi hitung hanya sisa outstanding. */
CREATE OR ALTER VIEW dbo.vw_WHS_PlanAlokasi AS
SELECT d.BaseType, d.BaseDocEntry, d.BaseLineNum,
       SUM(d.QtyPlan - d.QtyDone) AS Teralokasi
FROM   dbo.WHS_Plan p JOIN dbo.WHS_Plan1 d ON d.PlanId = p.PlanId
WHERE  p.Status IN ('Terbit','Proses','Partial')
GROUP BY d.BaseType, d.BaseDocEntry, d.BaseLineNum;
GO

/* 13. Sumber SAP - SPBB dari BL (container ada) - tersedia = OpenQty - Teralokasi */
-- Header (SQL Server: GETDATE() pengganti Sysdate; Objtype cukup sekali)
-- SELECT ObjType, DocEntry, CardName, DocDate, NumAtCard, DocNum, U_IDU_KODE_PT
-- FROM OPBL WHERE CANCELED='N' AND DocStatus='O' AND DocType='I' AND DocDate <= GETDATE();
-- Baris BL (ganti OPBL->ODLN, PBL1->DLN1 untuk DO tanpa container; ORDR/RDR1 untuk SPMB)
-- SELECT l.LineNum, l.ItemCode, l.Dscription, l.Quantity, l.OpenQty, l.U_IDU_QtyPack, l.FreeTxt,
--        l.ShipToCode AS ContainerNo, l.StgDesc AS BrandName, l.SerialNum AS Size,
--        l.BaseAtCard AS [Type], l.BlockNum AS Crop,
--        l.OpenQty - ISNULL(a.Teralokasi,0) AS Tersedia
-- FROM PBL1 l LEFT JOIN dbo.vw_WHS_PlanAlokasi a
--   ON a.BaseType='BL' AND a.BaseDocEntry=l.DocEntry AND a.BaseLineNum=l.LineNum
-- WHERE l.DocEntry=@DocEntry AND l.OpenQty>0;      -- ASUMSI nama kolom PBL1
