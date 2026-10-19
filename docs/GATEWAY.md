# Gateway timbangan RS232 dan printer TSC

HP Krani memakai browser dan server berada di cloud, jadi alat di LAN gudang diakses lewat **PC Gateway** yang selalu menyala di gudang.

```
HP Krani (browser) --HTTPS--> API cloud <--HTTPS (keluar saja)-- PC Gateway --RS232--> indikator timbangan
                                                                           --USB/TCP--> printer TSC
```

- Gateway hanya membuat koneksi **keluar** ke API (long-poll ~20 dtk). Tidak ada port yang dibuka di gudang, tidak perlu VPN.
- HP cukup punya internet; tidak harus satu WiFi dengan gudang.
- Timbang: `POST /api/alat/timbang {kodeTimbangan}` -> API membuat pekerjaan -> Gateway membaca COM -> `{beratKg, stabil}` (maks ~15 dtk).
- Cetak: `POST /api/alat/cetak {kodePrinter, qr, baris[], salinan}` -> API menyusun TSPL -> Gateway mengirim ke printer.
- Daftar alat gudang: `GET /api/alat?whs=KODE`. Bila Gateway tidak terlihat >60 dtk, API menolak dengan pesan jelas (krani bisa isi manual).
- Gateway menolak tanpa `X-Gateway-Id` + `X-Gateway-Key`. Di database hanya **hash SHA-256** key yang disimpan.

## Langkah pasang

1. **Database** (dari PC admin): jalankan `database/gateway.sql` setelah `gudang_atm_v2_struktur.sql`.
2. **Buat API key**: PowerShell contoh ada di akhir `gateway.sql`. Simpan key asli di password manager; hash masuk tabel `WHS_Gateway`.
   Daftarkan alat: `WHS_MasterTimbangan.GatewayId` dan `AlamatLan` (isi nama alat, mis. `COM3`), serta baris di `WHS_MasterPrinter`.
3. **Bangun paket** (di PC dengan .NET 8 SDK): `deploy\06-publish-gateway.ps1` -> `gateway-paket.zip`.
4. **PC gudang**: ekstrak zip, edit `appsettings.json` (`Api:BaseUrl`, `GatewayId`, daftar Timbangan dan Printer), lalu jalankan
   `07-install-gateway.ps1` sebagai Administrator (meminta API key, menyimpannya di registry service, bukan di file).
5. **Printer TSC**: pasang driver TSC di Windows lalu isi `NamaPrinter` persis seperti di Devices and Printers (mode `Windows`, kirim RAW).
   Untuk TSC jaringan: `Mode: "Tcp"`, `Host`, `Port: 9100`.
6. **Firewall PC gudang**: izinkan koneksi keluar HTTPS ke server. Tidak ada aturan masuk.

## Menentukan format data timbangan (belum diketahui)

Format tiap merek berbeda. Rekam dulu datanya (hentikan service dulu agar COM tidak terpakai):

```
.\GudangAtm.Gateway.exe --sniff COM3 9600 30
```

Letakkan beban lalu lihat keluarannya, mis. `ST,GS,   12.50,kg` atau `+0012500 g`. Kirim hasil rekaman ke pengembang untuk menyetel
`Pattern` (regex angka), `Satuan` (`kg`/`g`), dan `StabilPattern` (penanda stabil, mis. `ST`). Bila indikator tidak mengirim data terus-menerus,
isi `PerintahMinta` (mis. `P\r\n`); `--sniff COM3 9600 30 "P\r\n"` mengujinya. Parameter lain yang perlu dicoba bila data kacau: baud 2400/4800/9600/19200, Parity, DataBits.
Tanpa `StabilPattern`, hasil dianggap stabil bila `MinStabil` pembacaan berturut-turut sama.

Uji: `.\GudangAtm.Gateway.exe --tes-timbang TP-01` dan `--tes-cetak LP-01` (label uji dengan QR).

## Yang belum dibuat / perlu diputuskan

- Kode **belum dikompilasi dan belum diuji** (lingkungan penyusun tidak punya .NET SDK). Jalankan `dotnet build` dulu dan laporkan error bila ada.
- Tata letak label (`Tspl.Label` di `GatewayEndpoints.cs`) masih sederhana: QR + maksimal 5 baris, 203 dpi. Sesuaikan dengan label sebenarnya.
- Tombol "Ambil dari timbangan" dan "Cetak" di web/HP akan dipasang pada tahap registrasi & timbang (lihat `STATUS.md`); API-nya sudah ada.
- Catatan desain: Master Timbangan di desain masih menyebut "IP:port"; sekarang berarti nama alat di gateway (`COM3`).
- Satu PC gateway yang mati = timbang/cetak berhenti. Isi manual (dengan persetujuan Admin) tetap tersedia di desain. Pertimbangkan PC cadangan.
