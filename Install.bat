@echo off
setlocal
title Rust Server Setup Wizard
cd /d "%~dp0"

:: Check for administrative permissions and self-elevate if needed
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges to configure firewall and scheduled tasks...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd -ArgumentList '/c ""%~f0""' -Verb RunAs"
    exit /b
)

echo Starting Rust Server Installation Wizard...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-RustServer.ps1"

echo.
pause
