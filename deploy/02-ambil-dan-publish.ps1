<#
 Gudang ATM - langkah 2 (dan setiap update): ambil kode dari Git lalu publish API ke C:\GudangAtm\api.
 Contoh pertama kali : .\02-ambil-dan-publish.ps1 -RepoUrl https://github.com/<akun>/gudang-atm.git
 Contoh update       : .\02-ambil-dan-publish.ps1
 Rahasia (connection string, JWT, password sertifikat) TIDAK ikut: ada di pengaturan service (langkah 3).
#>
#Requires -RunAsAdministrator
param(
    [string]$RepoUrl = '',
    [string]$Branch = 'main',
    [string]$ServiceName = 'GudangAtmApi'
)
$ErrorActionPreference = 'Stop'
$src = 'C:\GudangAtm\src\gudang-atm'
$out = 'C:\GudangAtm\api'

if (-not (Test-Path "$src\.git")) {
    if (-not $RepoUrl) { throw 'Pertama kali: isi -RepoUrl (URL repository Git).' }
    git clone --branch $Branch $RepoUrl $src
} else {
    git -C $src fetch --all --prune
    git -C $src checkout $Branch
    git -C $src pull --ff-only
}
$ver = (git -C $src rev-parse --short HEAD)
Write-Host "Versi kode: $ver" -ForegroundColor Cyan

$tmp = "C:\GudangAtm\publish-$ver"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
dotnet publish "$src\api\GudangAtm.Api\GudangAtm.Api.csproj" -c Release -r win-x64 --self-contained false -o $tmp
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish gagal' }

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service $ServiceName -Force; $svc.WaitForStatus('Stopped', '00:00:30') }

# cadangkan versi lama (maks 5 terakhir)
if (Test-Path "$out\GudangAtm.Api.dll") {
    $bk = "C:\GudangAtm\backup\api-$(Get-Date -Format yyyyMMdd-HHmmss)"
    robocopy $out $bk /MIR /NFL /NDL /NJH /NJS | Out-Null
    Get-ChildItem 'C:\GudangAtm\backup' -Directory -Filter 'api-*' | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $out | Out-Null
robocopy $tmp $out /MIR /NFL /NDL /NJH /NJS | Out-Null   # robocopy: kode 0-7 = sukses
if ($LASTEXITCODE -ge 8) { throw "robocopy gagal (kode $LASTEXITCODE)" }
Remove-Item $tmp -Recurse -Force

if ($svc) { Start-Service $ServiceName; Write-Host "Service $ServiceName dijalankan ulang." -ForegroundColor Green }
else { Write-Host 'Service belum ada. Lanjut ke 03-install-service.ps1' -ForegroundColor Yellow }
