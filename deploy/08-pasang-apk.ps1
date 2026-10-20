<#
 Gudang ATM - memasang APK untuk diunduh krani lewat browser HP (tanpa Play Store).
 Pemakaian:  .\08-pasang-apk.ps1 -Apk C:\Users\...\app-release.apk -Build 12
   -Build = nomor run GitHub Actions yang membuat APK (terlihat di nama run / artifact). Aplikasi lama memberi tahu bila build di server lebih baru.
 Hasil: http://<server>:5000/unduh/ (atau https sesuai API) berisi halaman unduh + gudang-atm.apk + versi.json
#>
param(
  [Parameter(Mandatory)][string]$Apk,
  [Parameter(Mandatory)][int]$Build,
  [string]$Folder = 'C:\GudangAtm\unduh'
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Apk)) { throw "File tidak ditemukan: $Apk" }
New-Item -ItemType Directory -Force $Folder | Out-Null
Copy-Item $Apk "$Folder\gudang-atm.apk" -Force
$json = @{ build = $Build; tanggal = (Get-Date).ToString('yyyy-MM-dd HH:mm') } | ConvertTo-Json
Set-Content "$Folder\versi.json" $json -Encoding UTF8
$html = @"
<!doctype html><html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Unduh Gudang ATM</title>
<style>body{font-family:system-ui,sans-serif;margin:24px;max-width:480px}a.b{display:block;background:#19037B;color:#fff;padding:16px;border-radius:12px;text-align:center;text-decoration:none;font-weight:700;margin:16px 0}small{color:#555}</style></head>
<body><h1>Gudang ATM</h1><p>Aplikasi krani (Android). Versi build $Build.</p>
<a class="b" href="gudang-atm.apk">Unduh aplikasi Android (.apk)</a>
<small>Setelah terunduh, buka file-nya. Bila diminta, izinkan "Pasang dari sumber ini" untuk browser Anda. Update: pasang file baru di atas aplikasi lama (data login tetap).</small>
<p><small>iPhone: tidak lewat halaman ini (butuh TestFlight / Apple Developer Program).</small></p></body></html>
"@
Set-Content "$Folder\index.html" $html -Encoding UTF8
Write-Host "Terpasang di $Folder. Buka /unduh/ dari HP (WiFi gudang)."
