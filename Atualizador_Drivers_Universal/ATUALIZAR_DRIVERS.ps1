#requires -version 5.1
<#
  Atualizador criterioso de drivers
  Equipamento-alvo: Lenovo, Dell ou outro computador Windows
  Estratégia:
    1. identifica o equipamento;
    2. registra e opcionalmente exporta os drivers atuais;
    3. cria ponto de restauração, quando disponível;
    4. abre a ferramenta oficial do fabricante, quando encontrada;
    5. opcionalmente instala drivers oferecidos pelo Microsoft Update;
    6. compara os drivers antes/depois e procura dispositivos com erro.

  O script não baixa drivers de sites de terceiros e não força pacote incompatível.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=== {0} ===" -f $Text) -ForegroundColor Cyan
}

function Save-Text {
    param(
        [string]$Path,
        [object]$Content
    )
    $Content | Out-File -FilePath $Path -Encoding utf8 -Width 4096
}

function Import-MachineIdentityModule {
    $candidates = @(
        (Join-Path $PSScriptRoot "MachineIdentity.ps1"),
        (Join-Path $PSScriptRoot "Shared\MachineIdentity.ps1"),
        (Join-Path $PSScriptRoot "..\Shared\MachineIdentity.ps1")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            . $candidate
            return
        }
    }

    throw "MachineIdentity.ps1 não foi encontrado. Mantenha a pasta Shared junto ao pacote ou copie o arquivo para a pasta do script."
}

function Get-DriverSnapshot {
    Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DeviceID } |
        Select-Object DeviceName, DeviceClass, Manufacturer, DriverProviderName,
            DriverVersion, DriverDate, InfName, IsSigned, DeviceID |
        Sort-Object DeviceName, DeviceID
}

function Get-ProblemDevices {
    Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
        Select-Object Name, PNPClass, Manufacturer, Status,
            ConfigManagerErrorCode, DeviceID |
        Sort-Object ConfigManagerErrorCode, Name
}

function Find-LenovoSystemUpdate {
    $candidatePaths = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in @(
        "$env:ProgramFiles\Lenovo\System Update\tvsu.exe",
        "${env:ProgramFiles(x86)}\Lenovo\System Update\tvsu.exe"
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue).Path
            if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                $candidatePaths.Add([string]$resolved) | Out-Null
            }
        }
    }

    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($root in $roots) {
        $apps = Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "^Lenovo System Update" }

        foreach ($app in @($apps)) {
            $installLocation = [string]$app.InstallLocation
            if ([string]::IsNullOrWhiteSpace($installLocation)) {
                continue
            }

            foreach ($candidate in @(
                (Join-Path $installLocation "tvsu.exe"),
                (Join-Path $installLocation "Tvsu.exe")
            )) {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue).Path
                    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                        $candidatePaths.Add([string]$resolved) | Out-Null
                    }
                }
            }
        }
    }

    $selected = $candidatePaths |
        Select-Object -Unique |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace([string]$selected)) {
        return $null
    }

    # Força o retorno como caminho completo, evitando que um texto isolado
    # seja indexado como caracteres ("C", ":", "\") pelo PowerShell.
    return [string]$selected
}

function Install-MicrosoftDriverUpdates {
    param(
        [string]$LogDir,
        [string]$PreferredSource = "fabricante"
    )

    Write-Step "Pesquisa de drivers no Microsoft Update"

    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = "Auditoria e atualização de drivers"
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Online = $true

        Write-Host "Pesquisando atualizações do tipo Driver..." -ForegroundColor Cyan
        $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")

        $available = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $searchResult.Updates.Count; $i++) {
            $u = $searchResult.Updates.Item($i)
            $available.Add([pscustomobject]@{
                Indice            = $i + 1
                Titulo            = $u.Title
                DriverFabricante  = $u.DriverManufacturer
                DriverModelo      = $u.DriverModel
                DataDriver        = $u.DriverVerDate
                RequerReinicio    = $u.RebootRequired
                Baixado           = $u.IsDownloaded
            }) | Out-Null
        }

        $available |
            Format-Table -AutoSize |
            Out-String -Width 4096 |
            Save-Text -Path (Join-Path $LogDir "30_DRIVERS_MICROSOFT_DISPONIVEIS.txt")

        if ($searchResult.Updates.Count -eq 0) {
            Write-Host "Nenhum driver adicional foi oferecido pelo Microsoft Update." -ForegroundColor Green
            return [pscustomobject]@{
                Encontrados = 0
                Instalados = 0
                ReinicioNecessario = $false
                Resultado = "Nenhum driver oferecido"
            }
        }

        Write-Host ""
        Write-Host "Drivers oferecidos pelo Microsoft Update:" -ForegroundColor Yellow
        $available | Format-Table Indice, Titulo, DriverFabricante, DriverModelo -AutoSize
        Write-Host ""
        Write-Host "A fonte preferencial para este computador é: $PreferredSource." -ForegroundColor Yellow
        Write-Host "Instale estes pacotes somente depois de concluir a ferramenta oficial do fabricante, quando disponível." -ForegroundColor Yellow

        $answer = Read-Host "Instalar todos os drivers listados acima? Digite SIM para confirmar"
        if ($answer.Trim().ToUpperInvariant() -ne "SIM") {
            return [pscustomobject]@{
                Encontrados = $searchResult.Updates.Count
                Instalados = 0
                ReinicioNecessario = $false
                Resultado = "Instalação recusada pelo usuário"
            }
        }

        $downloadCollection = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $searchResult.Updates.Count; $i++) {
            $u = $searchResult.Updates.Item($i)
            if (-not $u.EulaAccepted) {
                try { $u.AcceptEula() } catch {}
            }
            [void]$downloadCollection.Add($u)
        }

        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $downloadCollection
        $downloadResult = $downloader.Download()

        $installCollection = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $downloadCollection.Count; $i++) {
            $u = $downloadCollection.Item($i)
            if ($u.IsDownloaded) {
                [void]$installCollection.Add($u)
            }
        }

        if ($installCollection.Count -eq 0) {
            throw "Nenhum pacote foi baixado. Resultado do download: $($downloadResult.ResultCode)"
        }

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $installCollection
        $installResult = $installer.Install()

        $details = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $installCollection.Count; $i++) {
            $itemResult = $installResult.GetUpdateResult($i)
            $details.Add([pscustomobject]@{
                Titulo        = $installCollection.Item($i).Title
                Resultado     = $itemResult.ResultCode
                HResult       = ("0x{0:X8}" -f [uint32]$itemResult.HResult)
                Reinicio      = $installCollection.Item($i).RebootRequired
            }) | Out-Null
        }

        $details |
            Format-Table -AutoSize |
            Out-String -Width 4096 |
            Save-Text -Path (Join-Path $LogDir "31_RESULTADO_DRIVERS_MICROSOFT.txt")

        return [pscustomobject]@{
            Encontrados = $searchResult.Updates.Count
            Instalados = $installCollection.Count
            ReinicioNecessario = [bool]$installResult.RebootRequired
            Resultado = "Código geral $($installResult.ResultCode)"
        }
    }
    catch {
        $message = $_.Exception.Message
        Save-Text -Path (Join-Path $LogDir "31_ERRO_DRIVERS_MICROSOFT.txt") -Content $message
        Write-Host "A pesquisa/instalação pelo Microsoft Update falhou: $message" -ForegroundColor Red
        Write-Host "Isso pode ocorrer enquanto o Windows Update estiver com falha." -ForegroundColor Yellow

        return [pscustomobject]@{
            Encontrados = 0
            Instalados = 0
            ReinicioNecessario = $false
            Resultado = "Falha: $message"
        }
    }
}

if (-not (Test-Administrator)) {
    Write-Host "Execute pelo arquivo EXECUTAR_ATUALIZADOR_DRIVERS.cmd." -ForegroundColor Red
    Read-Host "Pressione ENTER para sair"
    exit 1
}

Import-MachineIdentityModule

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$desktop = [Environment]::GetFolderPath("Desktop")
$logDir = Join-Path $desktop "Atualizacao_Drivers_$timestamp"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Start-Transcript -Path (Join-Path $logDir "00_TRANSCRICAO.txt") -Force | Out-Null

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " ATUALIZADOR DE DRIVERS — UNIVERSAL" -ForegroundColor Cyan
Write-Host " Lenovo, Dell ou modo genérico via Microsoft Update" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# Identificação do equipamento
# -------------------------------------------------------------------------
Write-Step "Identificação do equipamento"

$machineIdentity = Get-MachineIdentity
$supportInfo = Get-OemSupportInfo -Identity $machineIdentity
$cs = $machineIdentity.RawComputerSystem
$csp = $machineIdentity.RawProduct
$bios = $machineIdentity.RawBios
$cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

Save-MachineIdentity -Identity $machineIdentity -Path (Join-Path $logDir "01_IDENTIFICACAO.txt")

$machineIdentity |
    Select-Object ComputerName, Vendor, Manufacturer, Model, ProductName,
        ProductVersion, LenovoMachineType, DellServiceTag, BiosVersion,
        WindowsVersion, WindowsBuild |
    Format-List

Write-Host "Fabricante detectado: $($machineIdentity.Vendor)" -ForegroundColor Green
Write-Host "Ferramenta preferencial: $($supportInfo.ToolName)"

if ($machineIdentity.Vendor -notin @("Lenovo", "Dell")) {
    Write-Host ""
    Write-Host "Fabricante sem fluxo OEM especializado neste pacote." -ForegroundColor Yellow
    Write-Host "O script continuará com inventário, backup, ponto de restauração e Microsoft Update opcional." -ForegroundColor Yellow
}

if ($cv.DisplayVersion -ne "25H2") {
    Write-Host ""
    Write-Host "ATENÇÃO: o Windows ainda não está na versão 25H2." -ForegroundColor Yellow
    Write-Host "A sequência preferencial é atualizar primeiro o Windows e depois os drivers." -ForegroundColor Yellow
    $continueOldWindows = Read-Host "Continuar mesmo assim? Digite CONTINUAR"
    if ($continueOldWindows.Trim().ToUpperInvariant() -ne "CONTINUAR") {
        Stop-Transcript | Out-Null
        exit 21
    }
}

# -------------------------------------------------------------------------
# Alimentação, internet e estado de reinicialização
# -------------------------------------------------------------------------
Write-Step "Pré-requisitos"

$powerOnline = $true
$batteryPercent = $null

try {
    $batteryStatus = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus |
        Select-Object -First 1
    if ($batteryStatus) {
        $powerOnline = [bool]$batteryStatus.PowerOnline
    }
} catch {}

try {
    $battery = Get-CimInstance Win32_Battery | Select-Object -First 1
    if ($battery) {
        $batteryPercent = [int]$battery.EstimatedChargeRemaining
    }
} catch {}

Write-Host "Carregador conectado: $powerOnline"
Write-Host "Carga estimada da bateria: $batteryPercent%"

if (-not $powerOnline) {
    Write-Host "Conecte o carregador antes de atualizar drivers e firmware." -ForegroundColor Red
    Stop-Transcript | Out-Null
    Read-Host "Pressione ENTER para sair"
    exit 22
}

if ($null -ne $batteryPercent -and $batteryPercent -lt 40) {
    Write-Host "A bateria precisa estar com pelo menos 40%." -ForegroundColor Red
    Stop-Transcript | Out-Null
    Read-Host "Pressione ENTER para sair"
    exit 23
}

if (@($supportInfo.DnsNames).Count -gt 0) {
    $dnsResults = Test-OemDns -SupportInfo $supportInfo
    $dnsResults |
        Format-Table -AutoSize |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $logDir "02_DNS_FABRICANTE.txt")

    $dnsFailures = @($dnsResults | Where-Object { -not $_.Ok })
    if ($dnsFailures.Count -eq 0) {
        Write-Host "DNS do fabricante: OK" -ForegroundColor Green
    }
    else {
        Write-Host "Não foi possível resolver todos os servidores do fabricante." -ForegroundColor Yellow
        $dnsFailures | Format-Table -AutoSize
        $continueDns = Read-Host "Continuar mesmo assim? Digite CONTINUAR"
        if ($continueDns.Trim().ToUpperInvariant() -ne "CONTINUAR") {
            Stop-Transcript | Out-Null
            exit 24
        }
    }
}
else {
    Write-Host "Sem servidores OEM conhecidos para testar; etapa DNS específica ignorada." -ForegroundColor Yellow
}

$pendingReboot = (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") -or
                 (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")

if ($pendingReboot) {
    Write-Host "Existe uma reinicialização pendente." -ForegroundColor Yellow
    Write-Host "Reinicie o notebook e execute novamente para evitar instalações incompletas." -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    Read-Host "Pressione ENTER para sair"
    exit 25
}

# -------------------------------------------------------------------------
# Inventário e backup
# -------------------------------------------------------------------------
Write-Step "Inventário anterior"

$beforeDrivers = Get-DriverSnapshot
$beforeDrivers |
    Export-Csv (Join-Path $logDir "10_DRIVERS_ANTES.csv") -NoTypeInformation -Encoding UTF8

$problemsBefore = Get-ProblemDevices
$problemsBefore |
    Export-Csv (Join-Path $logDir "11_DISPOSITIVOS_COM_ERRO_ANTES.csv") -NoTypeInformation -Encoding UTF8

Write-Host "Drivers inventariados: $($beforeDrivers.Count)"
Write-Host "Dispositivos com erro antes: $($problemsBefore.Count)"

$backupChoice = Read-Host "Exportar uma cópia dos drivers atuais? Digite SIM para confirmar"
$driverBackupDir = ""

if ($backupChoice.Trim().ToUpperInvariant() -eq "SIM") {
    $driverBackupDir = Join-Path $desktop ("Backup_Drivers_{0}_{1}" -f $machineIdentity.Vendor, $timestamp)
    New-Item -ItemType Directory -Path $driverBackupDir -Force | Out-Null

    Write-Host "Exportando drivers para $driverBackupDir..." -ForegroundColor Cyan
    & pnputil.exe /export-driver * "$driverBackupDir" 2>&1 |
        Out-File (Join-Path $logDir "12_EXPORTACAO_DRIVERS.txt") -Encoding utf8 -Width 4096
}

$restorePointCreated = $false

try {
    Checkpoint-Computer -Description "Antes de atualizar drivers $($machineIdentity.Vendor) $timestamp" `
        -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
    $restorePointCreated = $true
    Write-Host "Ponto de restauração criado." -ForegroundColor Green
}
catch {
    $firstRestoreError = $_.Exception.Message
    Write-Host "Não foi possível criar o ponto de restauração." -ForegroundColor Yellow
    Write-Host "Motivo: $firstRestoreError" -ForegroundColor Yellow

    $enableRestore = Read-Host "Deseja tentar habilitar a Proteção do Sistema na unidade C:? Digite SIM"
    if ($enableRestore.Trim().ToUpperInvariant() -eq "SIM") {
        try {
            Set-Service -Name VSS -StartupType Manual -ErrorAction SilentlyContinue
            Set-Service -Name swprv -StartupType Manual -ErrorAction SilentlyContinue
            Start-Service -Name VSS -ErrorAction SilentlyContinue
            Start-Service -Name swprv -ErrorAction SilentlyContinue

            Enable-ComputerRestore -Drive "C:\" -ErrorAction Stop

            Checkpoint-Computer -Description "Antes de atualizar drivers $($machineIdentity.Vendor) $timestamp" `
                -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop

            $restorePointCreated = $true
            Write-Host "Proteção do Sistema habilitada e ponto de restauração criado." -ForegroundColor Green
        }
        catch {
            $secondRestoreError = $_.Exception.Message
            Write-Host "A segunda tentativa também falhou: $secondRestoreError" -ForegroundColor Yellow

            @"
Primeira tentativa:
$firstRestoreError

Segunda tentativa após solicitar habilitação:
$secondRestoreError

A atualização pode prosseguir porque o backup dos drivers é independente
do ponto de restauração, mas a ausência de um ponto reduz a possibilidade
de reversão automática do Windows.
"@ | Save-Text -Path (Join-Path $logDir "13_PONTO_RESTAURACAO.txt")
        }
    }
    else {
        @"
Não foi possível criar o ponto de restauração:
$firstRestoreError

A usuária optou por não habilitar a Proteção do Sistema.
A atualização pode prosseguir usando o backup exportado dos drivers.
"@ | Save-Text -Path (Join-Path $logDir "13_PONTO_RESTAURACAO.txt")
    }
}

# -------------------------------------------------------------------------
# Ferramenta oficial do fabricante
# -------------------------------------------------------------------------
Write-Step "Ferramenta oficial do fabricante"

$oemToolPath = $supportInfo.ToolPath
$oemToolVersion = $null
$oemToolUsed = $false

if ([string]::IsNullOrWhiteSpace([string]$oemToolPath)) {
    Write-Host "$($supportInfo.ToolName) não foi encontrado." -ForegroundColor Yellow

    if (-not [string]::IsNullOrWhiteSpace([string]$supportInfo.InstallUrl)) {
        Write-Host "Será aberta a página oficial para instalação/verificação." -ForegroundColor Yellow
        Start-Process $supportInfo.InstallUrl
    }

    Save-Text -Path (Join-Path $logDir "20_FERRAMENTA_OEM_AUSENTE.txt") `
        -Content "Ferramenta preferencial não localizada: $($supportInfo.ToolName)`r`nFabricante: $($machineIdentity.Vendor)`r`nURL: $($supportInfo.InstallUrl)"

    Write-Host "Você pode continuar com Microsoft Update, mas a fonte OEM é preferencial para Lenovo e Dell." -ForegroundColor Yellow
}
elseif (-not (Test-Path -LiteralPath $oemToolPath -PathType Leaf)) {
    Write-Host "O caminho retornado para a ferramenta OEM não existe: $oemToolPath" -ForegroundColor Red
    Save-Text -Path (Join-Path $logDir "21_CAMINHO_OEM_INVALIDO.txt") `
        -Content "Caminho inválido retornado: $oemToolPath"
}
else {
    $oemToolItem = Get-Item -LiteralPath $oemToolPath -ErrorAction Stop
    $oemToolVersion = [string]$oemToolItem.VersionInfo.FileVersion

    Write-Host "Ferramenta: $($supportInfo.ToolName)"
    Write-Host "Executável: $($oemToolItem.FullName)"
    Write-Host "Versão: $oemToolVersion"

@"
Ferramenta OEM localizada:
$($supportInfo.ToolName)
$($oemToolItem.FullName)
Versão: $oemToolVersion
"@ | Save-Text -Path (Join-Path $logDir "20_FERRAMENTA_OEM.txt")

    Write-Host ""
    Write-Host "Na ferramenta do fabricante:" -ForegroundColor Yellow
    Write-Host "1. Pesquise atualizações para este equipamento detectado." -ForegroundColor Yellow
    Write-Host "2. Selecione drivers críticos e recomendados aplicáveis." -ForegroundColor Yellow
    Write-Host "3. Atualizações opcionais só devem ser usadas quando correspondam ao hardware instalado." -ForegroundColor Yellow
    Write-Host "4. BIOS/UEFI deve ser tratada como etapa separada, com BitLocker/chave de recuperação verificados." -ForegroundColor Yellow
    Write-Host "5. Conclua as instalações e feche a ferramenta." -ForegroundColor Yellow
    Write-Host ""

    $openOemTool = Read-Host "Abrir agora $($supportInfo.ToolName)? Digite SIM"
    if ($openOemTool.Trim().ToUpperInvariant() -eq "SIM") {
        try {
            $leafName = [IO.Path]::GetFileName($oemToolItem.FullName)
            if ($leafName -ieq "dcu-cli.exe") {
                Write-Host "Dell Command Update CLI detectado. Abrindo a página oficial e a pasta da ferramenta para uso manual." -ForegroundColor Yellow
                Start-Process $supportInfo.InstallUrl
                Start-Process explorer.exe -ArgumentList "/select,`"$($oemToolItem.FullName)`""
            }
            else {
                $oemToolProcess = Start-Process -FilePath $oemToolItem.FullName -Verb RunAs -PassThru
                if ($oemToolProcess) {
                    Wait-Process -Id $oemToolProcess.Id -ErrorAction SilentlyContinue
                }
            }
            $oemToolUsed = $true
        }
        catch {
            Write-Host "Falha ao abrir a ferramenta OEM: $($_.Exception.Message)" -ForegroundColor Red
            Save-Text -Path (Join-Path $logDir "21_ERRO_ABRIR_FERRAMENTA_OEM.txt") -Content $_.Exception.Message
        }

        Write-Host ""
        Read-Host "Depois de concluir e fechar a ferramenta do fabricante, pressione ENTER"
    }
}

# -------------------------------------------------------------------------
# Microsoft Update — opcional e posterior ao fabricante
# -------------------------------------------------------------------------
$msResult = $null
$msChoice = Read-Host "Pesquisar também drivers oferecidos pelo Microsoft Update? Digite SIM"
if ($msChoice.Trim().ToUpperInvariant() -eq "SIM") {
    $msResult = Install-MicrosoftDriverUpdates -LogDir $logDir -PreferredSource $supportInfo.ToolName
} else {
    $msResult = [pscustomobject]@{
        Encontrados = 0
        Instalados = 0
        ReinicioNecessario = $false
        Resultado = "Etapa não solicitada"
    }
}

# -------------------------------------------------------------------------
# Varredura e comparação final
# -------------------------------------------------------------------------
Write-Step "Verificação posterior"

& pnputil.exe /scan-devices 2>&1 |
    Out-File (Join-Path $logDir "40_PNPUTIL_SCAN_DEVICES.txt") -Encoding utf8 -Width 4096

Start-Sleep -Seconds 5

$afterDrivers = Get-DriverSnapshot
$afterDrivers |
    Export-Csv (Join-Path $logDir "41_DRIVERS_DEPOIS.csv") -NoTypeInformation -Encoding UTF8

$problemsAfter = Get-ProblemDevices
$problemsAfter |
    Export-Csv (Join-Path $logDir "42_DISPOSITIVOS_COM_ERRO_DEPOIS.csv") -NoTypeInformation -Encoding UTF8

$beforeMap = @{}
foreach ($d in $beforeDrivers) {
    $beforeMap[[string]$d.DeviceID] = $d
}

$changes = New-Object System.Collections.Generic.List[object]
foreach ($after in $afterDrivers) {
    $before = $beforeMap[[string]$after.DeviceID]

    if ($before -and (
        [string]$before.DriverVersion -ne [string]$after.DriverVersion -or
        [string]$before.InfName -ne [string]$after.InfName
    )) {
        $changes.Add([pscustomobject]@{
            Dispositivo       = $after.DeviceName
            Fabricante        = $after.Manufacturer
            VersaoAnterior    = $before.DriverVersion
            VersaoAtual       = $after.DriverVersion
            InfAnterior       = $before.InfName
            InfAtual          = $after.InfName
            DataAtual         = $after.DriverDate
            Assinado          = $after.IsSigned
            DeviceID          = $after.DeviceID
        }) | Out-Null
    }
}

$changes |
    Export-Csv (Join-Path $logDir "43_DRIVERS_ALTERADOS.csv") -NoTypeInformation -Encoding UTF8

$unsigned = $afterDrivers | Where-Object { $_.IsSigned -eq $false }
$unsigned |
    Export-Csv (Join-Path $logDir "44_DRIVERS_NAO_ASSINADOS.csv") -NoTypeInformation -Encoding UTF8

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add("ATUALIZAÇÃO DE DRIVERS — RESULTADO")
$summary.Add("Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
$summary.Add("")
$summary.Add("Equipamento: $($machineIdentity.Manufacturer) $($machineIdentity.Model)")
$summary.Add("Fabricante normalizado: $($machineIdentity.Vendor)")
$summary.Add("Tipo Lenovo: $($machineIdentity.LenovoMachineType)")
$summary.Add("Service Tag Dell: $($machineIdentity.DellServiceTag)")
$summary.Add("Série: $($machineIdentity.SerialNumber)")
$summary.Add("Windows: $($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR)")
$summary.Add("Ferramenta OEM: $($supportInfo.ToolName)")
$summary.Add("Caminho ferramenta OEM: $oemToolPath")
$summary.Add("Versão ferramenta OEM: $oemToolVersion")
$summary.Add("Ferramenta OEM aberta nesta execução: $oemToolUsed")
$summary.Add("")
$summary.Add("Drivers inventariados antes: $($beforeDrivers.Count)")
$summary.Add("Drivers inventariados depois: $($afterDrivers.Count)")
$summary.Add("Drivers com mudança de versão/INF: $($changes.Count)")
$summary.Add("Dispositivos com erro antes: $($problemsBefore.Count)")
$summary.Add("Dispositivos com erro depois: $($problemsAfter.Count)")
$summary.Add("Drivers não assinados depois: $($unsigned.Count)")
$summary.Add("")
$summary.Add("Microsoft Update encontrados: $($msResult.Encontrados)")
$summary.Add("Microsoft Update instalados: $($msResult.Instalados)")
$summary.Add("Microsoft Update resultado: $($msResult.Resultado)")
$summary.Add("Reinício solicitado pelo Microsoft Update: $($msResult.ReinicioNecessario)")
$summary.Add("")
$summary.Add("Backup dos drivers: $(if ($driverBackupDir) { $driverBackupDir } else { 'Não solicitado' })")
$summary.Add("")
if ($problemsAfter.Count -eq 0 -and $unsigned.Count -eq 0) {
    $summary.Add("VEREDITO: nenhum dispositivo com erro e nenhum driver não assinado foi detectado após a atualização.")
} else {
    $summary.Add("VEREDITO: existem itens que precisam de análise nos relatórios 42 e/ou 44.")
}
$summary.Add("")
$summary.Add("Reinicie o computador antes da avaliação final, mesmo quando nenhum instalador exigir explicitamente.")

$summary |
    Out-File (Join-Path $logDir "RESULTADO_LEIA_PRIMEIRO.txt") -Encoding utf8 -Width 4096

Stop-Transcript | Out-Null

$zipPath = Join-Path $desktop "Relatorio_Atualizacao_Drivers_$timestamp.zip"
Compress-Archive -Path $logDir -DestinationPath $zipPath -CompressionLevel Optimal -Force

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " PROCESSO CONCLUÍDO" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Drivers alterados: $($changes.Count)"
Write-Host "Dispositivos com erro: $($problemsAfter.Count)"
Write-Host "Drivers não assinados: $($unsigned.Count)"
Write-Host ""
Write-Host "Relatório principal:" -ForegroundColor Cyan
Write-Host (Join-Path $logDir "RESULTADO_LEIA_PRIMEIRO.txt")
Write-Host ""
Write-Host "ZIP para análise:" -ForegroundColor Cyan
Write-Host $zipPath
Write-Host ""
Write-Host "Reinicie o computador agora." -ForegroundColor Yellow
Read-Host "Pressione ENTER para fechar"
