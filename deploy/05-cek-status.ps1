<# Gudang ATM - cek cepat: service, SQL Server terjangkau, health API, 20 log terakhir. #>
param([string]$ServiceName = 'GudangAtmApi', [string]$Server = '172.28.88.1', [int]$Port = 5443)
Write-Host 'Service' -ForegroundColor Cyan
Get-Service $ServiceName | Format-Table Name, Status, StartType -AutoSize
Write-Host "SQL Server ${Server}:1433" -ForegroundColor Cyan
Test-NetConnection $Server -Port 1433 | Select-Object ComputerName, RemotePort, TcpTestSucceeded
Write-Host 'Health API (sertifikat self-signed -> pakai -k)' -ForegroundColor Cyan
curl.exe -sk "https://localhost:$Port/api/health"
Write-Host "`nLog (Event Viewer > Windows Logs > Application, sumber GudangAtm.Api)" -ForegroundColor Cyan
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'GudangAtm.Api' } -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, LevelDisplayName, @{ n = 'Pesan'; e = { $_.Message.Substring(0, [Math]::Min(180, $_.Message.Length)) } } | Format-Table -Wrap
