# 交叉编译 Linux 版网关与 hubctl（在 Windows 上运行）
$ErrorActionPreference = "Stop"
$gw = Join-Path (Split-Path -Parent $PSScriptRoot) "gateway"
Push-Location $gw
try {
    $env:CGO_ENABLED = "0"; $env:GOOS = "linux"; $env:GOARCH = "amd64"
    go build -trimpath -ldflags "-s -w" -o dist/linux-amd64/synchub-gateway ./cmd/gateway
    go build -trimpath -ldflags "-s -w" -o dist/linux-amd64/hubctl ./cmd/hubctl
    Write-Host "built: $gw\dist\linux-amd64"
} finally {
    Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Pop-Location
}
