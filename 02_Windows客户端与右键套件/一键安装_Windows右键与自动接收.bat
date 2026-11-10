@echo off
chcp 65001 >nul
title SyncHub Windows 右键闪传与自动接收套件 - 一键安装
echo ============================================================
echo   SyncHub Windows 套件一键安装程序
echo   1. 复制 synchub_client.py 到 C:\Program Files\SyncClipboard
echo   2. 创建 K:\跨端传输文件 目录及桌面快捷方式
echo   3. 注册资源管理器右键菜单『发送到跨端传输中心 (SyncHub)』
echo   4. 注册后台静默自动接收守护任务 SyncHubAutoReceiver
echo ============================================================
echo.

set "TARGET_DIR=C:\Program Files\SyncClipboard"
if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"
copy /Y "%~dp0synchub_client.py" "%TARGET_DIR%\synchub_client.py" >nul

python "%TARGET_DIR%\synchub_client.py" --install-all
if %errorlevel% equ 0 (
    echo.
    echo [成功] Windows 右键菜单与后台自动接收守护进程已全部安装并启动！
) else (
    echo.
    echo [提示] 请右键此脚本选择『以管理员身份运行』以完成注册。
)
pause
