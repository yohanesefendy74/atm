<#
 Gudang ATM - Gateway, langkah 2: pasang sebagai Windows Service di PC gudang (Windows 10/11 atau Server).
 Jalankan dari folder hasil ekstrak gateway-paket.zip, sebagai Administrator.
 Sebelumnya: edit appsettings.json (Api:BaseUrl, GatewayId, daftar Timbangan/Printer).
 API key TIDAK disimpan di file; masuk ke registry service (Api__Key), sama seperti rahasia API.
#>
#Requires -RunAsAdministrator
param(
    [string]$ServiceName = 'GudangAtmGateway',
    [string]$Folder = 'C:\GudangAtmGateway'
)
$ErrorActionPreference = 'Stop'
function Plain([securestring]$s) { [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) }

if (-not (Test-Path "$PSScriptRoot\GudangAtm.Gateway.exe")) { throw 'Jalankan dari folder hasil ekstrak gateway-paket.zip' }
$key = Plain (Read-Host 'API key gateway (dari admin)' -AsSecureString)
if ($key.Length -lt 20) { throw 'API key terlalu pendek' }

if ((Get-Service $ServiceName -ErrorAction SilentlyContinue)) { Stop-Service $ServiceName -Force; Start-Sleep 2 }
New-Item -ItemType Directory -Force $Folder | Out-Null
if ((Resolve-Path $PSScriptRoot).Path -ne (Resolve-Path $Folder).Path) {
    # jangan menimpa appsettings.json yang sudah disetel di PC ini
    $keep = Test-Path "$Folder\appsettings.json"
    if ($keep) { Copy-Item "$PSScriptRoot\*" $Folder -Recurse -Force -Exclude 'appsettings.json' }
    else { Copy-Item "$PSScriptRoot\*" $Folder -Recurse -Force }
}

if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) {
    New-Service -Name $ServiceName -DisplayName 'Gudang ATM Gateway' -BinaryPathName "`"$Folder\GudangAtm.Gateway.exe`"" `
        -StartupType Automatic -Description 'Jembatan timbangan RS232 dan printer TSC ke server Gudang ATM' | Out-Null
}
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name Environment -Value @("Api__Key=$key") -Type MultiString
sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/30000/restart/60000 | Out-Null
Start-Service $ServiceName
Start-Sleep 3
Get-Service $ServiceName | Format-Table Name, Status, StartType -AutoSize
Write-Host 'Lihat log: Event Viewer > Windows Logs > Application (sumber GudangAtmGateway).' -ForegroundColor Green
Write-Host 'Tes tanpa service: hentikan service dulu, lalu  .\GudangAtm.Gateway.exe --sniff COM3 9600  atau --tes-timbang TP-01 / --tes-cetak LP-01' -ForegroundColor Yellow
