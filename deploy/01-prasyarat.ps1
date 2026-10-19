<#
 Gudang ATM - langkah 1: siapkan Windows Server 2019 (jalankan sebagai Administrator).
 Memasang: .NET 8 SDK, Git for Windows. Membuat folder C:\GudangAtm\*, zona waktu WIB.
 Perlu internet dari server (download dari dot.net dan github.com).
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # Server 2019 default belum TLS1.2 untuk PowerShell 5.1

Write-Host '== Zona waktu WIB ==' -ForegroundColor Cyan
tzutil /s 'SE Asia Standard Time'

Write-Host '== Folder ==' -ForegroundColor Cyan
foreach ($d in 'C:\GudangAtm', 'C:\GudangAtm\src', 'C:\GudangAtm\api', 'C:\GudangAtm\certs', 'C:\GudangAtm\backup', 'C:\GudangAtm\installer') {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

Write-Host '== .NET 8 SDK ==' -ForegroundColor Cyan
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue) -or -not ((dotnet --list-sdks) -match '^8\.')) {
    $s = 'C:\GudangAtm\installer\dotnet-install.ps1'
    Invoke-WebRequest -UseBasicParsing 'https://dot.net/v1/dotnet-install.ps1' -OutFile $s
    & $s -Channel 8.0 -InstallDir 'C:\Program Files\dotnet'
    $mp = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($mp -notlike '*C:\Program Files\dotnet*') {
        [Environment]::SetEnvironmentVariable('Path', $mp + ';C:\Program Files\dotnet', 'Machine')
    }
    $env:Path += ';C:\Program Files\dotnet'
}
dotnet --list-sdks

Write-Host '== Git for Windows ==' -ForegroundColor Cyan
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    # Cek versi terbaru di https://git-scm.com/download/win bila link di bawah sudah tidak ada
    $g = 'C:\GudangAtm\installer\git-setup.exe'
    Invoke-WebRequest -UseBasicParsing 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe' -OutFile $g
    Start-Process $g -ArgumentList '/VERYSILENT', '/NORESTART' -Wait
    $env:Path += ';C:\Program Files\Git\cmd'
}
git --version

Write-Host "`nSelesai. Tutup lalu buka lagi PowerShell (Administrator) supaya PATH baru terbaca." -ForegroundColor Green
