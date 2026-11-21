# P0 acceptance test: 2 GB file over the relay with a hard-killed receiver
# AND a hard-killed sender in the middle, then SHA-256 comparison.
#   powershell -ExecutionPolicy Bypass -File scripts\p0_acceptance.ps1 [-SizeMB 2048] [-LimitMBps 150]
param(
    [int]$SizeMB = 2048,
    [int]$LimitMBps = 150,
    [int]$Port = 5940
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$gw = Join-Path $root "server\gateway"
$bin = Join-Path $gw "bin"
$work = Join-Path $root ".p0test"

Write-Host "== build"
Push-Location $gw; go build -o bin/ ./cmd/...; Pop-Location
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work, "$work\src", "$work\recv" | Out-Null

function Wait-Until([scriptblock]$cond, [int]$timeoutSec, [string]$what) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $cond)) {
        if ($sw.Elapsed.TotalSeconds -gt $timeoutSec) { throw "timeout waiting for $what" }
        Start-Sleep -Milliseconds 200
    }
}
function Start-Hub([string]$name, [string[]]$hubArgs) {
    Start-Process -FilePath "$bin\hubctl.exe" -ArgumentList $hubArgs -PassThru -NoNewWindow `
        -RedirectStandardOutput "$work\$name.out.log" -RedirectStandardError "$work\$name.err.log"
}
function Recv-Pct([string]$log) {
    # NTFS directory listings report stale sizes for open files, so read the
    # receiver's own progress output instead of probing the .part file.
    $m = Select-String -Path "$work\$log.out.log" -Pattern '\s(\d+\.\d)%' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($m) { [double]$m.Matches[0].Groups[1].Value } else { 0.0 }
}

$procs = @()
try {
    Write-Host "== gateway on :$Port"
    $env:SYNCHUB_USER = "p0user"; $env:SYNCHUB_PASSWORD = "p0-test-pass"
    $g = Start-Process -FilePath "$bin\gateway.exe" -ArgumentList "-addr", "127.0.0.1:$Port", "-data", "$work\devices.json" `
        -PassThru -NoNewWindow -RedirectStandardOutput "$work\gateway.out.log" -RedirectStandardError "$work\gateway.err.log"
    $procs += $g
    Wait-Until { try { (Invoke-WebRequest "http://127.0.0.1:$Port/healthz" -UseBasicParsing).StatusCode -eq 200 } catch { $false } } 10 "gateway"

    Write-Host "== register devices"
    $base = "http://127.0.0.1:$Port"
    & "$bin\hubctl.exe" -config "$work\win.json" register -server $base -name "Win-PC" -user p0user -pass p0-test-pass -recv "$work\recv-win"
    $code = (& "$bin\hubctl.exe" -config "$work\win.json" pair) -replace '.*code: (\d{6}).*', '$1'
    & "$bin\hubctl.exe" -config "$work\phone.json" register -server $base -name "Android-Phone" -code $code -recv "$work\recv"
    & "$bin\hubctl.exe" -config "$work\win.json" devices

    Write-Host "== generate $SizeMB MiB random file"
    $src = "$work\src\big_$SizeMB.bin"
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] (4MB)
    $fs = [IO.File]::OpenWrite($src)
    for ($i = 0; $i -lt ($SizeMB / 4); $i++) { $rng.GetBytes($buf); $fs.Write($buf, 0, $buf.Length) }
    $fs.Close()
    $srcHash = (Get-FileHash $src -Algorithm SHA256).Hash
    Write-Host "   source sha256 $srcHash"

    Write-Host "== start receiver daemon + sender"
    $recv = Start-Hub "recv1" @("-config", "$work\phone.json", "daemon"); $procs += $recv
    Start-Sleep 1
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $send = Start-Hub "send1" @("-config", "$work\win.json", "send", "-to", "Android", "-limit-mbps", "$LimitMBps", $src); $procs += $send

    Wait-Until { (Recv-Pct "recv1") -ge 30 } 300 "30% received"
    $p1 = Recv-Pct "recv1"
    Write-Host "== HARD KILL receiver at $p1%"
    Stop-Process -Id $recv.Id -Force
    Start-Sleep 3
    Write-Host "== restart receiver"
    $recv2 = Start-Hub "recv2" @("-config", "$work\phone.json", "daemon"); $procs += $recv2

    Wait-Until { (Recv-Pct "recv2") -ge 65 } 300 "65% received"
    $p2 = Recv-Pct "recv2"
    Write-Host "== HARD KILL sender at $p2%"
    Stop-Process -Id $send.Id -Force
    Start-Sleep 3
    $tid = (Select-String -Path "$work\send1.out.log" -Pattern 'queued (t[\w-]+)').Matches[0].Groups[1].Value
    Write-Host "== resume sender ($tid)"
    $resume = Start-Hub "send2" @("-config", "$work\win.json", "resume", $tid); $procs += $resume
    $resume.WaitForExit(600000) | Out-Null
    $sw.Stop()

    $dst = "$work\recv\big_$SizeMB.bin"
    Wait-Until { Test-Path $dst } 30 "final file"
    $dstHash = (Get-FileHash $dst -Algorithm SHA256).Hash
    Write-Host "   dest   sha256 $dstHash"
    Write-Host "== sender logs"
    Get-Content "$work\send1.err.log", "$work\send2.err.log" | Select-String -Pattern "resuming|session ended"
    Write-Host "== receiver logs"
    Get-Content "$work\recv1.err.log", "$work\recv2.err.log" | Select-String -Pattern "need|complete|failed"
    if ($dstHash -ne $srcHash) { throw "HASH MISMATCH" }
    if (Test-Path "$work\recv\.synchub-partial\$tid") { throw "partial state left behind" }
    if (Select-String -Path "$work\*.err.log" -Pattern "authentication failed" -Quiet) { throw "stale/corrupt chunk delivered across sessions" }
    # The resumed sessions must not have started from zero.
    $r2 = Select-String -Path "$work\send1.err.log" -Pattern 'resuming at (\d+\.\d)%' | Select-Object -Last 1
    $r3 = Select-String -Path "$work\send2.err.log" -Pattern 'resuming at (\d+\.\d)%' | Select-Object -Last 1
    $o2 = [double]$r2.Matches[0].Groups[1].Value; $o3 = [double]$r3.Matches[0].Groups[1].Value
    if ($o2 -lt 25 -or $o3 -lt 60) { throw "resume offsets too low ($o2% / $o3%) - not a real resume" }
    Write-Host ("`nP0 ACCEPTANCE PASSED: {0} MiB; receiver killed at {1}% -> resumed at {2}%; sender killed at {3}% -> resumed at {4}%; total {5:N1}s; sha256 identical" -f $SizeMB, $p1, $o2, $p2, $o3, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
}
finally {
    foreach ($p in $procs) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
}
