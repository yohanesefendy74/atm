/* Gudang ATM - Gateway alat (timbangan RS232 dan printer TSC di LAN gudang)
   Jalankan SETELAH gudang_atm_v2_struktur.sql. Aman dijalankan ulang. */

IF OBJECT_ID('dbo.WHS_Gateway') IS NULL
CREATE TABLE dbo.WHS_Gateway (
    GatewayId   NVARCHAR(20)  NOT NULL PRIMARY KEY,        -- contoh GW-JKT01
    WhsCode     NVARCHAR(8)   NOT NULL,                    -- OWHS.WhsCode lokasi PC gateway
    Keterangan  NVARCHAR(60)  NULL,
    KeyHash     CHAR(64)      NOT NULL,                    -- SHA-256 hex dari API key (key asli TIDAK disimpan)
    Aktif       BIT           NOT NULL DEFAULT 1,
    LastSeen    DATETIME2(0)  NULL,
    Versi       NVARCHAR(20)  NULL
);
GO

IF OBJECT_ID('dbo.WHS_MasterPrinter') IS NULL
CREATE TABLE dbo.WHS_MasterPrinter (
    KodePrinter NVARCHAR(10) NOT NULL PRIMARY KEY,         -- LP-01
    WhsCode     NVARCHAR(8)  NOT NULL,
    GatewayId   NVARCHAR(20) NOT NULL REFERENCES dbo.WHS_Gateway(GatewayId),
    Lokasi      NVARCHAR(60) NULL,
    UkuranMm    NVARCHAR(10) NOT NULL DEFAULT '100x70',    -- lebar x tinggi label (mm)
    Aktif       BIT NOT NULL DEFAULT 1
);
GO

/* Timbangan: tambah kolom gateway. Kolom AlamatLan sekarang berisi nama alat di gateway (mis. 'COM3') */
IF COL_LENGTH('dbo.WHS_MasterTimbangan','GatewayId') IS NULL
    ALTER TABLE dbo.WHS_MasterTimbangan ADD GatewayId NVARCHAR(20) NULL REFERENCES dbo.WHS_Gateway(GatewayId);
GO

IF OBJECT_ID('dbo.WHS_GatewayJob') IS NULL
CREATE TABLE dbo.WHS_GatewayJob (
    JobId      BIGINT IDENTITY(1,1) PRIMARY KEY,
    GatewayId  NVARCHAR(20) NOT NULL REFERENCES dbo.WHS_Gateway(GatewayId),
    Tipe       NVARCHAR(8)  NOT NULL CHECK (Tipe IN ('TIMBANG','CETAK')),
    Target     NVARCHAR(10) NOT NULL,                      -- KodeTimbangan / KodePrinter
    Payload    NVARCHAR(MAX) NULL,                         -- CETAK: TSPL yang sudah jadi
    Status     NVARCHAR(10) NOT NULL DEFAULT 'BARU' CHECK (Status IN ('BARU','DIAMBIL','SELESAI','GAGAL','LEWAT')),
    BeratKg    NUMERIC(12,2) NULL,                         -- hasil TIMBANG
    Stabil     BIT NULL,
    Pesan      NVARCHAR(200) NULL,
    UserId     INT NOT NULL,
    Dibuat     DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    Diambil    DATETIME2(0) NULL,
    Selesai    DATETIME2(0) NULL
);
CREATE INDEX IX_WHS_GatewayJob_Antrean ON dbo.WHS_GatewayJob (GatewayId, Status, JobId);
GO

/* Cara membuat gateway (API key dibuat acak oleh admin, hash-nya saja yang masuk tabel):
   PowerShell:  $k = -join ((48..57)+(97..122) | Get-Random -Count 40 | % {[char]$_}); $k
                $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($k))).Replace('-','').ToLower(); $h
   INSERT INTO dbo.WHS_Gateway (GatewayId, WhsCode, Keterangan, KeyHash) VALUES ('GW-JKT01','<WhsCode>','PC gudang Jakarta','<hash>');
   Key asli ($k) dimasukkan ke appsettings.json gateway; JANGAN disimpan di git. */
