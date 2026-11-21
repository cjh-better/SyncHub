# Build SyncHub Flutter clients on this Windows machine.
#   powershell -ExecutionPolicy Bypass -File scripts\build_app.ps1 [-Target windows|apk|all]
# Notes (environment-specific, see README):
#  - Gradle 9.x Kotlin-DSL script compilation is broken on this machine, so the
#    Android project is pinned to Gradle 8.14.3 + AGP 8.11.1 + Kotlin 2.2.21.
#  - The global JAVA_HOME points at a broken JDK, so JDK 17 is set per process.
param(
    [ValidateSet("windows", "apk", "all")][string]$Target = "all",
    [string]$AppIcon = ""
)
$ErrorActionPreference = "Stop"

function Assert-WindowsPowerShellScript([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        throw "$Path must be UTF-8 with BOM so Windows PowerShell 5.1 -File can parse it."
    }
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        $first = $parseErrors[0]
        throw "$Path failed PowerShell parse at line $($first.Extent.StartLineNumber): $($first.Message)"
    }
}

Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 | ForEach-Object {
    Assert-WindowsPowerShellScript $_.FullName
}
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-17.0.19.10-hotspot"
$env:ANDROID_HOME = "M:\android-sdk"; $env:ANDROID_SDK_ROOT = "M:\android-sdk"
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
$flutter = "M:\flutter\flutter\bin\flutter.bat"
$repoRoot = Split-Path -Parent $PSScriptRoot
$app = Join-Path $repoRoot "app"
function Assert-WindowsIconFile([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        throw "Windows build needs app/windows/runner/resources/app_icon.ico. The build will not substitute the system icon. Pass -AppIcon only to use a different .ico."
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing app icon path. It must be a regular .ico file, not a directory or a link: $Path"
    }
    if ($item.Length -lt 22) {
        throw "Refusing app icon. The file is too small to be an ICO: $Path"
    }
    $stream = [System.IO.File]::Open($item.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $header = New-Object byte[] 6
        $read = $stream.Read($header, 0, 6)
        if ($read -ne 6 -or $header[0] -ne 0 -or $header[1] -ne 0 -or $header[2] -ne 1 -or $header[3] -ne 0) {
            throw "Refusing app icon. The file is not an ICO: $Path"
        }
        $count = [int]$header[4] + (256 * [int]$header[5])
        if ($count -lt 1) { throw "Refusing app icon. The ICO contains no images: $Path" }
        $tableBytes = 6 + ($count * 16)
        if ($item.Length -lt $tableBytes) { throw "Refusing app icon. The ICO directory is truncated: $Path" }
    } finally {
        $stream.Dispose()
    }
}

function Resolve-SyncHubAppIcon([string]$ExplicitPath) {
    $dest = Join-Path $app "windows\runner\resources\app_icon.ico"
    $source = $ExplicitPath
    if ([string]::IsNullOrWhiteSpace($source)) { $source = $env:SYNCHUB_APP_ICON }
    if ([string]::IsNullOrWhiteSpace($source)) { $source = $dest }
    Assert-WindowsIconFile $source
    $destFull = [System.IO.Path]::GetFullPath($dest)
    $resources = [System.IO.Path]::GetFullPath((Join-Path $app "windows\runner\resources"))
    if (-not $resources.EndsWith("\")) { $resources = $resources + "\" }
    if (-not $destFull.StartsWith($resources, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to copy the icon outside windows\runner\resources."
    }
    New-Item -ItemType Directory -Force -Path $resources | Out-Null
    $sourceFull = [System.IO.Path]::GetFullPath($source)
    if (-not [string]::Equals($sourceFull, $destFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        [System.IO.File]::Copy($sourceFull, $destFull, $true)
        Assert-WindowsIconFile $destFull
    }
    return $destFull
}
$out = Join-Path $repoRoot "dist"
New-Item -ItemType Directory -Force $out | Out-Null

Push-Location $app
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed ($LASTEXITCODE)" }

    if ($Target -in "windows", "all") {
        $icon = Resolve-SyncHubAppIcon $AppIcon
        Write-Host "windows icon -> $icon"
        & $flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }

        $releaseDir = Join-Path $app "build\windows\x64\runner\Release"
        $dart = Join-Path (Split-Path -Parent $flutter) "dart.bat"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "strip_windows_jni.ps1") -BundleDir $releaseDir -Dart $dart
        if ($LASTEXITCODE -ne 0) { throw "Windows bundle still depends on JNI/JVM" }

        $winStage = Join-Path $out "windows-x64"
        if (Test-Path $winStage) { Remove-Item -Recurse -Force $winStage }
        New-Item -ItemType Directory -Force $winStage | Out-Null
        Copy-Item -Recurse -Force "build\windows\x64\runner\Release\*" $winStage
        Copy-Item -Force (Join-Path $PSScriptRoot "install_windows.ps1") $winStage
        Copy-Item -Force (Join-Path $PSScriptRoot "windows_single_tray.ps1") $winStage
        Copy-Item -Force (Join-Path $PSScriptRoot "一键安装_SyncHub_Windows.bat") $winStage
        Copy-Item -Force (Join-Path $PSScriptRoot "install_windows.ps1") $out
        Copy-Item -Force (Join-Path $PSScriptRoot "windows_single_tray.ps1") $out
        Copy-Item -Force (Join-Path $PSScriptRoot "一键安装_SyncHub_Windows.bat") $out
        foreach ($required in @("synchub.exe", "install_windows.ps1", "windows_single_tray.ps1")) {
            $bundled = Join-Path $winStage $required
            if (-not (Test-Path -LiteralPath $bundled)) {
                throw "Windows bundle is missing $required"
            }
        }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "strip_windows_jni.ps1") -BundleDir $winStage -Dart $dart
        if ($LASTEXITCODE -ne 0) { throw "Staged Windows bundle still depends on JNI/JVM" }

        $zip = Join-Path $out "SyncHub-windows-x64.zip"
        if (Test-Path $zip) { Remove-Item -Force $zip }
        Compress-Archive -Path (Join-Path $winStage "*") -DestinationPath $zip
        Write-Host "windows -> $zip"
    }

    if ($Target -in "apk", "all") {
        & $flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed ($LASTEXITCODE)" }

        Copy-Item "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk" (Join-Path $out "SyncHub-android-arm64-v8a.apk") -Force
        Copy-Item "build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk" (Join-Path $out "SyncHub-android-armeabi-v7a.apk") -Force
        Write-Host "apk -> $out"
    }
} finally { Pop-Location }
