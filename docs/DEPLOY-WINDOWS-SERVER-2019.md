# Setup di server cloud Windows Server 2019 — langkah demi langkah

Hasil akhir: API + web app Gudang ATM jalan sebagai **Windows Service** (`GudangAtmApi`) di `https://<alamat-server>:5443`,
terhubung ke SQL Server `WORKSHOP_STAGING`. HP krani memakai APK atau membuka alamat itu di browser.

```
HP / laptop  --HTTPS 5443-->  Server cloud Win 2019 (GudangAtmApi.exe, Kestrel)  --1433 (VPN/privat)-->  SQL Server (satu server, localhost)
```

> **Yang perlu dipahami dulu**
> 1. Kode di repo ini adalah **versi 1** (inbound/outbound, QR, label, CMS cek input & posting). Fitur desain v2
>    (SPBB/SPMB, Jadwal, Surat Jalan, titipan per ruangan, Setup, Riwayat Berat) **belum dibuat kodenya**; lihat `docs/STATUS.md`.
>    Skrip `database/gudang_atm_v2_struktur.sql` sudah disiapkan tetapi belum dipakai API v1.
> 2. Skrip PowerShell di `deploy/` **belum diuji di server sungguhan**. Jalankan pertama kali di server uji / snapshot.
> 3. Password database **tidak** disimpan di Git. Ia dimasukkan sekali saat langkah 6 dan disimpan di pengaturan service.

---

## 0. Cek sebelum mulai

| Hal | Cara cek | Kalau gagal |
|---|---|---|
| Server cloud bisa menjangkau SQL Server `localhost:1433` | di server: `Test-NetConnection localhost -Port 1433` | `194.233.84.97` adalah alamat privat. Perlu **VPN site-to-site / VPN client** dari cloud ke jaringan kantor, atau SQL Server dipindah/di-replikasi ke cloud. **Jangan** membuka port 1433 ke internet. |
| Alamat yang dipakai HP | IP publik atau (lebih baik) nama domain, mis. `gudang.perusahaan.co.id` | Siapkan A-record ke IP publik server |
| Akses internet dari server | `Invoke-WebRequest https://github.com -UseBasicParsing` | Perlu untuk download .NET, Git, dan clone |
| Akses ke repository Git | URL repo + Personal Access Token (repo private) | Lihat `docs/GIT.md` |
| Akun admin SQL (untuk menjalankan skrip tabel) | Dari PC admin dengan SSMS | Minta DBA |

Port yang dibuka di **security group / firewall cloud**: `3389` (RDP, batasi ke IP Anda) dan `5443` (HTTPS aplikasi, batasi ke IP kantor/VPN bila memungkinkan). Port lain tidak perlu.

---

## 1. Masuk ke server dan update dasar

1. RDP ke server sebagai Administrator.
2. Windows Update sampai selesai, restart bila diminta.
3. Buka **PowerShell sebagai Administrator** (klik kanan → Run as administrator).
4. (Sekali saja) izinkan skrip lokal:
   ```powershell
   Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
   ```

## 2. Siapkan database (dari PC admin, bukan dari server)

Buka SSMS, sambung ke `localhost` (atau 194.233.84.97 dari PC lain) dengan akun admin, lalu jalankan **berurutan** (semua aman diulang):

1. `database/web_security.sql` — tabel `WHS_AuditLog`, kolom CMS, dll. Di bagian 3 file ini ada contoh membuat login khusus aplikasi.
2. `database/gudang_atm_relasi.sql` — **hanya bagian 6** (prosedur `dbo.usp_WHS_NextDocEntry`). Bagian lain berisi contoh query.
3. `database/gudang_atm_v2_struktur.sql` — tabel desain v2 (`WHS_*`). Boleh ditunda sampai kodenya dibuat, tetapi aman dijalankan sekarang.

Lalu buat **login SQL khusus aplikasi** (jangan pakai `sa`). Ganti `PASSWORD-KUAT` dengan password acak minimal 16 karakter,
**tanpa tanda `;` dan `=`** (karena masuk connection string):

```sql
USE master;
CREATE LOGIN gudang_app WITH PASSWORD = 'PASSWORD-KUAT', CHECK_POLICY = ON;
USE WORKSHOP_STAGING;
CREATE USER gudang_app FOR LOGIN gudang_app;
-- hak minimum; sesuaikan bila ada tabel lain yang dibaca API
GRANT SELECT, INSERT, UPDATE ON SCHEMA::dbo TO gudang_app;
GRANT EXECUTE ON SCHEMA::dbo TO gudang_app;
```

Cek koneksi dari server nanti (langkah 6) memakai login ini. Hapus/ubah hak lebih ketat setelah semua fitur teruji (mis. tanpa DELETE, tanpa DDL).

## 3. Pasang prasyarat di server

Salin folder `deploy/` ke server (RDP: salin-tempel, atau `git clone` dulu di langkah 4 lalu jalankan dari `C:\GudangAtm\src\gudang-atm\deploy`).

```powershell
cd C:\GudangAtm\src\gudang-atm\deploy      # atau lokasi tempat Anda menyalin
.\01-prasyarat.ps1
```

Skrip ini: set zona waktu WIB, buat folder `C:\GudangAtm\{src,api,certs,backup,installer}`, memasang **.NET 8 SDK** dan **Git**.
**Tutup lalu buka lagi PowerShell (Administrator)** setelahnya agar PATH baru terbaca. Cek: `dotnet --version` (8.x) dan `git --version`.

> Kalau Git belum terpasang sehingga folder `deploy` belum ada di server, salin saja file `01-prasyarat.ps1` lewat RDP, jalankan, baru lanjut.

## 4. Ambil kode dan publish

```powershell
cd C:\GudangAtm\src\gudang-atm\deploy
.\02-ambil-dan-publish.ps1 -RepoUrl https://github.com/yohanesefendy74/atm.git
```

Untuk repo private, Git akan meminta login: username = akun GitHub, password = **Personal Access Token** (hak `repo` read). Simpan dengan
`git config --global credential.helper manager` (sudah bawaan Git for Windows).

Hasil publish ada di `C:\GudangAtm\api` (berisi `GudangAtm.Api.exe`, `wwwroot` dst). Skrip ini juga dipakai untuk **update** berikutnya
(tanpa `-RepoUrl`): ia mencadangkan versi lama ke `C:\GudangAtm\backup` (5 terakhir), menyalin versi baru, dan menjalankan ulang service.

## 5. Sertifikat HTTPS

Aplikasi **wajib HTTPS** (cookie `Secure`, HSTS). Pilih salah satu:

**A. Uji coba / internal — self-signed** (HP harus memasang sertifikatnya agar dipercaya):
```powershell
.\04-sertifikat-selfsigned.ps1 -Dns gudang.perusahaan.co.id,203.0.113.10   # nama domain dan/atau IP yang dipakai HP
```
Menghasilkan `C:\GudangAtm\certs\gudang.pfx` (server) dan `gudang.cer`. Di HP Android: salin `gudang.cer` →
Pengaturan › Keamanan › Enkripsi & kredensial › Instal sertifikat › Sertifikat CA. (Untuk APK, atur juga `network_security_config` bila perlu.)

**B. Produksi — sertifikat dari CA perusahaan atau Let's Encrypt** (butuh domain publik): minta file `.pfx` dari tim IT dan letakkan di
`C:\GudangAtm\certs\gudang.pfx`. Dengan Let's Encrypt bisa memakai **win-acme** (`wacs.exe`, https://www.win-acme.com): pilih opsi *Manual input* /
*Export to PFX*, buka port 80 sementara untuk validasi, lalu ekspor `.pfx` ke folder di atas. Perpanjangan: ulangi ekspor, jalankan ulang langkah 6, restart service.

## 6. Pasang sebagai Windows Service

```powershell
.\03-install-service.ps1 -AdminUsers ADMIN1,ADMIN2
```
Ganti `ADMIN1,ADMIN2` dengan `USER_CODE` yang boleh membuka CMS (selain user `OUSR.SUPERUSER = 'Y'`). Parameter lain punya nilai awal
(`-Server localhost -Database WORKSHOP_STAGING -SqlUser gudang_app -Port 5443`); ubah bila berbeda.

Skrip akan menanyakan **password login SQL** dan **password file .pfx** (tidak tampil di layar), lalu:
- membuat service `GudangAtmApi` (Automatic, restart otomatis bila crash),
- mengisi connection string, kunci JWT acak, dan pengaturan HTTPS di pengaturan service (registry; bukan file, bukan Git),
- membuka Windows Firewall port 5443,
- menjalankan service.

Mengganti password atau kunci di kemudian hari: jalankan skrip ini lagi (semua sesi login lama otomatis keluar karena kunci JWT baru).

## 7. Tes

Di server:
```powershell
.\05-cek-status.ps1
curl.exe -k https://localhost:5443/api/health        # harus {"ok":true}
```
Dari laptop/HP: buka `https://<domain-atau-ip>:5443/api/health` lalu `https://<domain-atau-ip>:5443` → login dengan `OUSR.USER_CODE`.
Urutan uji cepat: login Krani → buat Inbound uji → login Admin → CMS cek input. Pakai data uji, jangan data produksi.

Kalau gagal, lihat tabel masalah di bawah dan Event Viewer › Windows Logs › Application (sumber `GudangAtm.Api`).

## 8. Operasional

| Tugas | Perintah |
|---|---|
| Update ke versi terbaru | `git push` dari dev → di server `.\02-ambil-dan-publish.ps1` |
| Lihat status | `.\05-cek-status.ps1` |
| Start / stop / restart | `Start-Service GudangAtmApi` · `Stop-Service GudangAtmApi` · `Restart-Service GudangAtmApi` |
| Rollback | `Stop-Service GudangAtmApi; robocopy C:\GudangAtm\backup\api-<tanggal> C:\GudangAtm\api /MIR; Start-Service GudangAtmApi` |
| Cadangan database | Jadwalkan backup `WORKSHOP_STAGING` di SQL Server (bukan tugas server aplikasi) |
| Cadangan konfigurasi | Catat password di pengelola kata sandi tim. Konfigurasi service ada di registry `HKLM\SYSTEM\CurrentControlSet\Services\GudangAtmApi\Environment` |

## 9. Masalah yang sering muncul

| Gejala | Penyebab / solusi |
|---|---|
| Service berhenti sendiri saat start | Event Viewer: biasanya `Jwt:Key belum diisi` / connection string kosong → jalankan ulang `03-install-service.ps1` |
| `Cannot open server ... / timeout` di log | Server cloud tidak menjangkau SQL (VPN putus / firewall 1433). Tes `Test-NetConnection localhost -Port 1433` |
| `Login failed for user 'gudang_app'` | Password salah, atau login belum punya user di `WORKSHOP_STAGING` (langkah 2) |
| Browser: sertifikat tidak dipercaya | Memakai self-signed → pasang `gudang.cer` di perangkat, atau pakai sertifikat CA |
| Tidak bisa dibuka dari luar server | Security group cloud belum membuka 5443, atau Windows Firewall (`Get-NetFirewallRule -DisplayName 'Gudang ATM HTTPS'`) |
| Login berhasil tapi halaman kosong | Folder `wwwroot` tidak ikut tersalin → ulangi `02-ambil-dan-publish.ps1`, cek `C:\GudangAtm\api\wwwroot\index.html` |
| Kolom tidak ditemukan saat simpan dokumen | Nama kolom bertanda **ASUMSI** di `api/GudangAtm.Api/Sql.cs` belum cocok dengan tabel asli (lihat README bagian 1) |
| Terkunci setelah 5x salah password | Akun dikunci 15 menit (pengaturan `Security:LockMinutes`) |

## 10. Daftar periksa keamanan sebelum dipakai produksi

- [ ] Port 1433 SQL Server **tidak** terbuka ke internet; hanya VPN/privat.
- [ ] Memakai login `gudang_app`, bukan `sa`; hak sudah dipersempit.
- [ ] Sertifikat dari CA tepercaya (bukan self-signed) dan `TrustServerCertificate=False` setelah SQL Server memakai sertifikat valid.
- [ ] RDP 3389 dibatasi ke IP tertentu, akun Administrator memakai password kuat / MFA bila tersedia.
- [ ] `Security:AdminUsers` hanya berisi admin yang benar-benar perlu.
- [ ] Windows Update dan pembaruan .NET 8 rutin (bulanan).
- [ ] Rencana perubahan password `OUSR` dari Base64 ke hash (lihat README bagian "Yang masih perlu dilakukan tim IT").

## Timbangan dan printer di jaringan lokal gudang

Server cloud tidak bisa menjangkau timbangan RS232 dan printer TSC di gudang, dan browser HP Krani tidak boleh memanggil alat lokal
dari halaman HTTPS. Solusinya **PC Gateway** di gudang (koneksi keluar saja ke server). Panduan lengkap: [GATEWAY.md](GATEWAY.md).


## Saldo stok (WHS_Saldo)

Jalankan `database/saldo.sql` sekali (akun admin), beri hak ke `gudang_app` (contoh GRANT di akhir file), lalu isi awal:

```sql
EXEC dbo.usp_WHS_SaldoRebuild;
SELECT * FROM dbo.vw_WHS_SaldoSelisih;   -- harus kosong
```

Sesudah itu saldo diperbarui otomatis setiap Admin memposting dokumen di CMS. Pengecekan & bangun ulang juga tersedia di web Admin → Setup.
