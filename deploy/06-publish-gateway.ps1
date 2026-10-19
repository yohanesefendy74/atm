<#
 Gudang ATM - Gateway, langkah 1: bangun paket untuk PC gudang.
 Jalankan di PC/server yang punya .NET 8 SDK dan repo ini. Hasil: gateway-paket.zip (self-contained, PC gudang
 TIDAK perlu memasang .NET). Salin zip itu ke PC gudang, ekstrak, lalu jalankan 07-install-gateway.ps1 di sana.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'gateway-paket'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
dotnet publish "$root\gateway\GudangAtm.Gateway\GudangAtm.Gateway.csproj" -c Release -r win-x64 --self-contained true -o $out
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish gagal' }
Copy-Item "$PSScriptRoot\07-install-gateway.ps1" $out
Compress-Archive -Path "$out\*" -DestinationPath "$root\gateway-paket.zip" -Force
Write-Host "Paket: $root\gateway-paket.zip" -ForegroundColor Green
