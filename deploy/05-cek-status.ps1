<# Gudang ATM - cek cepat: service, SQL Server terjangkau, health API, 20 log terakhir. #>
param([string]$ServiceName = 'GudangAtmApi', [string]$Server = '172.28.88.1', [int]$Port = 5443)
Write-Host 'Service' -ForegroundColor Cyan
Get-Service $ServiceName | Format-Table Name, Status, StartType -AutoSize
Write-Host "SQL Server ${Server}:1433" -ForegroundColor Cyan
Test-NetConnection $Server -Port 1433 | Select-Object ComputerName, RemotePort, TcpTestSucceeded
Write-Host 'Health API (sertifikat self-signed -> pakai -k)' -ForegroundColor Cyan
curl.exe -sk "https://localhost:$Port/api/health"
Write-Host "`nLog (Event Viewer > Windows Logs > Application, sumber GudangAtm.Api)" -ForegroundColor Cyan
try {
    $ev = Get-WinEvent -LogName Application -MaxEvents 300 -ErrorAction Stop |
        Where-Object { $_.ProviderName -like '*GudangAtm*' -or $_.Message -like '*GudangAtm*' } | Select-Object -First 20
    if ($ev) {
        $ev | Select-Object TimeCreated, LevelDisplayName, @{ n = 'Pesan'; e = { $_.Message.Substring(0, [Math]::Min(180, $_.Message.Length)) } } | Format-Table -Wrap
    } else { Write-Host '(tidak ada log GudangAtm di 300 event Application terakhir)' }
} catch { Write-Host "Log tidak bisa dibaca: $($_.Exception.Message). Buka Event Viewer > Application secara manual." -ForegroundColor Yellow }
