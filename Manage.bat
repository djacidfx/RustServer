@echo off
setlocal
title Rust Server Manager
cd /d "%~dp0"

:: Check for administrative permissions and self-elevate if needed
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges to manage Rust server processes and services...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd -ArgumentList '/c """%~f0""" %*' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-RustServer.ps1" %*

if "%~1"=="" pause
