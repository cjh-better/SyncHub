<#
.SYNOPSIS
    SyncHub-Next Master E2E Test Suite PowerShell Wrapper.
.DESCRIPTION
    Executes all 4 tiers of automated end-to-end integration tests.
    Strictly isolated on local loopback (127.0.0.1) with ephemeral ports.
    Zero external server communication.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests/run_all_e2e.ps1
    powershell -ExecutionPolicy Bypass -File tests/run_all_e2e.ps1 -Tier 1
#>

param (
    [Parameter(Mandatory = $false)]
    [ValidateSet(1, 2, 3, 4)]
    [int]$Tier
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$RunnerPy = Join-Path $ScriptDir "run_all_e2e.py"

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host " Starting SyncHub-Next Automated E2E Test Suite via PowerShell" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

$PyArgs = @($RunnerPy)
if ($PSBoundParameters.ContainsKey('Tier')) {
    $PyArgs += "--tier"
    $PyArgs += $Tier.ToString()
}

$Process = Start-Process -FilePath "python" -ArgumentList $PyArgs -WorkingDirectory $ProjectRoot -NoNewWindow -Wait -PassThru

if ($Process.ExitCode -eq 0) {
    Write-Host "`nAll E2E Test Suites Passed Successfully (Exit Code 0)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`nE2E Test Suites Encountered Failures (Exit Code $($Process.ExitCode))" -ForegroundColor Red
    exit $Process.ExitCode
}
