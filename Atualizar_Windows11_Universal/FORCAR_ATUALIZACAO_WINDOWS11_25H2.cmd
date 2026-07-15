@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Atualizacao segura para Windows 11 25H2

fltmc >nul 2>&1
if errorlevel 1 (
    echo Solicitando permissao de Administrador...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cls
echo ================================================================
echo  ATUALIZACAO IN-PLACE PARA WINDOWS 11 25H2
echo  Preserva arquivos, aplicativos e ativacao OEM
echo ================================================================
echo.
echo Este procedimento usa uma ISO oficial montada no Windows.
echo Ele NAO faz instalacao limpa e NAO apaga seus arquivos.
echo O Dynamic Update sera desativado durante a instalacao para evitar
echo a falha atual do Windows Update. As atualizacoes mensais devem ser
echo instaladas depois que o Windows 25H2 iniciar normalmente.
echo.

set "LOGDIR=C:\Win11_25H2_Logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1

(
  echo Data: %date% %time%
  echo Computador: %COMPUTERNAME%
  echo Usuario: %USERNAME%
  ver
) > "%LOGDIR%\00_INICIO.txt"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$cs=Get-CimInstance Win32_ComputerSystem; $csp=Get-CimInstance Win32_ComputerSystemProduct; $bios=Get-CimInstance Win32_BIOS; $cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; $vendor='Desconhecido'; if($cs.Manufacturer -match 'Lenovo'){$vendor='Lenovo'} elseif($cs.Manufacturer -match 'Dell'){$vendor='Dell'} elseif($cs.Manufacturer){$vendor=$cs.Manufacturer}; $lenovoType=$null; if($vendor -eq 'Lenovo'){foreach($v in @($cs.Model,$csp.Name,$csp.Version,$csp.SKUNumber)){if($v -match '(?i)\b([0-9A-Z]{4})[0-9A-Z]{0,8}\b'){$lenovoType=$matches[1].ToUpperInvariant(); break}}}; [pscustomobject]@{Computador=$env:COMPUTERNAME; Fabricante=$cs.Manufacturer; FabricanteNormalizado=$vendor; Modelo=$cs.Model; Produto=$csp.Name; VersaoProduto=$csp.Version; TipoLenovo=$lenovoType; ServiceTagDell=if($vendor -eq 'Dell'){$bios.SerialNumber}else{$null}; Serie=$bios.SerialNumber; BIOS=$bios.SMBIOSBIOSVersion; Windows=$cv.DisplayVersion; Build=('{0}.{1}' -f $cv.CurrentBuild,$cv.UBR)} ^| Format-List ^| Tee-Object -FilePath '%LOGDIR%\00_IDENTIFICACAO_MAQUINA.txt'"

if errorlevel 1 (
    echo.
    echo ERRO: nao foi possivel identificar a maquina com WMI/CIM.
    echo Consulte %LOGDIR%\00_IDENTIFICACAO_MAQUINA.txt se ele tiver sido criado.
    pause
    exit /b 9
)

for /f "usebackq delims=" %%V in (`powershell.exe -NoProfile -Command ^
  "(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion"`) do set "VERSAO_ATUAL=%%V"

for /f "usebackq delims=" %%B in (`powershell.exe -NoProfile -Command ^
  "$r=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; '{0}.{1}' -f $r.CurrentBuild,$r.UBR"`) do set "BUILD_ATUAL=%%B"

echo Versao atual: %VERSAO_ATUAL%
echo Build atual:  %BUILD_ATUAL%
echo.

for /f "usebackq delims=" %%F in (`powershell.exe -NoProfile -Command ^
  "[math]::Round((Get-PSDrive -Name C).Free/1GB,1)"`) do set "FREEGB=%%F"

echo Espaco livre em C: %FREEGB% GB
powershell.exe -NoProfile -Command ^
  "if ((Get-PSDrive -Name C).Free -lt 30GB) { exit 1 } else { exit 0 }"
if errorlevel 1 (
    echo.
    echo ERRO: deixe pelo menos 30 GB livres antes de continuar.
    echo Libere espaco, reinicie o computador e execute novamente.
    pause
    exit /b 10
)

powershell.exe -NoProfile -Command ^
  "$p=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'); if($p){exit 1}else{exit 0}"
if errorlevel 1 (
    echo.
    echo ATENCAO: existe uma reinicializacao pendente.
    echo Reinicie o computador antes da atualizacao e execute este arquivo novamente.
    pause
    exit /b 11
)

echo.
echo Estado atual do BitLocker:
manage-bde.exe -status C: > "%LOGDIR%\01_BITLOCKER_ANTES.txt" 2>&1
findstr /i /c:"Protection Status" /c:"Status da Protecao" /c:"Conversion Status" /c:"Status da Conversao" "%LOGDIR%\01_BITLOCKER_ANTES.txt"
echo O instalador sera instruido a suspender temporariamente a protecao.
echo Confirme que voce possui a chave de recuperacao antes de prosseguir.
echo.

dism.exe /online /Get-Intl > "%LOGDIR%\02_IDIOMA_SISTEMA.txt" 2>&1
echo Idioma detectado:
findstr /i /c:"Default system UI language" /c:"Idioma padrao da interface do usuario do sistema" "%LOGDIR%\02_IDIOMA_SISTEMA.txt"
echo.
echo A ISO precisa ter o MESMO idioma do Windows atual, normalmente:
echo Portugues (Brasil).
echo.

set "ISODRIVE="
for /f "usebackq delims=" %%D in (`powershell.exe -NoProfile -Command ^
  "$v=Get-Volume -ErrorAction SilentlyContinue ^| Where-Object { $_.DriveLetter -and (Test-Path ($_.DriveLetter+':\setup.exe')) -and ((Test-Path ($_.DriveLetter+':\sources\install.wim')) -or (Test-Path ($_.DriveLetter+':\sources\install.esd'))) } ^| Select-Object -First 1; if($v){$v.DriveLetter}"`) do set "ISODRIVE=%%D:"

if not defined ISODRIVE (
    echo Nenhuma ISO oficial do Windows 11 foi encontrada montada.
    echo.
    echo Siga estes passos:
    echo 1. Baixe a ISO x64 atual no site oficial da Microsoft.
    echo 2. Confirme que a pagina informa Windows 11, versao 25H2.
    echo 3. Selecione o mesmo idioma do Windows atual.
    echo 4. Clique com o botao direito no arquivo ISO e escolha MONTAR.
    echo 5. Execute este arquivo novamente.
    echo.
    choice /c SN /n /m "Abrir agora a pagina oficial da Microsoft? [S/N]: "
    if errorlevel 2 exit /b 12
    start "" "https://www.microsoft.com/pt-br/software-download/windows11"
    exit /b 12
)

echo ISO localizada em: %ISODRIVE%\
echo.
dir "%ISODRIVE%\setup.exe" >> "%LOGDIR%\03_MIDIA_LOCALIZADA.txt" 2>&1
if exist "%ISODRIVE%\sources\install.wim" (
    echo Imagem: install.wim >> "%LOGDIR%\03_MIDIA_LOCALIZADA.txt"
    dism.exe /Get-WimInfo /WimFile:"%ISODRIVE%\sources\install.wim" >> "%LOGDIR%\03_MIDIA_LOCALIZADA.txt" 2>&1
) else (
    echo Imagem: install.esd >> "%LOGDIR%\03_MIDIA_LOCALIZADA.txt"
    dism.exe /Get-WimInfo /WimFile:"%ISODRIVE%\sources\install.esd" >> "%LOGDIR%\03_MIDIA_LOCALIZADA.txt" 2>&1
)

echo ================================================================
echo Escolha a etapa:
echo.
echo [1] Somente verificar compatibilidade
echo [2] Iniciar atualizacao para 25H2
echo [3] Sair
echo ================================================================
choice /c 123 /n /m "Opcao: "
if errorlevel 3 exit /b 0
if errorlevel 2 goto ATUALIZAR
if errorlevel 1 goto COMPAT

:COMPAT
echo.
echo Executando verificacao de compatibilidade. Nenhuma instalacao sera feita.
echo Esta etapa pode levar varios minutos.
echo.
"%ISODRIVE%\setup.exe" /auto upgrade /quiet /compat scanonly /dynamicupdate disable /eula accept /copylogs "%LOGDIR%\Compatibilidade.zip"
set "RC=%ERRORLEVEL%"
set "RCHEX="
set "RC_DEC=%RC%"
for /f "usebackq delims=" %%H in (`powershell.exe -NoProfile -Command ^
  "$n=[int64]$env:RC_DEC; '0x{0:X8}' -f ([uint32]($n -band 0xffffffff))"`) do set "RCHEX=%%H"

echo.
echo Codigo retornado: %RC% - %RCHEX%
echo Codigo retornado: %RC% - %RCHEX% > "%LOGDIR%\04_RESULTADO_COMPATIBILIDADE.txt"

if /i "%RCHEX%"=="0xC1900210" (
    echo RESULTADO: nenhuma incompatibilidade bloqueadora foi encontrada.
    echo Agora execute novamente e escolha a opcao 2.
) else if /i "%RCHEX%"=="0xC1900208" (
    echo RESULTADO: aplicativo ou driver incompativel bloqueou a atualizacao.
    echo Envie a pasta C:\Win11_25H2_Logs para analise.
) else if /i "%RCHEX%"=="0xC1900200" (
    echo RESULTADO: o instalador reportou bloqueio de requisito de sistema.
    echo Nao tente contornar o bloqueio antes de analisar os logs.
) else if /i "%RCHEX%"=="0xC190020E" (
    echo RESULTADO: espaco insuficiente para instalar.
) else (
    echo A verificacao retornou outro codigo.
    echo Consulte os logs em C:\Win11_25H2_Logs.
)
echo.
pause
exit /b %RC%

:ATUALIZAR
echo.
echo ================================================================
echo  CONFIRMACAO FINAL
echo ================================================================
echo.
echo Antes de continuar:
echo - mantenha o carregador conectado;
echo - salve seus arquivos importantes;
echo - feche todos os programas;
echo - desconecte pendrives, impressoras, docks e discos externos;
echo - nao desligue o computador durante a instalacao;
echo - confirme que a ISO e oficial, x64, 25H2 e do mesmo idioma.
echo.
choice /c SN /n /m "Iniciar a atualizacao preservando arquivos e aplicativos? [S/N]: "
if errorlevel 2 exit /b 0

echo.
echo Iniciando o Windows Setup...
echo Os avisos dispensaveis serao ignorados, mas bloqueios graves permanecem ativos.
echo O computador podera reiniciar varias vezes.
echo.

"%ISODRIVE%\setup.exe" /auto upgrade /dynamicupdate disable /eula accept /compat ignorewarning /bitlocker alwayssuspend /copylogs "%LOGDIR%\Instalacao.zip"
set "RC=%ERRORLEVEL%"

echo.
echo O Windows Setup retornou o codigo: %RC%
echo Codigo de retorno: %RC% > "%LOGDIR%\05_RESULTADO_INSTALACAO.txt"
echo.
echo Se a atualizacao nao iniciar ou retornar ao Windows antigo, compacte e envie:
echo C:\Win11_25H2_Logs
echo.
pause
exit /b %RC%
