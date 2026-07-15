@echo off
setlocal
chcp 65001 >nul
title Informações do computador

set "MAQUINA_ATUAL=%COMPUTERNAME%"
set "USUARIO_ATUAL=%USERDOMAIN%\%USERNAME%"
if "%USERDOMAIN%"=="" set "USUARIO_ATUAL=%USERNAME%"
set "SEM_PAUSA="
if /I "%~1"=="--nopause" set "SEM_PAUSA=--nopause"
if /I "%~1"=="/nopause" set "SEM_PAUSA=--nopause"
set "PS_SEM_PAUSA="
if defined SEM_PAUSA set "PS_SEM_PAUSA=-NoPause"

if exist "%~dp0Informacoes_Maquina_Usuario.exe" (
    "%~dp0Informacoes_Maquina_Usuario.exe" %SEM_PAUSA% --machine "%MAQUINA_ATUAL%" --user "%USUARIO_ATUAL%"
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0MOSTRAR_INFORMACOES_MAQUINA.ps1" %PS_SEM_PAUSA% -MachineNameOverride "%MAQUINA_ATUAL%" -LoggedUserOverride "%USUARIO_ATUAL%"
)
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo A coleta terminou com o código %RC%.
    pause
)

exit /b %RC%
