@echo off
setlocal
title Rust Server Manager
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-RustServer.ps1" %*

if "%~1"=="" pause
