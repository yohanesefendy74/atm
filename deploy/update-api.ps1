<#
 Gudang ATM - SATU FILE untuk sinkron & menjalankan API sebagai Windows Service.

 Yang dilakukan:
   1. Cek prasyarat (git, .NET 8 SDK, sqlcmd bila -Sql).
   2. Sinkron kode dari GitHub (clone pertama kali, selanjutnya pull).
   3. (opsional -Sql) jalankan skrip database: gudang_atm_v2_tambahan.sql lalu saldo.sql.
   4. dotnet publish API (web sudah ikut di wwwroot).
   5. Stop service -> cadangkan versi lama -> salin versi baru -> start service.
      Bila service belum ada, otomatis menjalankan 03-install-service.ps1 (minta password SQL & .pfx sekali).
   6. Cek /api/health. Bila gagal, otomatis kembali ke versi sebelumnya.

 Cara pakai (PowerShell "Run as Administrator"):
   .\update-api.ps1                      # update biasa (lewati bila kode tidak berubah)
   .\update-api.ps1 -Sql                 # update + jalankan skrip database (login Windows / -SqlUser)
   .\update-api.ps1 -Paksa               # publish ulang walau kode tidak berubah
   .\update-api.ps1 -Restart             # hanya restart service + cek health
   .\update-api.ps1 -Rollback            # kembali ke cadangan terakhir
   .\update-api.ps1 -Diagnosa            # jalankan versi gagal terakhir di konsol 20 detik untuk melihat error start-up

 Rahasia (connection string, JWT, password sertifikat) TIDAK ada di file ini; tersimpan di pengaturan service (langkah 03).
#>
#Requires -RunAsAdministrator
param(
    [string]$RepoUrl = 'https://github.com/yohanesefendy74/atm.git',
    [string]$Branch = 'main',
    [string]$ServiceName = 'GudangAtmApi',
    [int]$Port = 5443,
    [switch]$Sql,                         # jalankan skrip database
    [string]$SqlServer = 'localhost',
    [string]$Database = 'WORKSHOP_STAGING',
    [string]$SqlUser = '',                # kosong = Windows Authentication; isi (mis. login admin DB) untuk SQL login, password ditanya
    [switch]$Paksa,
    [switch]$Restart,
    [switch]$Rollback,
    [switch]$Diagnosa
)
$ErrorActionPreference = 'Stop'
$root   = 'C:\GudangAtm'
$src    = "$root\src\gudang-atm"
$out    = "$root\api"
$backup = "$root\backup"
$log    = "$root\logs\update-$(Get-Date -Format yyyyMMdd-HHmmss).log"
New-Item -ItemType Directory -Force -Path "$root\logs", $backup | Out-Null
Start-Transcript -Path $log -Append | Out-Null

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

function Stop-Api {
    $s = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Stopped') {
        Stop-Service $ServiceName -Force
        $s.WaitForStatus('Stopped', '00:00:30')
    }
    # pastikan file tidak terkunci proses lama
    Get-Process GudangAtm.Api -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-Api {
    Start-Service $ServiceName
    (Get-Service $ServiceName).WaitForStatus('Running', '00:00:30')
}

function Test-Health([int]$Detik = 60) {
    # sertifikat bisa self-signed: pakai curl.exe -k (ada di Windows Server 2019)
    $batas = (Get-Date).AddSeconds($Detik)
    while ((Get-Date) -lt $batas) {
        $r = & curl.exe -sk -o NUL -w '%{http_code}' "https://localhost:$Port/api/health"
        if ($r -eq '200') { return $true }
        Start-Sleep 3
    }
    return $false
}

function Show-Events {
    try {
        $ev = Get-WinEvent -LogName Application -MaxEvents 400 -ErrorAction Stop |
            Where-Object { $_.ProviderName -in '.NET Runtime', 'Application Error' -or $_.ProviderName -like '*GudangAtm*' -or $_.Message -like '*GudangAtm*' } |
            Where-Object { $_.TimeCreated -gt (Get-Date).AddMinutes(-15) } | Select-Object -First 6
        if ($ev) {
            Warn 'Event Viewer (15 menit terakhir):'
            $ev | ForEach-Object { Write-Host "---- $($_.TimeCreated) $($_.ProviderName) $($_.LevelDisplayName)" -ForegroundColor DarkYellow; Write-Host ($_.Message.Substring(0, [Math]::Min(1500, $_.Message.Length))) }
        } else { Warn 'Tidak ada event GudangAtm / .NET Runtime di 15 menit terakhir.' }
    } catch { Warn "Event Viewer tidak bisa dibaca: $($_.Exception.Message)" }
}

function Copy-Folder($from, $to) {
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    robocopy $from $to /MIR /NFL /NDL /NJH /NJS /R:3 /W:2 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $from -> $to gagal (kode $LASTEXITCODE)" }
}

function Restore-Last {
    $last = Get-ChildItem $backup -Directory -Filter 'api-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $last) { throw 'Tidak ada cadangan untuk rollback' }
    Info "Rollback ke $($last.Name)"
    Stop-Api
    Copy-Folder $last.FullName $out
    Start-Api
    if (Test-Health 60) { Ok 'Versi sebelumnya berjalan lagi.' } else { Warn 'Health masih gagal setelah rollback. Cek 05-cek-status.ps1 / Event Viewer.' }
}

try {
    # ---------------------------------------------------------------- mode singkat
    if ($Rollback) { Restore-Last; return }
    if ($Diagnosa) {
        # Jalankan exe di konsol dengan environment service (rahasia tidak ditampilkan), tampilkan output start-up
        $dir = if (Test-Path "$root\gagal\GudangAtm.Api.exe") { "$root\gagal" } else { $out }
        Info "Diagnosa: menjalankan $dir\GudangAtm.Api.exe selama 20 detik"
        $reg = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -ErrorAction Stop).Environment
        foreach ($e in $reg) { $kv = $e -split '=', 2; if ($kv.Count -eq 2) { Set-Item -Path "env:$($kv[0])" -Value $kv[1] } }
        $env:Logging__LogLevel__Default = 'Information'
        Stop-Api
        $o = "$root\logs\diag-out.txt"; $er = "$root\logs\diag-err.txt"
        $p = Start-Process "$dir\GudangAtm.Api.exe" -WorkingDirectory $dir -PassThru -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $er
        Start-Sleep 12
        $code = & curl.exe -sk -o "$root\logs\diag-health.txt" -w '%{http_code}' "https://localhost:$Port/api/health"
        Start-Sleep 3
        if (-not $p.HasExited) { Stop-Process $p.Id -Force } else { Warn "Proses berhenti sendiri (exit code $($p.ExitCode))" }
        Start-Sleep 2
        Write-Host "Health: HTTP $code" -ForegroundColor Cyan
        Write-Host '---- output ----' -ForegroundColor Cyan
        # sembunyikan password / kunci bila ada di output
        foreach ($f in $o, $er) { if (Test-Path $f) { Get-Content $f -Tail 80 | ForEach-Object { $_ -replace '(?i)(password|pwd|key)=[^;\s]+', '$1=***' } } }
        Info 'Menjalankan service lagi'
        Start-Api
        if (Test-Health 60) { Ok 'Service berjalan (versi yang terpasang).' } else { Warn 'Service belum sehat.'; Show-Events }
        return
    }
    if ($Restart) {
        Info "Restart service $ServiceName"
        Stop-Api; Start-Api
        if (Test-Health 60) { Ok "Sehat: https://localhost:$Port/api/health" } else { Warn 'Health gagal. Jalankan 05-cek-status.ps1.' }
        return
    }

    # ---------------------------------------------------------------- 1. prasyarat
    Info 'Cek prasyarat'
    foreach ($c in 'git', 'dotnet') { if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "$c belum terpasang. Jalankan 01-prasyarat.ps1 dulu." } }
    if (-not ((& dotnet --list-sdks) -match '^8\.')) { throw '.NET 8 SDK belum terpasang. Jalankan 01-prasyarat.ps1 dulu.' }
    if ($Sql -and -not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { throw 'sqlcmd tidak ditemukan (pasang SQL Server Command Line Utilities) atau jalankan tanpa -Sql.' }
    Ok 'git, dotnet OK'

    # ---------------------------------------------------------------- 2. sinkron kode
    Info "Sinkron kode ($Branch)"
    if (-not (Test-Path "$src\.git")) {
        New-Item -ItemType Directory -Force -Path (Split-Path $src) | Out-Null
        git clone --branch $Branch $RepoUrl $src
        if ($LASTEXITCODE -ne 0) { throw 'git clone gagal' }
        $lama = ''
    } else {
        $lama = (git -C $src rev-parse --short HEAD)
        git -C $src fetch origin $Branch --prune
        if ($LASTEXITCODE -ne 0) { throw 'git fetch gagal (cek koneksi / akses GitHub)' }
        git -C $src checkout $Branch
        git -C $src reset --hard "origin/$Branch"     # folder src hanya salinan baca; perubahan lokal dibuang
        if ($LASTEXITCODE -ne 0) { throw 'git reset gagal' }
    }
    $baru = (git -C $src rev-parse --short HEAD)
    Ok "Versi: $(if ($lama) { "$lama -> " })$baru"
    if ($lama -and $lama -ne $baru) { git -C $src log --oneline "$lama..$baru" | Select-Object -First 15 | ForEach-Object { Write-Host "      $_" } }
    $berubah = (-not $lama) -or ($lama -ne $baru)

    # ---------------------------------------------------------------- 3. database (opsional)
    if ($Sql) {
        Info "Skrip database ke $SqlServer / $Database"
        $auth = @('-E')
        if ($SqlUser) {
            $p = Read-Host "Password SQL '$SqlUser'" -AsSecureString
            $env:SQLCMDPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p))
            $auth = @('-U', $SqlUser)
        }
        try {
            foreach ($f in 'gudang_atm_v2_tambahan.sql', 'saldo.sql') {
                $path = "$src\database\$f"
                if (-not (Test-Path $path)) { Warn "$f tidak ada, dilewati"; continue }
                Write-Host "    $f ..." -NoNewline
                & sqlcmd -S $SqlServer -d $Database @auth -C -b -I -i $path -o "$root\logs\sql-$f.log"
                if ($LASTEXITCODE -ne 0) { Write-Host ''; throw "Skrip $f gagal. Lihat $root\logs\sql-$f.log" }
                Write-Host ' OK' -ForegroundColor Green
            }
        } finally { Remove-Item Env:\SQLCMDPASSWORD -ErrorAction SilentlyContinue }
        Warn 'Ingat: GRANT tabel baru ke gudang_app (baris GRANT di akhir tambahan.sql) bila belum.'
    }

    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if (-not $berubah -and -not $Paksa -and $svc -and (Test-Path "$out\GudangAtm.Api.exe")) {
        Ok 'Kode tidak berubah, publish dilewati (pakai -Paksa untuk publish ulang).'
        if ($svc.Status -ne 'Running') { Start-Api }
        if (Test-Health 30) { Ok "API sehat: https://localhost:$Port/api/health" } else { Warn 'Health gagal. Jalankan 05-cek-status.ps1.' }
        return
    }

    # ---------------------------------------------------------------- 4. publish
    Info 'dotnet publish'
    $tmp = "$root\publish-$baru"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    dotnet publish "$src\api\GudangAtm.Api\GudangAtm.Api.csproj" -c Release -r win-x64 --self-contained false -o $tmp --nologo -v q
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish gagal (versi yang berjalan tidak diubah)' }
    if (-not (Test-Path "$tmp\wwwroot\index.html")) { Warn 'wwwroot\index.html tidak ada di hasil publish (web tidak ikut?)' }
    Ok "Hasil publish: $tmp"

    # ---------------------------------------------------------------- cek sertifikat sebelum ganti versi
    $certPath = $null
    $envSvc = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -ErrorAction SilentlyContinue).Environment
    if ($envSvc) { $certPath = ($envSvc | Where-Object { $_ -like 'Kestrel__Endpoints__Https__Certificate__Path=*' } | Select-Object -First 1) -replace '^[^=]+=', '' }
    if (-not $certPath -and (Test-Path "$out\appsettings.Production.json")) {
        try { $certPath = (Get-Content "$out\appsettings.Production.json" -Raw | ConvertFrom-Json).Kestrel.Endpoints.Https.Certificate.Path } catch { }
    }
    if ($certPath) {
        $full = if ([IO.Path]::IsPathRooted($certPath)) { $certPath } else { Join-Path $out $certPath }
        if (Test-Path $full) { Ok "Sertifikat: $full" } else { Warn "Sertifikat $full TIDAK ditemukan; API akan gagal start." }
    }

    # ---------------------------------------------------------------- 5. ganti versi + jalankan service
    Info 'Pasang versi baru'
    Stop-Api
    if (Test-Path "$out\GudangAtm.Api.dll") {
        $bk = "$backup\api-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Folder $out $bk
        Get-ChildItem $backup -Directory -Filter 'api-*' | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Recurse -Force
        Ok "Cadangan: $bk"
    }
    # File khusus server di folder api TIDAK boleh tertimpa / terhapus: sertifikat (certs\, *.pfx), konfigurasi lokal
    # (appsettings.Production.json berisi path & password server), folder logs / unduh. Robocopy /XD /XF = tidak disalin & tidak dihapus.
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    robocopy $tmp $out /MIR /NFL /NDL /NJH /NJS /R:3 /W:2 /XD certs logs unduh /XF appsettings.Production.json appsettings.Local.json *.pfx *.pem *.key | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy publish -> $out gagal (kode $LASTEXITCODE)" }
    if (-not (Test-Path "$out\appsettings.Production.json") -and (Test-Path "$tmp\appsettings.Production.json")) {
        Copy-Item "$tmp\appsettings.Production.json" "$out\appsettings.Production.json"   # hanya bila server belum punya
    }
    Remove-Item $tmp -Recurse -Force
    Set-Content -Path "$out\VERSION.txt" -Value "$baru $(Get-Date -Format s)"

    if (-not $svc) {
        Warn "Service $ServiceName belum ada: menjalankan 03-install-service.ps1 (isi password SQL & .pfx)"
        & "$src\deploy\03-install-service.ps1" -ServiceName $ServiceName -Port $Port
    } else {
        Start-Api
    }

    # ---------------------------------------------------------------- 6. cek kesehatan
    Info 'Cek /api/health'
    if (Test-Health 90) {
        Ok "API berjalan versi $baru : https://localhost:$Port/api/health"
        Get-Service $ServiceName | Format-Table Name, Status, StartType -AutoSize
    } else {
        Warn 'Health gagal dalam 90 detik.'
        Show-Events
        Copy-Folder $out "$root\gagal"     # simpan versi gagal untuk -Diagnosa
        if ($svc -and (Get-ChildItem $backup -Directory -Filter 'api-*' -ErrorAction SilentlyContinue)) { Restore-Last }
        throw 'Versi baru tidak sehat (sudah dikembalikan ke versi sebelumnya). Jalankan: .\update-api.ps1 -Diagnosa  lalu kirim hasilnya.'
    }
}
catch {
    Write-Host "GAGAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $log" -ForegroundColor Yellow
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
