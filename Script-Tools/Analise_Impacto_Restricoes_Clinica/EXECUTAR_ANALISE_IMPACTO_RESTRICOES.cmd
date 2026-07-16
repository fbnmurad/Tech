@echo off
setlocal
chcp 65001 >nul
title Analise de impacto - restricoes de jogos e wallpaper

fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Solicitando permissao de Administrador...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ANALISAR_IMPACTO_RESTRICOES.ps1"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo A analise terminou com o codigo %RC%.
    pause
)

exit /b %RC%
