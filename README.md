# Gudang ATM — Aplikasi Krani (Flutter) + API

> Setup server: **`docs/DEPLOY-WINDOWS-SERVER-2019.md`** · Git: `docs/GIT.md` · Status fitur v1/v2: `docs/STATUS.md` · Desain: `design/`

```
gudang_atm/
├─ app/                     Aplikasi Android krani (Flutter)
├─ web/                     Web app React (CMS Admin + versi web krani), responsif HP/laptop
├─ api/GudangAtm.Api/       Server ASP.NET Core 8: REST API + menyajikan web app (wwwroot)
├─ database/                Query relasi, penomoran dokumen, persiapan web (audit log, kolom CMS)
└─ .github/workflows/       Build APK otomatis di GitHub Actions
```

Alur: **HP / browser → server GudangAtm.Api (HTTPS, jaringan kantor) → SQL Server WORKSHOP_STAGING**.
Password database hanya ada di server API, tidak pernah dikirim ke HP atau browser.

## 0. Web app (CMS Admin + Krani)

- Buka `https://<server>:5443` dari laptop atau HP. Di HP tampil seperti aplikasi (header + bottom nav);
  di laptop memakai sidebar dan tabel lebar.
- **Krani**: Beranda, Inbound, Outbound OB/BT/KR/RP (scan QR lewat kamera HP bila browser mendukung,
  scanner barcode USB/Bluetooth, atau ketik), cetak label QR (dialog cetak browser, kertas 100 × 70 mm), Laporan.
- **Admin** (`OUSR.SUPERUSER = 'Y'` atau terdaftar di `Security:AdminUsers`): CMS — cek input krani, pilah TrxCode
  (IB/RC, OB/BT, KR/SS/RP), isi PT, CardCode, No DO, No BL, validasi DO retur ke ODLN per baris, edit qty
  (nilai krani di-backup ke `qty_scan`, `qty2_scan`, `QtyPalet_scan`), posting → status Close (header & baris).
- Web app sudah di-build ke `api/GudangAtm.Api/wwwroot`, jadi cukup jalankan server API.
  Untuk mengubah tampilan: `cd web && npm install && npm run build` (hasil menimpa wwwroot).

### Keamanan yang diterapkan
| Area | Penerapan |
|---|---|
| Transport | HTTPS wajib (HSTS + redirect), cookie `Secure` dengan prefix `__Host-` |
| Sesi web | Cookie HttpOnly + SameSite=Strict, 30 menit sliding, dicek ulang ke OUSR tiap 5 menit; tidak ada token di localStorage |
| CSRF | Token anti-forgery wajib di header `X-XSRF-TOKEN` untuk semua POST/PUT web (termasuk login & logout) |
| Login | Pesan error sama untuk user/password salah, akun dikunci 15 menit setelah 5x gagal, rate limit 10 percobaan/menit/IP |
| Hak akses | Role Krani/Admin; data dibatasi cabang (BPLId) dan warehouse USR9 user; endpoint CMS khusus Admin |
| Input | Semua SQL terparameter (Dapper), validasi panjang/format (No mobil, kontainer, qty), body maks 1 MB |
| Header | CSP ketat (`script-src 'self'`, tanpa inline script), X-Frame-Options DENY, nosniff, Referrer-Policy, Permissions-Policy |
| Error | Detail error tidak dikirim ke browser, hanya ke log server |
| Audit | Tabel `WHS_AuditLog`: login berhasil/gagal/terkunci, logout, buat dokumen, simpan & posting CMS (bisa dilihat di CMS) |
| Aplikasi HP | JWT Bearer (tidak memakai cookie), HTTPS saja (`network_security_config`), CA internal bisa dipasang di HP |

### Yang masih perlu dilakukan tim IT
1. **Password OUSR disimpan Base64** (setara teks biasa). Ideal: pindah ke hash (mis. PBKDF2/bcrypt) — perlu perubahan di sisi SAP/aplikasi lain yang memakai OUSR.
2. Pasang sertifikat HTTPS (`certs/gudang.pfx`, lihat `appsettings.Production.json`) dari CA internal / domain perusahaan.
3. Pakai login SQL khusus (`gudang_app`, contoh di `database/web_security.sql`), bukan `sa`; aktifkan sertifikat SQL Server lalu ubah `TrustServerCertificate=False`.
4. Bila server di belakang IIS/nginx, isi `Security:KnownProxies` agar rate limit & audit memakai IP asli.
5. JWT aplikasi HP berlaku 12 jam dan belum bisa dicabut sebelum habis — perpendek `Jwt:HoursValid` bila perlu.

---

## 1. Database

1. Jalankan `database/web_security.sql` (tabel `WHS_AuditLog`, kolom CMS yang belum ada, login SQL khusus, prosedur posting stok opsional).
1. Jalankan `database/gudang_atm_relasi.sql` bagian **6** untuk membuat `dbo.usp_WHS_NextDocEntry`
   (nomor dokumen `YYMM` + 8 digit, reset per bulan, dari `SYS_NOURUT`).
2. `OKRN.DocEntry`, `KRN1.DocEntry` dan `SYS_NOURUT.Counter` harus **BIGINT** (12 digit melebihi INT).
3. Cocokkan nama kolom yang ditandai **ASUMSI** di `api/GudangAtm.Api/Sql.cs` dengan tabel asli
   (mis. `OKRN.NoMobil`, `OKRN.ContainerNo`, `OKRN.DocStatus`, `KRN1.Quantity/Qty2/QtyPalet`, `KRN1.Origin`, `OUSR.U_NAME`).
   Semua SQL ada di satu file itu.
4. Sangat disarankan membuat login SQL khusus aplikasi (bukan `sa`) dengan hak SELECT/INSERT
   ke tabel terkait dan EXECUTE ke `usp_WHS_NextDocEntry`.

## 2. Server API (Windows / Linux, .NET 8)

1. Install .NET 8 SDK di server kantor.
2. Edit `api/GudangAtm.Api/appsettings.json`:
   - `ConnectionStrings:Gudang` → isi user & password SQL Server (sebaiknya lewat environment variable
     `ConnectionStrings__Gudang`, bukan disimpan di file).
   - `Jwt:Key` → teks acak minimal 32 karakter (server menolak start bila masih "GANTI...").
   - `Security:AdminUsers` → daftar USER_CODE yang boleh membuka CMS (selain OUSR.SUPERUSER = 'Y').
   - `Posting:StockProcedure` → isi `dbo.usp_WHS_PostStock` bila posting harus menulis SaldoWhs/ItemHistoryWhs.
   - Produksi (`appsettings.Production.json`): HTTPS di `https://0.0.0.0:5443` dengan sertifikat `certs/gudang.pfx`.
     Uji coba lokal: `ASPNETCORE_ENVIRONMENT=Development` → `http://0.0.0.0:5080`, HTTPS tidak diwajibkan.
3. Jalankan:
   ```
   cd api/GudangAtm.Api
   dotnet run                      # uji coba
   dotnet publish -c Release -o C:\GudangAtmApi   # untuk dipasang sebagai Windows Service / IIS
   ```
4. Buka port 5443 di firewall server. Tes dari browser HP: `https://<ip-server>:5443/api/health`, lalu buka `https://<ip-server>:5443` untuk web app.

### Endpoint

| Method | Path | Keterangan |
|---|---|---|
| POST | /api/auth/login | `OUSR.USER_CODE` + password (dibandingkan sebagai Base64 dengan `OUSR.password`) |
| GET | /api/warehouses | Pilihan warehouse dari `USR9` + flag titipan (`OWHS.External='Y'`) |
| GET | /api/items?q= · /api/brands | OITM + OITB, SYS_GCM `MSTBRAND` |
| GET | /api/docs?kind=inbound\|outbound | Daftar dokumen + status: Menunggu PT / Siap cetak / Menunggu DO / Selesai |
| POST | /api/inbound | ObjType 6730, TrxCode IB atau BT (otomatis dari warehouse), Flag 1 |
| POST | /api/outbound | OB → 6710 (BT bila titipan); KR/RP → 6720, palet keluar Flag −1, Item Inbound Flag +1; KR/RP ditolak di warehouse titipan |
| GET | /api/pallet?qr=&whsCode= | Baca QR `yymmdd-itemcode-container`, isi per sak/palet, stok |
| GET | /api/labels/{objType}/{docEntry} | Data label; **409 bila PT belum diisi Admin**; PT = `OPRC.PrcName` |
| GET | /api/reports/stock-item · stock-container · stock-card · kpi | Laporan dari dokumen Close |

## 3. Membuat APK

### Cara A — GitHub Actions (tanpa install Flutter)
1. Upload folder `gudang_atm` ke repository GitHub (boleh private).
2. Tab **Actions** → **Build APK Gudang ATM** → **Run workflow**.
3. Setelah selesai (±8 menit), unduh artifact **gudang-atm-apk** → `app-release.apk`.

### Cara B — di laptop
1. Install Flutter 3.24+ dan Android Studio (Android SDK).
2. ```
   cd app
   flutter create --org com.levelup --project-name gudang_atm --platforms=android .
   flutter pub get
   flutter build apk --release
   ```
   `flutter create` hanya menambah file Android yang belum ada; `AndroidManifest.xml` (izin kamera,
   Bluetooth, http lokal) dan kode di `lib/` tetap dipakai.
3. APK ada di `app/build/app/outputs/flutter-apk/app-release.apk`.

APK ini ditandatangani dengan debug key bawaan Flutter (cukup untuk dipasang langsung di HP gudang).
Untuk distribusi resmi, buat keystore sendiri sesuai panduan Flutter "Build and release an Android app".

## 4. Pemakaian di HP

1. Install APK (izinkan "Install unknown apps").
2. Di layar Login, ikon ⚙ → isi alamat server, mis. `https://194.233.84.97:5443` → **Simpan & tes koneksi**.
   Bila sertifikat dari CA internal, pasang dulu sertifikat CA di HP (Pengaturan › Keamanan › Install sertifikat).
3. Pair printer TSC / Xprinter di Pengaturan Bluetooth Android, lalu di aplikasi:
   Pengaturan → Printer → **Pilih** → **Cetak label uji**.
4. Alur krani:
   - **Inbound**: Header (warehouse combo, no mobil, no kontainer) → Detail barang curah (manual) →
     Simpan & kirim ke Admin → status *Menunggu PT* → setelah Admin isi PT di CMS: *Siap cetak* →
     cetak label (jumlah = Qty Palet).
   - **Outbound**: Warehouse dulu → Jenis OB / KR / RP (warehouse titipan otomatis BT, KR & RP terkunci) →
     scan QR palet (keluar utuh / sebagian, KG bisa diubah karena susut) → Item Inbound untuk KR/RP →
     Simpan. Label Item Inbound bisa dicetak setelah Admin isi PT.
   - **Laporan**: Kartu Stok, Stock per Barang, Stock per Container, KPI.

## 5. Catatan

- Kode API & APK belum dikompilasi/diuji terhadap database asli; jalankan dulu di server uji. Web app sudah di-bundle dan dites di browser (HP & laptop) dengan API tiruan.
- Login memakai Base64 sesuai `OUSR.password` — Base64 bukan enkripsi. Pertimbangkan hash (mis. SHA-256 + salt) ke depan.
- Tanda tangan sopir belum disimpan (belum ada kolom di OKRN).
- Satu QR dipakai bersama oleh semua palet item+container yang sama; di layar scan, setelah 1 palet terbaca
  tekan **Scan palet berikutnya** untuk membaca palet berikutnya.
