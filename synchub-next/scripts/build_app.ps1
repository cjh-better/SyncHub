# Build SyncHub Flutter clients on this Windows machine.
#   powershell -ExecutionPolicy Bypass -File scripts\build_app.ps1 [-Target windows|apk|all]
# Notes (environment-specific, see README):
#  - Gradle 9.x Kotlin-DSL script compilation is broken on this machine, so the
#    Android project is pinned to Gradle 8.14.3 + AGP 8.11.1 + Kotlin 2.2.21.
#  - The global JAVA_HOME points at a broken JDK, so JDK 17 is set per process.
param([ValidateSet("windows", "apk", "all")][string]$Target = "all")
$ErrorActionPreference = "Stop"
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-17.0.19.10-hotspot"
$env:ANDROID_HOME = "M:\android-sdk"; $env:ANDROID_SDK_ROOT = "M:\android-sdk"
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
$flutter = "M:\flutter\flutter\bin\flutter.bat"
$repoRoot = Split-Path -Parent $PSScriptRoot
$app = Join-Path $repoRoot "app"
$out = Join-Path $repoRoot "dist"
New-Item -ItemType Directory -Force $out | Out-Null

Push-Location $app
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed ($LASTEXITCODE)" }

    if ($Target -in "windows", "all") {
        & $flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }

        $winStage = Join-Path $out "windows-x64"
        if (Test-Path $winStage) { Remove-Item -Recurse -Force $winStage }
        New-Item -ItemType Directory -Force $winStage | Out-Null
        Copy-Item -Recurse -Force "build\windows\x64\runner\Release\*" $winStage
        Copy-Item -Force (Join-Path $PSScriptRoot "install_windows.ps1") $winStage
        Copy-Item -Force (Join-Path $PSScriptRoot "一键安装_SyncHub_Windows.bat") $winStage
        Copy-Item -Force (Join-Path $PSScriptRoot "install_windows.ps1") $out
        Copy-Item -Force (Join-Path $PSScriptRoot "一键安装_SyncHub_Windows.bat") $out

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
