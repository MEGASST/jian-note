@echo off
chcp 65001 >nul
cd /d "%~dp0"

rem 本地运行时直接调用主程序，绕开 exe 启动器：
rem 未签名的 exe 每次重新编译都会被 SmartScreen 拦一道，脚本方式没有这个问题。
start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0JianNote.ps1"
exit /b 0
