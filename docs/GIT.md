# Git: menyimpan dan mengunggah source

Repository lokal sudah dibuat (branch `main`, sudah ada commit awal). Untuk mengunggah ke GitHub / GitLab / Azure DevOps:

1. Buat repository **kosong** di layanan Git Anda (tanpa README/.gitignore awal). Disarankan **private**.
2. Di folder repo ini:
   ```
   git remote add origin https://github.com/yohanesefendy74/atm.git
   git push -u origin main
   ```
   Git meminta login: username + **Personal Access Token** (GitHub › Settings › Developer settings › Tokens, hak `repo`).
3. Di server cloud, pakai token terpisah yang hanya berhak **baca** (fine-grained token, `Contents: Read-only`) atau deploy key.

## Isi repository

```
api/GudangAtm.Api/   API ASP.NET Core 8 + web app hasil build (wwwroot)
web/                 sumber web app React (npm run build -> menimpa wwwroot)
app/                 aplikasi Android krani (Flutter)
database/            skrip SQL (web_security, relasi, v2 struktur)
design/              papan desain (*.dc.html) + canvas.json; buka lewat artifact desain
deploy/              skrip PowerShell setup server Windows 2019
docs/                panduan setup server, status, panduan Git
```

## Aturan yang dipakai

- **Jangan commit rahasia**: password SQL, kunci JWT, file `.pfx`. `.gitignore` sudah memblokir `*.pfx`, `certs/`, `.env`.
  File `appsettings*.json` hanya berisi placeholder `GANTI_*`.
- Alur cabang sederhana: `main` = yang berjalan di server. Kerjakan di cabang `fitur/<nama>`, gabungkan lewat pull request, lalu jalankan `deploy/02-ambil-dan-publish.ps1` di server.
- Pesan commit: bahasa Indonesia, ringkas, awali dengan area (`api:`, `web:`, `db:`, `app:`, `design:`, `deploy:`).
- Skrip SQL bersifat **idempotent** (aman diulang). Perubahan skema baru: tambahkan di file baru bernomor, mis. `database/20261101_nama-perubahan.sql`, jangan mengubah file yang sudah dijalankan di produksi.
