@echo off
chcp 65001 >nul
cd /d "%~dp0"
if exist "%~dp0简笺.exe" (
    start "" "%~dp0简笺.exe"
    exit /b 0
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0JianNote.ps1"
if errorlevel 1 (
    echo.
    echo 简笺启动失败，请将本窗口中的错误信息告诉开发者。
    pause
)

