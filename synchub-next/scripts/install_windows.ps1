# SyncHub Windows One-Click User-Space Installer
# Installs SyncHub to %LOCALAPPDATA%\Programs\SyncHub (no admin required unless
# disabling the legacy \SyncHubAutoReceiver scheduled task).
param(
    [string]$SourceDir = "",
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Programs\SyncHub"),
    [switch]$Yes,
    [switch]$NoLaunch,
    [switch]$NoDesktopShortcut,
    [switch]$SkipLegacyDisable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function U([string]$Escaped) {
    return [regex]::Unescape($Escaped)
}

function Write-Step([string]$Msg) {
    Write-Host "[SyncHub] $Msg" -ForegroundColor Cyan
}

function Write-Ok([string]$Msg) {
    Write-Host "  [OK] $Msg" -ForegroundColor Green
}

function Write-Warn([string]$Msg) {
    Write-Host "  [!] $Msg" -ForegroundColor Yellow
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-BundleSource {
    param([string]$ExplicitDir)

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitDir)) {
        $candidates += $ExplicitDir
    }
    $candidates += @(
        $PSScriptRoot,
        (Join-Path $PSScriptRoot "windows-x64"),
        (Join-Path $PSScriptRoot "Release"),
        (Join-Path $PSScriptRoot "SyncHub"),
        $repoRoot,
        (Join-Path $repoRoot "dist\windows-x64"),
        (Join-Path $repoRoot "app\build\windows\x64\runner\Release")
    )

    foreach ($cand in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($cand)) {
            $exe = Join-Path $cand "synchub.exe"
            $dll = Join-Path $cand "flutter_windows.dll"
            if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $dll)) {
                return @{ Path = (Resolve-Path -LiteralPath $cand).Path; Temp = $false }
            }
        }
    }

    $zipCandidates = @(
        (Join-Path $PSScriptRoot "SyncHub-windows-x64.zip"),
        (Join-Path $repoRoot "dist\SyncHub-windows-x64.zip")
    )
    foreach ($zip in $zipCandidates) {
        if (Test-Path -LiteralPath $zip) {
            $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("synchub_stage_" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path $stage | Out-Null
            Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
            if (Test-Path -LiteralPath (Join-Path $stage "synchub.exe")) {
                return @{ Path = $stage; Temp = $true }
            }
            $nested = Get-ChildItem -LiteralPath $stage -Filter "synchub.exe" -Recurse | Select-Object -First 1
            if ($null -ne $nested) {
                return @{ Path = $nested.Directory.FullName; Temp = $true }
            }
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    throw (U "Cannot find SyncHub Windows release bundle (synchub.exe). Run scripts\build_app.ps1 -Target windows first or place install_windows.ps1 inside the release folder.")
}

function Import-RegText {
    param([string]$RegContent)
    $tmpReg = Join-Path ([System.IO.Path]::GetTempPath()) ("synchub_" + [guid]::NewGuid().ToString("N") + ".reg")
    $prevEap = $ErrorActionPreference
    try {
        [System.IO.File]::WriteAllText($tmpReg, $RegContent, [System.Text.UnicodeEncoding]::new($false, $true))
        $ErrorActionPreference = "Continue"
        $null = & reg.exe import $tmpReg 2>&1
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prevEap
        Remove-Item -LiteralPath $tmpReg -Force -ErrorAction SilentlyContinue
    }
}

function Escape-RegValue([string]$Val) {
    return $Val.Replace('\', '\\').Replace('"', '\"')
}

function Test-LegacyAutoReceiverActive {
    $taskActive = $false
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $csvOut = & schtasks.exe /Query /TN "\SyncHubAutoReceiver" /FO CSV /NH 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($csvOut -join ""))) {
            $xmlOut = (& schtasks.exe /Query /TN "\SyncHubAutoReceiver" /XML 2>$null) -join "`n"
            if ($LASTEXITCODE -eq 0 -and $xmlOut -notmatch '<Enabled>\s*false\s*</Enabled>') {
                $taskActive = $true
            }
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }

    $procs = @(
        Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*synchub_client.py*' }
    )
    return ($taskActive -or ($procs.Count -gt 0))
}

function Disable-LegacyAutoReceiver {
    $elevatedBody = @'
$ErrorActionPreference = 'SilentlyContinue'
& schtasks.exe /End /TN "\SyncHubAutoReceiver" *> $null
& schtasks.exe /Change /TN "\SyncHubAutoReceiver" /Disable *> $null
Get-CimInstance Win32_Process -Filter "Name = 'python.exe' OR Name = 'pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*synchub_client.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
'@
    if (Test-IsAdmin) {
        & powershell.exe -NoProfile -NonInteractive -Command $elevatedBody
        return
    }
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($elevatedBody)
    $encoded = [Convert]::ToBase64String($bytes)
    Start-Process -FilePath "powershell.exe" -Verb RunAs -WindowStyle Hidden -Wait `
        -ArgumentList @("-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-EncodedCommand", $encoded) | Out-Null
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("  " + (U "SyncHub Windows \u4E00\u952E\u5B89\u88C5\u4E0E\u8FC1\u79FB\u7A0B\u5E8F")) -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# 1. Locate release bundle & install into %LOCALAPPDATA%\Programs\SyncHub
Write-Step (U "\u6B63\u5728\u68C0\u67E5\u5B89\u88C5\u5305\u6765\u6E90...")
$srcInfo = Resolve-BundleSource -ExplicitDir $SourceDir
$resolvedSrc = $srcInfo.Path
Write-Ok ((U "\u5B89\u88C5\u6E90: ") + $resolvedSrc)

try {
    $targetExe = Join-Path $InstallDir "synchub.exe"
    $runningSyncHub = @(
        Get-Process -Name "synchub" -ErrorAction SilentlyContinue |
            Where-Object {
                try { $_.Path -and ([string]::Equals($_.Path, $targetExe, [System.StringComparison]::OrdinalIgnoreCase)) }
                catch { $false }
            }
    )
    if ($runningSyncHub.Count -gt 0) {
        Write-Step (U "\u68C0\u6D4B\u5230\u6B63\u5728\u8FD0\u884C\u7684 SyncHub\uFF0C\u6B63\u5728\u5E73\u6ED1\u5173\u95ED\u4EE5\u66F4\u65B0\u6587\u4EF6...")
        $runningSyncHub | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 600
    }

    if ([string]::Equals($resolvedSrc.TrimEnd('\'), $InstallDir.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Ok ((U "\u5DF2\u4F4D\u4E8E\u76EE\u6807\u76EE\u5F55: ") + $InstallDir)
    } else {
        Write-Step ((U "\u6B63\u5728\u5B89\u88C5\u7A0B\u5E8F\u6587\u4EF6\u5230 ") + $InstallDir + " ...")
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        $dataDir = Join-Path $InstallDir "data"
        if (Test-Path -LiteralPath $dataDir) {
            Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -Path (Join-Path $resolvedSrc "*") -Destination $InstallDir -Recurse -Force
        Write-Ok ((U "\u7A0B\u5E8F\u6587\u4EF6\u5DF2\u5B89\u88C5\u5230 ") + $targetExe)
    }
} finally {
    if ($srcInfo.Temp -and (Test-Path -LiteralPath $resolvedSrc)) {
        Remove-Item -LiteralPath $resolvedSrc -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$exePath = Join-Path $InstallDir "synchub.exe"
if (-not (Test-Path -LiteralPath $exePath)) {
    throw "Installation verification failed: $exePath not found."
}

# 2. Migrate legacy %APPDATA%\SyncClipboard\synchub_win_state.json -> %APPDATA%\xyz.synchub\synchub\hub_receiver_state.json
Write-Step (U "\u6B63\u5728\u8FC1\u79FB\u65E7\u7248\u63A5\u6536\u8FDB\u5EA6 (synchub_win_state.json)...")
$legacyStateFile = Join-Path $env:APPDATA "SyncClipboard\synchub_win_state.json"
$newSupportDir = Join-Path $env:APPDATA "xyz.synchub\synchub"
$newStateFile = Join-Path $newSupportDir "hub_receiver_state.json"
New-Item -ItemType Directory -Force -Path $newSupportDir | Out-Null

if (Test-Path -LiteralPath $legacyStateFile) {
    try {
        $legacyRaw = ([System.IO.File]::ReadAllText($legacyStateFile, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF)
        $legacyObj = $legacyRaw | ConvertFrom-Json
        $legacyLastId = 0
        if ($null -ne $legacyObj -and $null -ne $legacyObj.PSObject.Properties["last_id"]) {
            $legacyLastId = [int]$legacyObj.last_id
        }

        $currentLastId = 0
        if (Test-Path -LiteralPath $newStateFile) {
            $curRaw = ([System.IO.File]::ReadAllText($newStateFile, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF)
            $curObj = $curRaw | ConvertFrom-Json
            if ($null -ne $curObj -and $null -ne $curObj.PSObject.Properties["last_id"]) {
                $currentLastId = [int]$curObj.last_id
            }
        }

        if ($legacyLastId -gt $currentLastId) {
            $mergedJson = @{
                last_id    = $legacyLastId
                updated_at = [Math]::Round([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0, 3)
            } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText($newStateFile, $mergedJson, [System.Text.UTF8Encoding]::new($false))
            Write-Ok ((U "\u5DF2\u8FC1\u79FB last_id = ") + $legacyLastId + " -> " + $newStateFile)
        } else {
            Write-Ok ((U "\u73B0\u6709\u63A5\u6536\u8FDB\u5EA6\u5DF2\u662F\u6700\u65B0 (last_id = ") + $currentLastId + ")")
        }
    } catch {
        Write-Warn ((U "\u8FC1\u79FB synchub_win_state.json \u65F6\u8DF3\u8FC7: ") + $_.Exception.Message)
    }
} else {
    Write-Ok (U "\u672A\u53D1\u73B0\u65E7\u7248 synchub_win_state.json\uFF0C\u65E0\u9700\u8FC1\u79FB")
}

# 3. Clean legacy SyncHubSend / SyncHubSendStar Explorer verbs (leave SyncClipboard untouched)
Write-Step (U "\u6B63\u5728\u6E05\u7406\u65E7\u7248 SyncHubSend / SyncHubSendStar \u53F3\u952E\u83DC\u5355...")
$legacyVerbCleanupReg = @(
    "Windows Registry Editor Version 5.00",
    "",
    "[-HKEY_CURRENT_USER\Software\Classes\*\shell\SyncHubSend]",
    "[-HKEY_CURRENT_USER\Software\Classes\*\shell\SyncHubSendStar]",
    "[-HKEY_CURRENT_USER\Software\Classes\Directory\shell\SyncHubSend]",
    "[-HKEY_CURRENT_USER\Software\Classes\Directory\shell\SyncHubSendStar]",
    ""
) -join "`r`n"
[void](Import-RegText -RegContent $legacyVerbCleanupReg)
Write-Ok (U "\u65E7\u7248\u53F3\u952E\u83DC\u5355\u9879\u5DF2\u6E05\u7406")

# 4. Offer / run elevation to disable legacy \SyncHubAutoReceiver if active
if (-not $SkipLegacyDisable) {
    if (Test-LegacyAutoReceiverActive) {
        Write-Warn (U "\u68C0\u6D4B\u5230\u65E7\u7248\u540E\u53F0\u81EA\u52A8\u63A5\u6536\u4EFB\u52A1 \\SyncHubAutoReceiver (synchub_client.py) \u6B63\u5728\u8FD0\u884C\u3002")
        $shouldDisable = $true
        if (-not $Yes -and [Environment]::UserInteractive) {
            try {
                $ans = Read-Host (U "  \u662F\u5426\u63D0\u6743\u505C\u7528\u65E7\u7248 \\SyncHubAutoReceiver (\u4E0D\u5F71\u54CD SyncClipboard)? [Y/n]")
                if ($ans -match '^[Nn]') {
                    $shouldDisable = $false
                }
            } catch {
                $shouldDisable = $true
            }
        }
        if ($shouldDisable) {
            try {
                Disable-LegacyAutoReceiver
                if (-not (Test-LegacyAutoReceiverActive)) {
                    Write-Ok (U "\u5DF2\u505C\u7528 \\SyncHubAutoReceiver \u5E76\u7ED3\u675F synchub_client.py \u8FDB\u7A0B")
                } else {
                    Write-Warn (U "\\SyncHubAutoReceiver \u4ECD\u5904\u4E8E\u542F\u7528\u72B6\u6001\uFF0C\u7A0D\u540E\u53EF\u5728 SyncHub \u8BBE\u7F6E\u4E2D\u4E00\u952E\u505C\u7528")
                }
            } catch {
                Write-Warn ((U "\u5DF2\u8DF3\u8FC7\u63D0\u6743\u505C\u7528: ") + $_.Exception.Message)
            }
        }
    } else {
        Write-Ok (U "\u672A\u68C0\u6D4B\u5230\u6D3B\u8DC3\u7684\u65E7\u7248 \\SyncHubAutoReceiver \u5B88\u62A4\u8FDB\u7A0B")
    }
}

# 5. Register HKCU\Software\Microsoft\Windows\CurrentVersion\Run\SyncHub
Write-Step (U "\u6B63\u5728\u6CE8\u518C\u5F00\u673A\u9759\u9ED8\u81EA\u542F\u52A8...")
$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (-not (Test-Path -LiteralPath $runKeyPath)) {
    New-Item -Path $runKeyPath -Force | Out-Null
}
Set-ItemProperty -LiteralPath $runKeyPath -Name "SyncHub" -Value "`"$exePath`" --minimized" -Type String
Write-Ok ("HKCU\...\Run\SyncHub = `"$exePath`" --minimized")

# 6. Register initial Windows Explorer cascading context menu
Write-Step (U "\u6B63\u5728\u6CE8\u518C\u8D44\u6E90\u7BA1\u7406\u5668\u53F3\u952E\u83DC\u5355 (\u53D1\u9001\u5230 SyncHub)...")
$escExe = Escape-RegValue $exePath
$escIcon = Escape-RegValue "`"$exePath`",0"
$escSendVerb = Escape-RegValue (U "\u53D1\u9001\u5230 SyncHub")
$escPickVerb = Escape-RegValue (U "\u9009\u62E9\u8BBE\u5907\u53D1\u9001\u2026")
$escPickCmd = Escape-RegValue "`"$exePath`" --send `"%1`""
$escCloudStarVerb = Escape-RegValue (U "\u5B58\u5230\u4E91\u7AEF\u6536\u85CF")
$escCloudStarCmd = Escape-RegValue "`"$exePath`" --send --cloud --star `"%1`""
$escCloudTempVerb = Escape-RegValue (U "\u53D1\u9001\u5230\u4E91\u7AEF\u4E2D\u8F6C (72\u5C0F\u65F6)")
$escCloudTempCmd = Escape-RegValue "`"$exePath`" --send --cloud `"%1`""

$contextMenuReg = @(
    "Windows Registry Editor Version 5.00",
    "",
    "[-HKEY_CURRENT_USER\Software\Classes\SyncHub.ContextMenu]",
    "",
    "[HKEY_CURRENT_USER\Software\Classes\*\shell\SyncHub]",
    "`"MUIVerb`"=`"$escSendVerb`"",
    "`"Icon`"=`"$escIcon`"",
    "`"MultiSelectModel`"=`"Player`"",
    "`"ExtendedSubCommandsKey`"=`"SyncHub.ContextMenu`"",
    "",
    "[HKEY_CURRENT_USER\Software\Classes\Directory\shell\SyncHub]",
    "`"MUIVerb`"=`"$escSendVerb`"",
    "`"Icon`"=`"$escIcon`"",
    "`"MultiSelectModel`"=`"Player`"",
    "`"ExtendedSubCommandsKey`"=`"SyncHub.ContextMenu`"",
    "",
    "[HKEY_CURRENT_USER\Software\Classes\SyncHub.ContextMenu\shell\01_pick]",
    "`"MUIVerb`"=`"$escPickVerb`"",
    "",
    "[HKEY_CURRENT_USER\Software\Classes\SyncHub.ContextMenu\shell\01_pick\command]",
    "@=`"$escPickCmd`"",
    "",
    "[HKEY_CURRENT_USER\Software\Classes\SyncHub.ContextMenu\shell\90_cloud]",
    "`"MUIVerb`"=`"$escCloudStarVerb`"",
    "`"CommandFlags`"=dword:00000020",
    "",
    "[HKEY_CURRENT_USER\Software\Classes\SyncHub.ContextMenu\shell\90_cloud\command]",
    "@=`"$escCloudStarCmd`"",
    "",
    "[HKEY_CURRENT_USER\Software\Classes\SyncHub.ContextMenu\shell\91_cloud_temp]",
    "`"MUIVerb`"=`"$escCloudTempVerb`"",
    "",
    "[HKEY_CURRENT_USER\Software\Classes\SyncHub.ContextMenu\shell\91_cloud_temp\command]",
    "@=`"$escCloudTempCmd`"",
    ""
) -join "`r`n"

if (-not (Import-RegText -RegContent $contextMenuReg)) {
    throw "Failed to import Explorer context-menu registry entries."
}
Write-Ok (U "\u5DF2\u6CE8\u518C\u6587\u4EF6\u4E0E\u6587\u4EF6\u5939\u53F3\u952E\u83DC\u5355\u300E\u53D1\u9001\u5230 SyncHub\u300F")

# 7. Create Start Menu and Desktop shortcuts
Write-Step (U "\u6B63\u5728\u521B\u5EFA\u5F00\u59CB\u83DC\u5355\u4E0E\u684C\u9762\u5FEB\u6377\u65B9\u5F0F...")
try {
    $wsh = New-Object -ComObject WScript.Shell
    $desc = U "SyncHub \u8DE8\u7AEF\u6587\u4EF6\u4E0E\u526A\u8D34\u677F\u4F20\u8F93"

    $startMenuPrograms = [Environment]::GetFolderPath("Programs")
    if (-not [string]::IsNullOrWhiteSpace($startMenuPrograms)) {
        $startLnk = $wsh.CreateShortcut((Join-Path $startMenuPrograms "SyncHub.lnk"))
        $startLnk.TargetPath = $exePath
        $startLnk.WorkingDirectory = $InstallDir
        $startLnk.IconLocation = "$exePath,0"
        $startLnk.Description = $desc
        $startLnk.Save()
    }

    if (-not $NoDesktopShortcut) {
        $desktopDir = [Environment]::GetFolderPath("Desktop")
        if (-not [string]::IsNullOrWhiteSpace($desktopDir)) {
            $deskLnk = $wsh.CreateShortcut((Join-Path $desktopDir "SyncHub.lnk"))
            $deskLnk.TargetPath = $exePath
            $deskLnk.WorkingDirectory = $InstallDir
            $deskLnk.IconLocation = "$exePath,0"
            $deskLnk.Description = $desc
            $deskLnk.Save()
        }
    }
    Write-Ok (U "\u5FEB\u6377\u65B9\u5F0F\u5DF2\u521B\u5EFA")
} catch {
    Write-Warn ((U "\u521B\u5EFA\u5FEB\u6377\u65B9\u5F0F\u5931\u8D25: ") + $_.Exception.Message)
}

# 8. Launch SyncHub
if (-not $NoLaunch) {
    Write-Step (U "\u6B63\u5728\u542F\u52A8 SyncHub...")
    Start-Process -FilePath $exePath -WorkingDirectory $InstallDir | Out-Null
    Write-Ok (U "SyncHub \u5DF2\u542F\u52A8\uFF08\u53EF\u5728\u7CFB\u7EDF\u6258\u76D8\u67E5\u770B\uFF09")
}

Write-Host ""
$handoff = Join-Path $PSScriptRoot "windows_single_tray.ps1"
if (Test-Path -LiteralPath $handoff) {
    Write-Step (U "\u6B63\u5728\u5907\u4EFD SyncClipboard \u5F00\u673A\u542F\u52A8\u9879\uFF08\u4E0D\u7981\u7528\u3001\u4E0D\u5220\u9664\uFF09...")
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $handoff -BackupOnly
    } catch {
        Write-Warn ((U "\u5907\u4EFD\u542F\u52A8\u9879\u5931\u8D25\uFF0C\u5B89\u88C5\u672C\u8EAB\u5DF2\u5B8C\u6210: ") + $_.Exception.Message)
    }
    Write-Warn (U "\u5B89\u88C5\u53EA\u5907\u4EFD\u5F00\u673A\u9879\u3002\u8BF7\u5728 SyncHub \u8BBE\u7F6E\u91CC\u70B9\u300C\u4E34\u65F6\u6682\u505C\u5E76\u9A8C\u8BC1\u300D\uFF0C\u6216\u8FD0\u884C windows_single_tray.ps1 -Trial\u3002\u9A8C\u8BC1\u901A\u8FC7\u518D\u7981\u7528\u65E7\u5F00\u673A\u9879\uFF1B\u5931\u8D25\u7528 -AbortTrial\u3002")
}
Write-Host ""
Write-Host ("  " + (U "\u5B89\u88C5\u5B8C\u6210\uFF01")) -ForegroundColor Green
