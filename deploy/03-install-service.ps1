<#
 Gudang ATM - langkah 3: pasang API sebagai Windows Service + isi rahasia + buka firewall.
 Jalankan SETELAH 02 dan setelah file sertifikat C:\GudangAtm\certs\gudang.pfx ada (lihat 04-sertifikat-selfsigned.ps1).
 Rahasia disimpan di registry service (HKLM\SYSTEM\CurrentControlSet\Services\<nama>\Environment),
 bukan di file dan bukan di Git. Ulangi skrip ini bila ingin mengganti password/kunci.
#>
#Requires -RunAsAdministrator
param(
    [string]$ServiceName = 'GudangAtmApi',
    [string]$Server = '194.233.84.97',          # SQL Server (harus terjangkau dari server cloud)
    [string]$Database = 'WORKSHOP_STAGING',
    [string]$SqlUser = 'gudang_app',          # login SQL khusus aplikasi, BUKAN sa
    [string[]]$AdminUsers = @(),              # USER_CODE yang boleh membuka CMS selain OUSR.SUPERUSER = 'Y'
    [int]$Port = 5443,
    [string]$PfxPath = 'C:\GudangAtm\certs\gudang.pfx'
)
$ErrorActionPreference = 'Stop'
function Plain([securestring]$s) { [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) }

if (-not (Test-Path 'C:\GudangAtm\api\GudangAtm.Api.exe')) { throw 'Jalankan 02-ambil-dan-publish.ps1 dulu.' }
if (-not (Test-Path $PfxPath)) { throw "Sertifikat $PfxPath tidak ada. Jalankan 04-sertifikat-selfsigned.ps1 atau salin .pfx dari CA Anda." }

$sqlPwd = Plain (Read-Host "Password login SQL '$SqlUser'" -AsSecureString)
$pfxPwd = Plain (Read-Host 'Password file .pfx' -AsSecureString)
$bytes = New-Object byte[] 48
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$jwt = [Convert]::ToBase64String($bytes)     # 64 karakter acak, dibuat otomatis

$conn = "Server=$Server;Database=$Database;User Id=$SqlUser;Password=$sqlPwd;Encrypt=True;TrustServerCertificate=True"
$envs = @(
    "ASPNETCORE_ENVIRONMENT=Production",
    "ConnectionStrings__Gudang=$conn",
    "Jwt__Key=$jwt",
    "Kestrel__Endpoints__Https__Url=https://0.0.0.0:$Port",
    "Kestrel__Endpoints__Https__Certificate__Path=$PfxPath",
    "Kestrel__Endpoints__Https__Certificate__Password=$pfxPwd"
)
for ($i = 0; $i -lt $AdminUsers.Count; $i++) { $envs += "Security__AdminUsers__$i=$($AdminUsers[$i])" }

if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) {
    New-Service -Name $ServiceName -DisplayName 'Gudang ATM API' -BinaryPathName '"C:\GudangAtm\api\GudangAtm.Api.exe"' `
        -StartupType Automatic -Description 'REST API + web app Gudang ATM (Kestrel, HTTPS)' | Out-Null
}
$key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
Set-ItemProperty -Path $key -Name Environment -Value $envs -Type MultiString
sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/30000/restart/60000 | Out-Null

# hak baca folder aplikasi & sertifikat untuk akun service (LocalSystem default; ganti bila memakai akun khusus)
icacls 'C:\GudangAtm\certs' /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null

if (-not (Get-NetFirewallRule -DisplayName 'Gudang ATM HTTPS' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'Gudang ATM HTTPS' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
}
Restart-Service $ServiceName -ErrorAction SilentlyContinue
if ((Get-Service $ServiceName).Status -ne 'Running') { Start-Service $ServiceName }
Start-Sleep 3
Get-Service $ServiceName | Format-Table Name, Status, StartType -AutoSize
Write-Host "Tes lokal : https://localhost:$Port/api/health  (atau: curl.exe -k https://localhost:$Port/api/health)" -ForegroundColor Green
Write-Host 'Batasi sumber IP di Windows Firewall / Security Group cloud ke jaringan kantor/VPN saja.' -ForegroundColor Yellow
