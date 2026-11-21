# SyncHub single-tray handover for the NEXT run on the Windows PC.
# Default is backup only. -Takeover requires -Confirm.
# This script never deletes SyncClipboard.exe, SyncClipboard.json, history, or received files.
param(
    [switch]$BackupOnly,
    [switch]$Trial,
    [switch]$AbortTrial,
    [switch]$Takeover,
    [switch]$Confirm,
    [switch]$Rollback,
    [switch]$StopOfficial,
    [string]$BackupDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TaskName = "\SyncClipboardStartup"
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$OfficialValue = "SyncClipboard"
$OfficialImage = "SyncClipboard.exe"

function Write-Step([string]$Msg) { Write-Host "[SyncHub] $Msg" -ForegroundColor Cyan }
function Write-Ok([string]$Msg) { Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host "  [!] $Msg" -ForegroundColor Yellow }

function Get-HandoffRoot {
    $root = Join-Path $env:APPDATA "SyncHub\tray-handoff"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    return $root
}

function Backup-OfficialStartup {
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $dir = Join-Path (Get-HandoffRoot) $stamp
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $present = $false
    $enabled = $false
    $xml = ""
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $xml = (& schtasks.exe /Query /TN $TaskName /XML 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($xml)) {
            $present = $true
            $enabled = $xml -notmatch '<Enabled>\s*false\s*</Enabled>'
            Set-Content -LiteralPath (Join-Path $dir "SyncClipboardStartup.xml") -Value $xml -Encoding UTF8
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    Set-Content -LiteralPath (Join-Path $dir "task-state.txt") -Encoding UTF8 -Value @(
        "name=$TaskName",
        "present=$present",
        "enabled=$enabled"
    )
    $runText = ""
    try {
        $runText = (& reg.exe query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" | Out-String)
    } catch {}
    Set-Content -LiteralPath (Join-Path $dir "hkcu-run.txt") -Value $runText -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dir "BACKUP_OK") -Value "synchub-tray-handoff" -Encoding ASCII
    @{
        version = 1
        task = $TaskName
        deletesProgramFiles = $false
        deletesUserConfig = $false
        deletesHistory = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir "manifest.json") -Encoding UTF8
    Write-Ok "已备份启动项: $dir"
    return $dir
}

function Get-SyncClipboardPipeName {
    # SyncClipboard 3.3.3 AppInstance.cs: Global\SyncClipboard-Pipe-{UserName}-
    return "Global\SyncClipboard-Pipe-$([Environment]::UserName)-"
}

function Send-SyncClipboardShutdown {
    # Same line the official client sends to the running instance.
    # ExitAsync stops services and calls Application.Exit. It does not hide the window.
    # Do not relaunch the official client. Its restart flag also leaves a new process running.
    $pipeName = Get-SyncClipboardPipeName
    $client = New-Object System.IO.Pipes.NamedPipeClientStream '.', $pipeName, ([System.IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect(3000)
        $writer = New-Object System.IO.StreamWriter($client)
        try {
            $writer.WriteLine('Shutdown')
            $writer.Flush()
        } finally {
            $writer.Dispose()
        }
        return $true
    } catch {
        Write-Warn "没能连上 SyncClipboard 退出管道 $pipeName : $($_.Exception.Message)"
        return $false
    } finally {
        $client.Dispose()
    }
}

function Wait-OfficialStopped([int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (-not (Test-OfficialRunning)) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return -not (Test-OfficialRunning)
}

function Request-OfficialExit {
    if (-not (Test-OfficialRunning)) { return $true }
    Write-Step "向正在运行的 SyncClipboard 发送官方 Shutdown（命名管道，不强制结束进程）。"
    $sent = Send-SyncClipboardShutdown
    if ($sent -and (Wait-OfficialStopped -Seconds 45)) { return $true }
    Write-Warn "SyncClipboard 进程还在。请在通知区域右键 SyncClipboard 图标，点击「退出」。"
    Write-Warn "要点托盘菜单里的退出，它会结束进程。只关闭设置窗口不会退出。"
    Write-Step "脚本再等 3 分钟。进程消失后，这一次试用会继续。不要退出 SyncHub，不要强制结束进程。"
    if (Wait-OfficialStopped -Seconds 180) { return $true }
    return $false
}

function Disable-OfficialStartup([string]$Dir, [switch]$StopProcess) {
    $marker = Join-Path $Dir "BACKUP_OK"
    if (-not (Test-Path -LiteralPath $marker)) {
        throw "没有备份标记，已拒绝修改启动项。"
    }
    $state = Get-Content -LiteralPath (Join-Path $Dir "task-state.txt") -Raw
    if ($state -match 'present=True') {
        & schtasks.exe /Change /TN $TaskName /Disable
        if ($LASTEXITCODE -ne 0) { throw "禁用 $TaskName 失败，未继续删除任何文件。" }
        Write-Ok "已禁用计划任务 $TaskName"
    } else {
        Write-Warn "备份里没有 $TaskName，跳过禁用。"
    }
    & reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v $OfficialValue /f | Out-Null
    if ($StopProcess) {
        if (-not (Request-OfficialExit)) {
            throw "SyncClipboard 仍在运行，不能把它当成已退出。未使用强制结束。"
        }
        Write-Ok "SyncClipboard 已退出（未删除程序）"
    }
    Write-Ok "未删除程序、配置、历史或已接收文件。"
}

function Restore-OfficialStartup([string]$Dir) {
    $statePath = Join-Path $Dir "task-state.txt"
    if (-not (Test-Path -LiteralPath $statePath)) { throw "找不到备份，未改动启动项。" }
    $state = Get-Content -LiteralPath $statePath -Raw
    if ($state -match 'enabled=True') {
        & schtasks.exe /Change /TN $TaskName /Enable
        if ($LASTEXITCODE -ne 0) { throw "恢复 $TaskName 失败。" }
        Write-Ok "已重新启用 $TaskName。下次登录会出现 SyncClipboard 托盘。"
    } else {
        Write-Warn "备份显示该任务原先未启用，保持现状。"
    }
    Write-Ok "未删除任何文件。手动打开 SyncClipboard 后，SyncHub 会暂停自己的剪贴板监视。"
}

function Get-OfficialExeFromBackup([string]$Dir) {
    $saved = Join-Path $Dir "official-exe.txt"
    if (Test-Path -LiteralPath $saved) {
        $exe = (Get-Content -LiteralPath $saved -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($exe)) { return $exe }
    }
    $fallback = Join-Path $env:LOCALAPPDATA "Programs\SyncClipboard\SyncClipboard.exe"
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return ""
}

function Save-OfficialExe([string]$Dir) {
    $exe = ""
    $proc = Get-CimInstance Win32_Process -Filter "Name = 'SyncClipboard.exe'" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $proc -and -not [string]::IsNullOrWhiteSpace($proc.ExecutablePath)) {
        $exe = $proc.ExecutablePath
    }
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $fallback = Join-Path $env:LOCALAPPDATA "Programs\SyncClipboard\SyncClipboard.exe"
        if (Test-Path -LiteralPath $fallback) { $exe = $fallback }
    }
    if (-not [string]::IsNullOrWhiteSpace($exe)) {
        Set-Content -LiteralPath (Join-Path $Dir "official-exe.txt") -Value $exe -Encoding UTF8
    }
    return $exe
}

function Test-OfficialRunning {
    $out = & tasklist.exe /FI "IMAGENAME eq SyncClipboard.exe" /NH
    return (($out | Out-String).ToLower().Contains("syncclipboard.exe"))
}

function Request-AppPause {
    $root = Get-HandoffRoot
    $cmd = Join-Path $root "command.json"
    $exe = ""
    if (-not [string]::IsNullOrWhiteSpace($BackupDir)) { $exe = Get-OfficialExeFromBackup $BackupDir }
    @{ op = "abort"; paused = $false; exe = $exe } | ConvertTo-Json | Set-Content -LiteralPath $cmd -Encoding UTF8
    $deadline = (Get-Date).AddSeconds(15)
    $synchub = @(Get-Process -Name "synchub" -ErrorAction SilentlyContinue)
    if ($synchub.Count -eq 0) { return $true }
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $cmd) {
            $raw = Get-Content -LiteralPath $cmd -Raw
            if ($raw -match '"paused"\s*:\s*true') { return $true }
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

if (-not $BackupOnly -and -not $Trial -and -not $AbortTrial -and -not $Takeover -and -not $Rollback -and -not $StopOfficial) {
    $BackupOnly = $true
}

if ($Rollback) {
    if ([string]::IsNullOrWhiteSpace($BackupDir)) { throw "回滚需要 -BackupDir <备份目录>" }
    Restore-OfficialStartup $BackupDir
    return
}

if ($AbortTrial) {
    if ([string]::IsNullOrWhiteSpace($BackupDir)) { throw "恢复需要 -BackupDir <试用备份目录>" }
    $paused = Request-AppPause
    if (-not $paused) {
        throw "SyncHub 仍在运行，且没有确认已暂停剪贴板。已拒绝启动 SyncClipboard，避免两边同时写。"
    }
    $exe = Get-OfficialExeFromBackup $BackupDir
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) {
        throw "找不到 SyncClipboard.exe。开机项未改，程序和配置都还在。请从开始菜单手动打开它。"
    }
    Start-Process -FilePath $exe | Out-Null
    @{ op = "idle"; paused = $false; exe = $exe } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path (Get-HandoffRoot) "command.json") -Encoding UTF8
    Write-Ok "已在 SyncHub 暂停剪贴板之后重新打开 SyncClipboard。开机项未改。"
    return
}

if ($Takeover) {
    if (-not $Confirm) { throw "禁用旧开机启动必须同时带 -Confirm，并且要在临时暂停并验证成功之后。" }
    if ([string]::IsNullOrWhiteSpace($BackupDir)) { throw "需要 -BackupDir，指向临时暂停时生成的备份。" }
    if (Test-OfficialRunning) {
        throw "SyncClipboard 仍在运行。请先 -Trial，验证 SyncHub 剪贴板，不要在两边都开着时禁用开机项。"
    }
    Disable-OfficialStartup -Dir $BackupDir
    Write-Step "旧开机启动已禁用。程序、配置和历史都还在。备份: $BackupDir"
    return
}

if ($StopOfficial) {
    if ($Trial -or $AbortTrial -or $Takeover -or $Rollback) {
        throw "-StopOfficial 不能和其他操作一起用。"
    }
    if (Request-OfficialExit) { exit 0 }
    Write-Warn "SyncClipboard 仍在运行。开机项未改。请从托盘点「退出」后重试。"
    exit 3
}

$saved = Backup-OfficialStartup
if ($Trial) {
    $exe = Save-OfficialExe $saved
    if (-not (Request-OfficialExit)) {
        throw "SyncClipboard 仍在运行。开机项未改，SyncHub 继续暂停剪贴板。请右键托盘图标点「退出」后重新运行 -Trial。"
    }
    @{ op = "trial"; paused = $false; exe = $exe } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path (Get-HandoffRoot) "command.json") -Encoding UTF8
    Set-Content -LiteralPath (Join-Path (Get-HandoffRoot) "latest-trial.txt") -Value $saved -Encoding UTF8
    Write-Output "BACKUP_DIR=$saved"
    Write-Ok "已临时退出 SyncClipboard。开机项未改。请验证文字、截图和单个文件。"
    Write-Step "通过: -Takeover -Confirm -BackupDir `"$saved`""
    Write-Step "失败: -AbortTrial -BackupDir `"$saved`""
    return
}

Write-Step "只做了备份。验证剪贴板请用 -Trial，不要直接 -Takeover。备份: $saved"
