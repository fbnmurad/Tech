@echo off
fltmc >nul 2>&1
if not "%errorlevel%"=="0" (powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp01_PREPARAR_NOVO_PERFIL_RECEP.ps1"
if not "%errorlevel%"=="0" pause
