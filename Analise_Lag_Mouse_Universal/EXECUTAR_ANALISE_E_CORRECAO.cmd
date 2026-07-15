@echo off
setlocal
title Analise e correcao de lag do mouse

fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Solicitando permissao de Administrador...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ANALISAR_E_CORRIGIR_LAG_MOUSE.ps1"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo O processo terminou com o codigo %RC%.
    pause
)

exit /b %RC%
