# Remove the Android-only JNI native asset from a Windows SyncHub bundle.
# Windows PowerShell 5.1: this file is UTF-8 with BOM.
param(
    [Parameter(Mandatory = $true)][string]$BundleDir,
    [string]$Dart = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $BundleDir)) {
    throw "Bundle directory does not exist: $BundleDir"
}

function Resolve-Dart {
    param([string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit) -and (Test-Path -LiteralPath $Explicit)) {
        return $Explicit
    }
    if (-not [string]::IsNullOrWhiteSpace($env:FLUTTER_ROOT)) {
        $fromRoot = Join-Path $env:FLUTTER_ROOT "bin\dart.bat"
        if (Test-Path -LiteralPath $fromRoot) { return $fromRoot }
    }
    $cmd = Get-Command dart.bat, dart -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return $cmd.Source }
    throw "dart was not found. Windows JNI stripping runs with the Dart SDK shipped beside Flutter."
}

$dart = Resolve-Dart $Dart
$app = Join-Path (Split-Path -Parent $PSScriptRoot) "app"
Push-Location $app
try {
    & $dart run --no-analytics tool/strip_windows_jni.dart $BundleDir
    if ($LASTEXITCODE -ne 0) {
        throw "strip_windows_jni.dart failed with exit $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
