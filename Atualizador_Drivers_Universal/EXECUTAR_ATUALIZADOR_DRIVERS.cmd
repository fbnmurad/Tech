@echo off
setlocal
title Atualizador universal de drivers

fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Solicitando permissao de Administrador...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ATUALIZAR_DRIVERS.ps1"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo O processo terminou com o codigo %RC%.
    pause
)

exit /b %RC%
