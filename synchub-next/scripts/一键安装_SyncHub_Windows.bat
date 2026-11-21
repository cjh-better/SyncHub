@echo off
chcp 65001 >nul
setlocal
title SyncHub Windows 一键安装程序

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_windows.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo [错误] 安装过程中出现问题，退出代码: %EXIT_CODE%
    pause
    exit /b %EXIT_CODE%
)

echo [完成] SyncHub Windows 客户端已完成安装并启动。
timeout /t 3 >nul
exit /b 0
