# Aplikasi mobile Krani (Android APK dan iPhone)

Kode: `app/` (Flutter). Build otomatis lewat GitHub Actions (`.github/workflows/build-apk.yml`).

## Android (APK)
1. GitHub > tab **Actions** > "Build aplikasi Gudang ATM" > Run workflow (atau otomatis tiap push ke `app/`).
2. Unduh artifact `gudang-atm-apk` > `app-release.apk`, kirim ke HP Android, izinkan "pasang dari sumber tidak dikenal".
3. Pengaturan aplikasi: isi alamat server, pilih printer Bluetooth (pair dulu di Android), cari timbangan Bluetooth.

## iPhone
- Job `ios` hanya membuktikan kode bisa dikompilasi (tanpa tanda tangan). **Tidak bisa dipasang** ke iPhone.
- Untuk dipasang: Apple Developer Program (berbayar, per tahun), sertifikat dan provisioning profile, lalu distribusi lewat **TestFlight**
  (paling mudah untuk tim internal) atau Ad Hoc (maks 100 perangkat). Butuh Mac atau layanan CI macOS dengan tanda tangan; siapkan akun Apple Developer dulu.
- iPhone **tidak** bisa Bluetooth klasik (SPP) ke printer/modul biasa. Hanya BLE. Karena itu di iPhone: timbangan lewat BLE (ESP32), label lewat **PDF + AirPrint/dialog cetak** (atau lewat PC Gateway).

## Pembacaan timbangan
ESP32 memancarkan BLE (Nordic UART) dan TCP (untuk Gateway) sekaligus. Aplikasi mencari perangkat dengan servis itu (`Pengaturan > Timbangan Bluetooth > Cari > Tes baca`).
Pola angka (`BleScale.pattern`, `gram`, `stabilPattern` di `app/lib/scale_ble.dart`) disetel dari hasil rekaman `--sniff`, sama dengan Gateway.
Penyimpanan berat ke server (sumber `BLE`, teks mentah) dipasang pada tahap registrasi & timbang; server perlu kolom sumber baru
(`WHS_Timbang.Sumber` sekarang hanya LAN/MANUAL).

## Cetak label
Urutan: printer Bluetooth Android yang dipilih (TSPL) > bila tidak ada/gagal, atau iPhone: label PDF dan dialog cetak sistem.

## Belum diuji
Kode ini belum dikompilasi dan belum diuji di perangkat (tidak ada Flutter SDK di lingkungan penyusun). Jalankan workflow, lalu laporkan error build bila ada.
