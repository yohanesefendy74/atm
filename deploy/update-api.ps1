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
    [switch]$Rollback
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

    # ---------------------------------------------------------------- 5. ganti versi + jalankan service
    Info 'Pasang versi baru'
    Stop-Api
    if (Test-Path "$out\GudangAtm.Api.dll") {
        $bk = "$backup\api-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Folder $out $bk
        Get-ChildItem $backup -Directory -Filter 'api-*' | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Recurse -Force
        Ok "Cadangan: $bk"
    }
    Copy-Folder $tmp $out
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
        if ($svc -and (Get-ChildItem $backup -Directory -Filter 'api-*' -ErrorAction SilentlyContinue)) { Restore-Last }
        throw 'Versi baru tidak sehat. Cek Event Viewer > Application (GudangAtm.Api) atau jalankan 05-cek-status.ps1.'
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
