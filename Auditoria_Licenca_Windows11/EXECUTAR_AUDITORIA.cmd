@echo off
setlocal
title Auditoria da Licenca do Windows

fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Solicitando permissao de Administrador...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AUDITAR_LICENCA_WINDOWS.ps1"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo A auditoria terminou com o codigo %RC%.
    pause
)

exit /b %RC%
