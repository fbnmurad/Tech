@echo off
fltmc >nul 2>&1
if not "%errorlevel%"=="0" (powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\APX-PerfilRecep\2_CONCLUIR_MIGRACAO.ps1"
if not "%errorlevel%"=="0" pause
