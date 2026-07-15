#requires -version 5.1
<#
  MODO CLÍNICA — REMOÇÃO E DESATIVAÇÃO DE JOGOS — V2 CORRIGIDA

  Equipamento-alvo:
    qualquer computador Windows, com identificação automática.

  Correções da V2:
    - remove estruturas genéricas que causavam "Os tipos de argumento não correspondem";
    - salva o estado em JSON usando apenas tipos simples;
    - registra a etapa exata em caso de erro;
    - não informa falsamente que criou ponto de restauração quando o Windows
      reutiliza um ponto das últimas 24 horas;
    - continua mesmo quando um pacote protegido não pode ser removido;
    - mantém Microsoft Store, Windows Update, drivers e aplicativos de trabalho.
#>

[CmdletBinding()]
param(
    [switch]$EnforceComputerName,
    [string]$ExpectedComputerName = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$StateRoot = "C:\ProgramData\APX-ModoClinicaJogos"
$StateFile = Join-Path $StateRoot "estado_mais_recente.json"

$GamingPackages = @(
    "Microsoft.GamingApp",
    "Microsoft.GamingServices",
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.XboxApp",
    "Microsoft.XboxGameOverlay",
    "Microsoft.XboxGamingOverlay",
    "Microsoft.XboxIdentityProvider",
    "Microsoft.XboxSpeechToTextOverlay",
    "Microsoft.Xbox.TCUI"
)

$GamingServices = @(
    "XblAuthManager",
    "XblGameSave",
    "XboxNetApiSvc",
    "XboxGipSvc",
    "GamingServices",
    "GamingServicesNet"
)

$ThirdPartyGameRegex = '(?i)\b(' +
    'Steam|Epic Games|EpicGamesLauncher|EA app|Electronic Arts|Origin|' +
    'Ubisoft Connect|Uplay|Battle\.net|Blizzard|GOG Galaxy|' +
    'Riot Client|Riot Games|VALORANT|League of Legends|' +
    'Roblox|Minecraft|Fortnite|Counter-Strike|Grand Theft Auto|' +
    'Call of Duty|Free Fire|BlueStacks|NoxPlayer|LDPlayer|' +
    'Playnite|GeForce NOW|Xbox' +
')\b'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Section {
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

function Add-Result {
    param(
        [ref]$ArrayRef,
        [string]$Tipo,
        [string]$Item,
        [string]$Resultado,
        [string]$Erro = ""
    )

    $entry = [pscustomobject]@{
        Tipo      = $Tipo
        Item      = $Item
        Resultado = $Resultado
        Erro      = $Erro
    }

    $ArrayRef.Value = @($ArrayRef.Value) + @($entry)
}

function Get-RegistryValueState {
    param(
        [string]$Path,
        [string]$Name
    )

    $exists = $false
    $value = $null

    if (Test-Path -LiteralPath $Path) {
        try {
            $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
            $value = $item.$Name
            $exists = $true
        }
        catch {}
    }

    return [pscustomobject]@{
        Path   = [string]$Path
        Name   = [string]$Name
        Exists = [bool]$exists
        Value  = if ($null -eq $value) { $null } else { [int64]$value }
    }
}

function Set-DwordValue {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty `
        -Path $Path `
        -Name $Name `
        -Value $Value `
        -PropertyType DWord `
        -Force | Out-Null
}

function Get-ServiceState {
    param([string]$Name)

    $cim = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction SilentlyContinue

    if ($null -eq $cim) {
        return [pscustomobject]@{
            Name      = [string]$Name
            Exists    = $false
            StartMode = $null
            State     = $null
        }
    }

    return [pscustomobject]@{
        Name      = [string]$Name
        Exists    = $true
        StartMode = [string]$cim.StartMode
        State     = [string]$cim.State
    }
}

function Get-InstalledSoftware {
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $items = @()

    foreach ($root in $roots) {
        $found = Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.DisplayName) } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation,
                UninstallString, QuietUninstallString, PSPath

        $items += @($found)
    }

    return @($items)
}

function Get-GamingInventory {
    param([string]$LogDir)

    $appx = @(
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $GamingPackages -contains $_.Name } |
            Select-Object Name, PackageFullName, PackageFamilyName,
                Architecture, Version, Status
    )

    $provisioned = @(
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $GamingPackages -contains $_.DisplayName } |
            Select-Object DisplayName, PackageName, Version, Architecture, ResourceId
    )

    $thirdParty = @(
        Get-InstalledSoftware |
            Where-Object {
                "$($_.DisplayName) $($_.Publisher) $($_.InstallLocation)" -match $ThirdPartyGameRegex
            } |
            Sort-Object DisplayName -Unique
    )

    $appx |
        Export-Csv (Join-Path $LogDir "10_APLICATIVOS_JOGOS_WINDOWS.csv") `
            -NoTypeInformation -Encoding UTF8

    $provisioned |
        Export-Csv (Join-Path $LogDir "11_JOGOS_PROVISIONADOS_NOVOS_USUARIOS.csv") `
            -NoTypeInformation -Encoding UTF8

    $thirdParty |
        Export-Csv (Join-Path $LogDir "12_JOGOS_E_LAUNCHERS_TERCEIROS.csv") `
            -NoTypeInformation -Encoding UTF8

    return [pscustomobject]@{
        Appx        = @($appx)
        Provisioned = @($provisioned)
        ThirdParty  = @($thirdParty)
    }
}

function Save-CurrentState {
    param(
        [string]$LogDir,
        [object]$Inventory
    )

    Write-Host "Salvando o estado atual para reversão..." -ForegroundColor Cyan

    $registryTargets = @(
        [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"; Name = "AllowGameDVR" },
        [pscustomobject]@{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled" },
        [pscustomobject]@{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AppCaptureEnabled" },
        [pscustomobject]@{ Path = "HKCU:\SOFTWARE\Microsoft\GameBar"; Name = "UseNexusForGameBarEnabled" },
        [pscustomobject]@{ Path = "HKCU:\SOFTWARE\Microsoft\GameBar"; Name = "ShowStartupPanel" }
    )

    $registryState = @()
    foreach ($target in $registryTargets) {
        $registryState += @(
            Get-RegistryValueState -Path ([string]$target.Path) -Name ([string]$target.Name)
        )
    }

    $serviceState = @()
    foreach ($serviceName in $GamingServices) {
        $serviceState += @(
            Get-ServiceState -Name ([string]$serviceName)
        )
    }

    $appxNames = @()
    foreach ($item in @($Inventory.Appx)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item.Name)) {
            $appxNames += [string]$item.Name
        }
    }
    $appxNames = @($appxNames | Sort-Object -Unique)

    $provisionedNames = @()
    foreach ($item in @($Inventory.Provisioned)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item.DisplayName)) {
            $provisionedNames += [string]$item.DisplayName
        }
    }
    $provisionedNames = @($provisionedNames | Sort-Object -Unique)

    $state = [pscustomobject]@{
        CreatedAt               = [string](Get-Date).ToString("o")
        ComputerName            = [string]$env:COMPUTERNAME
        CurrentUser             = [string][Security.Principal.WindowsIdentity]::GetCurrent().Name
        Registry                = @($registryState)
        Services                = @($serviceState)
        RemovedAppxNamesPlanned = @($appxNames)
        RemovedProvisionedNames = @($provisionedNames)
    }

    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null

    $json = $state | ConvertTo-Json -Depth 8
    $json | Out-File -FilePath $StateFile -Encoding utf8 -Width 4096
    $json | Out-File -FilePath (Join-Path $LogDir "20_ESTADO_ANTES.json") -Encoding utf8 -Width 4096

    Write-Host "Estado salvo em: $StateFile" -ForegroundColor Green
}

function Try-SystemRestorePoint {
    param([string]$LogDir)

    $message = ""

    try {
        $recent = @(
            Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
                Where-Object {
                    try {
                        [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) -ge (Get-Date).AddHours(-24)
                    }
                    catch {
                        $false
                    }
                }
        )

        if ($recent.Count -gt 0) {
            $message = "Já existe ponto de restauração criado nas últimas 24 horas. Ele será usado como referência."
            Write-Host $message -ForegroundColor Green
        }
        else {
            Checkpoint-Computer `
                -Description "Antes do Modo Clínica sem jogos $(Get-Date -Format 'yyyyMMdd_HHmmss')" `
                -RestorePointType "MODIFY_SETTINGS" `
                -ErrorAction Stop

            $message = "Solicitação de criação de ponto de restauração concluída."
            Write-Host $message -ForegroundColor Green
        }
    }
    catch {
        $message = "Não foi possível criar ou consultar ponto de restauração: $($_.Exception.Message)"
        Write-Host $message -ForegroundColor Yellow
    }

    Save-Text -Path (Join-Path $LogDir "21_PONTO_RESTAURACAO.txt") -Content $message
}

function Disable-GamingFeatures {
    param([string]$LogDir)

    $results = @()

    $settings = @(
        [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"; Name = "AllowGameDVR"; Value = 0 },
        [pscustomobject]@{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled"; Value = 0 },
        [pscustomobject]@{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AppCaptureEnabled"; Value = 0 },
        [pscustomobject]@{ Path = "HKCU:\SOFTWARE\Microsoft\GameBar"; Name = "UseNexusForGameBarEnabled"; Value = 0 },
        [pscustomobject]@{ Path = "HKCU:\SOFTWARE\Microsoft\GameBar"; Name = "ShowStartupPanel"; Value = 0 }
    )

    foreach ($setting in $settings) {
        try {
            Set-DwordValue -Path ([string]$setting.Path) -Name ([string]$setting.Name) -Value ([int]$setting.Value)
            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Registro" `
                -Item "$($setting.Path)\$($setting.Name)" `
                -Resultado "Desativado"
        }
        catch {
            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Registro" `
                -Item "$($setting.Path)\$($setting.Name)" `
                -Resultado "Falha" `
                -Erro $_.Exception.Message
        }
    }

    foreach ($serviceName in $GamingServices) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        if ($null -eq $service) {
            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Serviço" `
                -Item $serviceName `
                -Resultado "Não instalado"
            continue
        }

        try {
            if ($service.Status -ne "Stopped") {
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            }

            Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop

            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Serviço" `
                -Item $serviceName `
                -Resultado "Desabilitado"
        }
        catch {
            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Serviço" `
                -Item $serviceName `
                -Resultado "Falha" `
                -Erro $_.Exception.Message
        }
    }

    $results |
        Export-Csv (Join-Path $LogDir "30_RESULTADO_DESATIVACAO.csv") `
            -NoTypeInformation -Encoding UTF8

    return @($results)
}

function Remove-WindowsGamingApps {
    param([string]$LogDir)

    $results = @()

    Write-Host "Removendo aplicativos de jogos das contas existentes..." -ForegroundColor Cyan

    $packages = @(
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $GamingPackages -contains $_.Name } |
            Sort-Object PackageFullName -Unique
    )

    foreach ($package in $packages) {
        $removed = $false
        $errorMessage = ""

        try {
            Remove-AppxPackage `
                -Package ([string]$package.PackageFullName) `
                -AllUsers `
                -ErrorAction Stop

            $removed = $true
            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Appx instalado" `
                -Item ([string]$package.Name) `
                -Resultado "Removido de todos os usuários"
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        if (-not $removed) {
            try {
                $currentPackages = @(
                    Get-AppxPackage -Name ([string]$package.Name) -ErrorAction SilentlyContinue
                )

                foreach ($currentPackage in $currentPackages) {
                    Remove-AppxPackage `
                        -Package ([string]$currentPackage.PackageFullName) `
                        -ErrorAction Stop
                }

                if ($currentPackages.Count -gt 0) {
                    Add-Result -ArrayRef ([ref]$results) `
                        -Tipo "Appx instalado" `
                        -Item ([string]$package.Name) `
                        -Resultado "Removido do usuário atual"
                }
                else {
                    Add-Result -ArrayRef ([ref]$results) `
                        -Tipo "Appx instalado" `
                        -Item ([string]$package.Name) `
                        -Resultado "Não removido de outros usuários" `
                        -Erro $errorMessage
                }
            }
            catch {
                Add-Result -ArrayRef ([ref]$results) `
                    -Tipo "Appx instalado" `
                    -Item ([string]$package.Name) `
                    -Resultado "Falha" `
                    -Erro ("{0} | {1}" -f $errorMessage, $_.Exception.Message)
            }
        }
    }

    Write-Host "Removendo o provisionamento para futuros usuários..." -ForegroundColor Cyan

    $provisioned = @(
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $GamingPackages -contains $_.DisplayName } |
            Sort-Object PackageName -Unique
    )

    foreach ($package in $provisioned) {
        try {
            Remove-AppxProvisionedPackage `
                -Online `
                -PackageName ([string]$package.PackageName) `
                -AllUsers `
                -ErrorAction Stop | Out-Null

            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Appx provisionado" `
                -Item ([string]$package.DisplayName) `
                -Resultado "Removido"
        }
        catch {
            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Appx provisionado" `
                -Item ([string]$package.DisplayName) `
                -Resultado "Falha" `
                -Erro $_.Exception.Message
        }
    }

    $results |
        Export-Csv (Join-Path $LogDir "31_RESULTADO_REMOCAO_APLICATIVOS.csv") `
            -NoTypeInformation -Encoding UTF8

    return @($results)
}

function Restore-PoliciesAndServices {
    param([string]$LogDir)

    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        throw "Não foi encontrado um estado anterior em $StateFile."
    }

    $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $results = @()

    foreach ($item in @($state.Registry)) {
        try {
            if ([bool]$item.Exists) {
                Set-DwordValue `
                    -Path ([string]$item.Path) `
                    -Name ([string]$item.Name) `
                    -Value ([int]$item.Value)

                $action = "Valor anterior restaurado"
            }
            else {
                if (Test-Path -LiteralPath ([string]$item.Path)) {
                    Remove-ItemProperty `
                        -Path ([string]$item.Path) `
                        -Name ([string]$item.Name) `
                        -ErrorAction SilentlyContinue
                }

                $action = "Valor removido porque não existia antes"
            }

            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Registro" `
                -Item "$($item.Path)\$($item.Name)" `
                -Resultado $action
        }
        catch {
            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Registro" `
                -Item "$($item.Path)\$($item.Name)" `
                -Resultado "Falha" `
                -Erro $_.Exception.Message
        }
    }

    foreach ($item in @($state.Services)) {
        if (-not [bool]$item.Exists) {
            continue
        }

        $service = Get-Service -Name ([string]$item.Name) -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Serviço" `
                -Item ([string]$item.Name) `
                -Resultado "Não está instalado"
            continue
        }

        try {
            $startupType = switch ([string]$item.StartMode) {
                "Auto"     { "Automatic" }
                "Manual"   { "Manual" }
                "Disabled" { "Disabled" }
                default    { "Manual" }
            }

            Set-Service `
                -Name ([string]$item.Name) `
                -StartupType $startupType `
                -ErrorAction Stop

            if ([string]$item.State -eq "Running" -and $startupType -ne "Disabled") {
                Start-Service -Name ([string]$item.Name) -ErrorAction SilentlyContinue
            }

            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Serviço" `
                -Item ([string]$item.Name) `
                -Resultado "Estado anterior restaurado"
        }
        catch {
            Add-Result -ArrayRef ([ref]$results) `
                -Tipo "Serviço" `
                -Item ([string]$item.Name) `
                -Resultado "Falha" `
                -Erro $_.Exception.Message
        }
    }

    $results |
        Export-Csv (Join-Path $LogDir "40_RESULTADO_REVERSAO.csv") `
            -NoTypeInformation -Encoding UTF8

    return @($results)
}

if (-not (Test-Administrator)) {
    Write-Host "Solicitando permissão de Administrador..." -ForegroundColor Yellow
    Start-Process powershell.exe `
        -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
        -Verb RunAs
    exit
}

Import-MachineIdentityModule

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$desktop = [Environment]::GetFolderPath("Desktop")
$logDir = Join-Path $desktop "Modo_Clinica_Sem_Jogos_V2_$timestamp"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Start-Transcript -Path (Join-Path $logDir "00_TRANSCRICAO.txt") -Force | Out-Null

$stage = "Inicialização"

try {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " MODO CLÍNICA — REMOVER E DESATIVAR JOGOS — V2" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    $stage = "Identificação do equipamento"
    Write-Section $stage

    $machineIdentity = Get-MachineIdentity
    $cs = $machineIdentity.RawComputerSystem
    $csp = $machineIdentity.RawProduct
    $bios = $machineIdentity.RawBios
    $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

    Write-Host "Computador: $env:COMPUTERNAME"
    Write-Host "Fabricante: $($machineIdentity.Vendor)"
    Write-Host "Modelo: $($machineIdentity.Model)"
    Write-Host "Produto: $($machineIdentity.ProductName)"
    Write-Host "Tipo Lenovo: $($machineIdentity.LenovoMachineType)"
    Write-Host "Service Tag Dell: $($machineIdentity.DellServiceTag)"
    Write-Host "Série: $($machineIdentity.SerialNumber)"
    Write-Host "Windows: $($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR)"

    Save-MachineIdentity -Identity $machineIdentity -Path (Join-Path $logDir "01_IDENTIFICACAO.txt")

    if ($EnforceComputerName -and -not [string]::IsNullOrWhiteSpace($ExpectedComputerName) -and
        $env:COMPUTERNAME -ne $ExpectedComputerName) {
        throw "O nome atual do computador ($env:COMPUTERNAME) não corresponde ao esperado: $ExpectedComputerName."
    }

    $stage = "Inventário inicial"
    Write-Section "Inventário"

    $inventory = Get-GamingInventory -LogDir $logDir

    Write-Host "Aplicativos de jogos/Xbox do Windows: $(@($inventory.Appx).Count)"
    Write-Host "Pacotes provisionados para novos usuários: $(@($inventory.Provisioned).Count)"
    Write-Host "Possíveis jogos/launchers de terceiros: $(@($inventory.ThirdParty).Count)"

    if (@($inventory.ThirdParty).Count -gt 0) {
        Write-Host ""
        Write-Host "Programas de terceiros encontrados:" -ForegroundColor Yellow
        $inventory.ThirdParty |
            Select-Object DisplayName, DisplayVersion, Publisher |
            Format-Table -AutoSize
    }

    Write-Section "Menu"

    Write-Host "[1] Somente gerar inventário"
    Write-Host "[2] Aplicar Modo Clínica: remover apps de jogos e desativar recursos"
    Write-Host "[3] Restaurar políticas e serviços anteriores"
    Write-Host "[4] Abrir Aplicativos Instalados"
    Write-Host "[5] Sair"
    Write-Host ""

    $choice = Read-Host "Escolha uma opção"
    $actionSummary = "Nenhuma alteração realizada."

    switch ($choice) {
        "1" {
            $actionSummary = "Inventário gerado; nenhuma alteração realizada."
        }

        "2" {
            Write-Host ""
            Write-Host "Serão removidos aplicativos Xbox, Gaming App, Gaming Services e Paciência." -ForegroundColor Yellow
            Write-Host "Game DVR, capturas e serviços Xbox serão desativados." -ForegroundColor Yellow
            Write-Host "Microsoft Store, drivers e aplicativos de trabalho serão preservados." -ForegroundColor Green
            Write-Host ""

            $confirm = Read-Host "Digite REMOVER JOGOS para confirmar"
            if ($confirm.Trim().ToUpperInvariant() -ne "REMOVER JOGOS") {
                $actionSummary = "Operação cancelada; nenhuma alteração realizada."
                break
            }

            $stage = "Ponto de restauração"
            Try-SystemRestorePoint -LogDir $logDir

            $stage = "Salvamento do estado"
            Save-CurrentState -LogDir $logDir -Inventory $inventory

            $stage = "Desativação de recursos"
            Write-Section "Desativação de recursos de jogos"
            $disableResults = Disable-GamingFeatures -LogDir $logDir

            $stage = "Remoção dos aplicativos"
            Write-Section "Remoção dos aplicativos"
            $removeResults = Remove-WindowsGamingApps -LogDir $logDir

            $disableFailures = @($disableResults | Where-Object { $_.Resultado -eq "Falha" }).Count
            $removeFailures = @($removeResults | Where-Object { $_.Resultado -eq "Falha" }).Count

            $actionSummary = (
                "Modo Clínica aplicado. Falhas ao desativar: {0}. " +
                "Falhas ao remover aplicativos: {1}."
            ) -f $disableFailures, $removeFailures

            if (@($inventory.ThirdParty).Count -gt 0) {
                $openApps = Read-Host "Abrir Aplicativos Instalados para revisar programas de terceiros? Digite SIM"
                if ($openApps.Trim().ToUpperInvariant() -eq "SIM") {
                    Start-Process "ms-settings:appsfeatures"
                }
            }
        }

        "3" {
            Write-Host ""
            Write-Host "A reversão restaura políticas e serviços." -ForegroundColor Yellow
            Write-Host "Aplicativos removidos não são reinstalados automaticamente." -ForegroundColor Yellow
            Write-Host ""

            $confirm = Read-Host "Digite RESTAURAR para continuar"
            if ($confirm.Trim().ToUpperInvariant() -ne "RESTAURAR") {
                $actionSummary = "Reversão cancelada."
                break
            }

            $stage = "Reversão"
            $restoreResults = Restore-PoliciesAndServices -LogDir $logDir
            $restoreFailures = @($restoreResults | Where-Object { $_.Resultado -eq "Falha" }).Count
            $actionSummary = "Políticas e serviços restaurados. Falhas: $restoreFailures."
        }

        "4" {
            Start-Process "ms-settings:appsfeatures"
            $actionSummary = "Tela de Aplicativos Instalados aberta."
        }

        default {
            $actionSummary = "Nenhuma alteração realizada."
        }
    }

    $stage = "Inventário posterior"
    Write-Section "Verificação posterior"

    $after = Get-GamingInventory -LogDir $logDir

    $summary = [pscustomobject]@{
        Data                            = Get-Date
        Computador                      = $env:COMPUTERNAME
        Fabricante                      = $machineIdentity.Vendor
        Modelo                          = $machineIdentity.Model
        Produto                         = $machineIdentity.ProductName
        TipoLenovo                      = $machineIdentity.LenovoMachineType
        ServiceTagDell                  = $machineIdentity.DellServiceTag
        Serie                           = $machineIdentity.SerialNumber
        Windows                         = "$($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR)"
        Acao                            = $actionSummary
        AppxJogosAntes                  = @($inventory.Appx).Count
        AppxJogosDepois                 = @($after.Appx).Count
        ProvisionadosAntes              = @($inventory.Provisioned).Count
        ProvisionadosDepois             = @($after.Provisioned).Count
        ProgramasTerceirosIdentificados = @($inventory.ThirdParty).Count
        EstadoParaReversao              = $StateFile
        ReinicioRecomendado             = ($choice -in @("2","3"))
    }

    $summary | Format-List
    $summary |
        Format-List |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $logDir "RESULTADO_LEIA_PRIMEIRO.txt")

    $summary |
        Export-Csv (Join-Path $logDir "RESULTADO_RESUMIDO.csv") `
            -NoTypeInformation -Encoding UTF8

    Stop-Transcript | Out-Null

    $zipPath = Join-Path $desktop "Relatorio_Modo_Clinica_Sem_Jogos_V2_$timestamp.zip"
    Compress-Archive -Path $logDir -DestinationPath $zipPath -CompressionLevel Optimal -Force

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " PROCESSO CONCLUÍDO" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host $actionSummary
    Write-Host ""
    Write-Host "Relatório:"
    Write-Host $zipPath -ForegroundColor Cyan

    if ($choice -in @("2","3")) {
        Write-Host ""
        Write-Host "Reinicie o notebook para concluir." -ForegroundColor Yellow
        $restart = Read-Host "Digite REINICIAR para reiniciar agora, ou pressione ENTER para fazer depois"
        if ($restart.Trim().ToUpperInvariant() -eq "REINICIAR") {
            Restart-Computer -Force
        }
    }
}
catch {
    $errorText = @"
ETAPA
$stage

MENSAGEM
$($_.Exception.Message)

TIPO
$($_.Exception.GetType().FullName)

POSIÇÃO
$($_.InvocationInfo.PositionMessage)

PILHA
$($_.ScriptStackTrace)

DETALHES
$($_ | Out-String)
"@

    Save-Text -Path (Join-Path $logDir "ERRO.txt") -Content $errorText

    Write-Host ""
    Write-Host "A operação foi interrompida na etapa: $stage" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "O arquivo ERRO.txt contém a linha exata." -ForegroundColor Yellow

    try { Stop-Transcript | Out-Null } catch {}

    Read-Host "Pressione ENTER para fechar"
    exit 1
}
