@echo off
setlocal
title Verificador universal de BIOS

fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Solicitando permissao de Administrador...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0VERIFICAR_BIOS.ps1"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo A verificacao terminou com o codigo %RC%.
    pause
)

exit /b %RC%
