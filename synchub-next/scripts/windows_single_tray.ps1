# SyncHub single-tray handover for the NEXT run on the Windows PC.
# Default is backup only. -Takeover requires -Confirm.
# This script never deletes SyncClipboard.exe, SyncClipboard.json, history, or received files.
param(
    [switch]$BackupOnly,
    [switch]$Takeover,
    [switch]$Confirm,
    [switch]$Rollback,
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
        & taskkill.exe /IM $OfficialImage | Out-Null
        Write-Ok "已请求退出 $OfficialImage（未删除程序）"
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

if (-not $BackupOnly -and -not $Takeover -and -not $Rollback) { $BackupOnly = $true }

if ($Rollback) {
    if ([string]::IsNullOrWhiteSpace($BackupDir)) { throw "回滚需要 -BackupDir <备份目录>" }
    Restore-OfficialStartup $BackupDir
    return
}

$saved = Backup-OfficialStartup
if ($BackupOnly -and -not $Takeover) {
    Write-Step "只做了备份。确认新版本剪贴板正常后，再执行 -Takeover -Confirm。"
    return
}

if ($Takeover) {
    if (-not $Confirm) { throw "接管必须同时带 -Confirm。这一步会禁用旧自启并退出 SyncClipboard，但仍不删除程序和数据。" }
    Disable-OfficialStartup -Dir $saved -StopProcess
    Write-Step "备份目录（回滚用）: $saved"
}
