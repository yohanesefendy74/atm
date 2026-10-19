<#
 Gudang ATM - langkah 3a (alternatif): buat sertifikat HTTPS self-signed -> C:\GudangAtm\certs\gudang.pfx
 Hanya untuk uji coba / jaringan internal. Untuk produksi sebaiknya sertifikat dari CA perusahaan atau Let's Encrypt
 (domain publik), lihat docs/DEPLOY-WINDOWS-SERVER-2019.md bagian 7.
 Contoh: .\04-sertifikat-selfsigned.ps1 -Dns gudang.contoh.co.id,203.0.113.10
#>
#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory = $true)][string[]]$Dns,     # nama domain dan/atau IP yang dipakai HP/browser untuk membuka server
    [int]$Years = 2
)
$ErrorActionPreference = 'Stop'
$pwd1 = Read-Host 'Password untuk file .pfx (catat, dipakai di langkah 3)' -AsSecureString
$cert = New-SelfSignedCertificate -Subject "CN=$($Dns[0])" -DnsName $Dns -KeyAlgorithm RSA -KeyLength 2048 `
    -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears($Years) -CertStoreLocation Cert:\LocalMachine\My `
    -KeyUsage DigitalSignature, KeyEncipherment -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1')
New-Item -ItemType Directory -Force -Path 'C:\GudangAtm\certs' | Out-Null
Export-PfxCertificate -Cert $cert -FilePath 'C:\GudangAtm\certs\gudang.pfx' -Password $pwd1 | Out-Null
Export-Certificate -Cert $cert -FilePath 'C:\GudangAtm\certs\gudang.cer' | Out-Null
Remove-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)"
Write-Host 'Dibuat: C:\GudangAtm\certs\gudang.pfx (untuk server) dan gudang.cer (pasang di HP/laptop supaya dipercaya).' -ForegroundColor Green
