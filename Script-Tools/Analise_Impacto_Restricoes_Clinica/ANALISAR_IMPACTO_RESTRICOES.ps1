#requires -version 5.1
<#
  Analisa se as restrições de jogos e wallpaper podem estar impactando
  a performance do computador.

  Modo de operação:
  - somente leitura;
  - não restaura serviços;
  - não reinstala aplicativos;
  - não remove políticas;
  - coleta evidências e gera relatório.
#>

[CmdletBinding()]
param(
    [int]$DurationSeconds = 90,
    [int]$IntervalSeconds = 2,
    [int]$EventDays = 14
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

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
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object]$Content
    )

    $Content | Out-File -FilePath $Path -Encoding utf8 -Width 4096
}

function Find-MachineIdentityModule {
    $candidates = @(
        (Join-Path $PSScriptRoot "MachineIdentity.ps1"),
        (Join-Path $PSScriptRoot "Shared\MachineIdentity.ps1"),
        (Join-Path $PSScriptRoot "..\Shared\MachineIdentity.ps1")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-BasicMachineIdentity {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

    $manufacturer = $computerSystem.Manufacturer
    $normalizedVendor = "UNKNOWN"
    if ($manufacturer -match "Lenovo") {
        $normalizedVendor = "LENOVO"
    }
    elseif ($manufacturer -match "Dell") {
        $normalizedVendor = "DELL"
    }
    elseif ($manufacturer) {
        $normalizedVendor = $manufacturer.ToUpperInvariant()
    }

    [pscustomobject]@{
        ComputerName     = $env:COMPUTERNAME
        Vendor           = $manufacturer
        NormalizedVendor = $normalizedVendor
        Model            = $computerSystem.Model
        SerialNumber     = $bios.SerialNumber
        WindowsCaption   = $os.Caption
        WindowsVersion   = $os.Version
        WindowsBuild     = $os.BuildNumber
        Source           = "Fallback interno do analisador"
    }
}

function Save-BasicMachineIdentity {
    param(
        [Parameter(Mandatory)] [object]$Identity,
        [Parameter(Mandatory)] [string]$Path
    )

    Save-Text -Path $Path -Content ($Identity | Format-List * | Out-String)
}

function Get-RegistryValueInfo {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Name
    )

    $exists = $false
    $value = $null
    $errorMessage = $null

    try {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
            $value = $item.$Name
            $exists = $true
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
    }

    [pscustomobject]@{
        Path   = $Path
        Name   = $Name
        Exists = $exists
        Value  = $value
        Error  = $errorMessage
    }
}

function Get-LoadedUserProfiles {
    $profileRoot = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

    foreach ($item in Get-ChildItem -LiteralPath $profileRoot -ErrorAction SilentlyContinue) {
        $sid = $item.PSChildName
        if ($sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') {
            continue
        }

        $profile = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
        $path = [Environment]::ExpandEnvironmentVariables([string]$profile.ProfileImagePath)
        $loaded = Test-Path -LiteralPath "Registry::HKEY_USERS\$sid"

        [pscustomobject]@{
            Sid     = $sid
            User    = Split-Path -Path $path -Leaf
            Path    = $path
            Loaded  = $loaded
            Hive    = if ($loaded) { "Registry::HKEY_USERS\$sid" } else { $null }
        }
    }
}

function Get-GamingRestrictionState {
    param([string]$LogDir)

    Write-Section "Estado das restrições de jogos"

    $registryTargets = @(
        [pscustomobject]@{ Scope = "HKLM"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"; Name = "AllowGameDVR"; RestrictedValue = 0 },
        [pscustomobject]@{ Scope = "HKCU"; Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled"; RestrictedValue = 0 },
        [pscustomobject]@{ Scope = "HKCU"; Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AppCaptureEnabled"; RestrictedValue = 0 },
        [pscustomobject]@{ Scope = "HKCU"; Path = "HKCU:\SOFTWARE\Microsoft\GameBar"; Name = "UseNexusForGameBarEnabled"; RestrictedValue = 0 },
        [pscustomobject]@{ Scope = "HKCU"; Path = "HKCU:\SOFTWARE\Microsoft\GameBar"; Name = "ShowStartupPanel"; RestrictedValue = 0 }
    )

    $registry = foreach ($target in $registryTargets) {
        $state = Get-RegistryValueInfo -Path $target.Path -Name $target.Name
        [pscustomobject]@{
            Scope           = $target.Scope
            Path            = $target.Path
            Name            = $target.Name
            Exists          = $state.Exists
            Value           = $state.Value
            RestrictedValue = $target.RestrictedValue
            RestrictionOn   = ($state.Exists -and ([string]$state.Value -eq [string]$target.RestrictedValue))
            Error           = $state.Error
        }
    }

    $services = foreach ($name in $GamingServices) {
        $svc = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name) -ErrorAction SilentlyContinue
        if ($svc) {
            [pscustomobject]@{
                Name      = $svc.Name
                Exists    = $true
                State     = $svc.State
                StartMode = $svc.StartMode
                ProcessId = $svc.ProcessId
                Disabled  = ([string]$svc.StartMode -eq "Disabled")
                Running   = ([string]$svc.State -eq "Running")
            }
        }
        else {
            [pscustomobject]@{
                Name      = $name
                Exists    = $false
                State     = $null
                StartMode = $null
                ProcessId = $null
                Disabled  = $false
                Running   = $false
            }
        }
    }

    $appx = @(
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $GamingPackages -contains $_.Name } |
            Select-Object Name, PackageFullName, PackageFamilyName, Version, Status
    )

    $provisioned = @(
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $GamingPackages -contains $_.DisplayName } |
            Select-Object DisplayName, PackageName, Version, Architecture
    )

    $stateFile = "C:\ProgramData\APX-ModoClinicaJogos\estado_mais_recente.json"
    $savedState = $null
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        try {
            $savedState = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $savedStateJson = $savedState | ConvertTo-Json -Depth 10
            Save-Text -Path (Join-Path $LogDir "15_ESTADO_MODO_CLINICA_SALVO.json") -Content $savedStateJson
        }
        catch {
            Save-Text -Path (Join-Path $LogDir "15_ESTADO_MODO_CLINICA_ERRO.txt") -Content $_.Exception.Message
        }
    }

    $registry | Export-Csv (Join-Path $LogDir "10_REGISTRO_JOGOS.csv") -NoTypeInformation -Encoding UTF8
    $services | Export-Csv (Join-Path $LogDir "11_SERVICOS_JOGOS.csv") -NoTypeInformation -Encoding UTF8
    $appx | Export-Csv (Join-Path $LogDir "12_APPX_JOGOS_INSTALADOS.csv") -NoTypeInformation -Encoding UTF8
    $provisioned | Export-Csv (Join-Path $LogDir "13_APPX_JOGOS_PROVISIONADOS.csv") -NoTypeInformation -Encoding UTF8

    Write-Host "Políticas/valores de jogos ativos: $(@($registry | Where-Object RestrictionOn).Count)"
    Write-Host "Serviços de jogos instalados: $(@($services | Where-Object Exists).Count)"
    Write-Host "Serviços de jogos em execução: $(@($services | Where-Object Running).Count)"
    Write-Host "Appx de jogos/Xbox ainda instalados: $(@($appx).Count)"

    [pscustomobject]@{
        Registry    = @($registry)
        Services    = @($services)
        Appx        = @($appx)
        Provisioned = @($provisioned)
        StateFile   = $stateFile
        SavedState  = $savedState
    }
}

function Get-WallpaperRestrictionState {
    param([string]$LogDir)

    Write-Section "Estado das restrições de wallpaper"

    $lockScreen = Get-RegistryValueInfo `
        -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" `
        -Name "NoChangingLockScreen"

    $profiles = @(Get-LoadedUserProfiles)
    $loadedProfiles = @($profiles | Where-Object Loaded)

    $userStates = foreach ($profile in $loadedProfiles) {
        $activeDesktop = Join-Path $profile.Hive "Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop"
        $systemPolicy = Join-Path $profile.Hive "Software\Microsoft\Windows\CurrentVersion\Policies\System"
        $desktop = Join-Path $profile.Hive "Control Panel\Desktop"

        $noChange = Get-RegistryValueInfo -Path $activeDesktop -Name "NoChangingWallPaper"
        $policyWallpaper = Get-RegistryValueInfo -Path $systemPolicy -Name "Wallpaper"
        $policyStyle = Get-RegistryValueInfo -Path $systemPolicy -Name "WallpaperStyle"
        $currentWallpaper = Get-RegistryValueInfo -Path $desktop -Name "WallPaper"

        $wallpaperPath = if ($policyWallpaper.Exists) { [string]$policyWallpaper.Value } else { [string]$currentWallpaper.Value }
        $expandedWallpaper = if ($wallpaperPath) { [Environment]::ExpandEnvironmentVariables($wallpaperPath) } else { $null }
        $exists = if ($expandedWallpaper) { Test-Path -LiteralPath $expandedWallpaper -PathType Leaf } else { $false }
        $sizeMB = $null
        if ($exists) {
            try {
                $sizeMB = [math]::Round((Get-Item -LiteralPath $expandedWallpaper).Length / 1MB, 2)
            }
            catch {}
        }

        [pscustomobject]@{
            User                 = $profile.User
            Sid                  = $profile.Sid
            HiveLoaded           = $profile.Loaded
            NoChangingWallPaper  = if ($noChange.Exists) { $noChange.Value } else { $null }
            WallpaperLocked      = ($noChange.Exists -and [int]$noChange.Value -eq 1)
            PolicyWallpaper      = $policyWallpaper.Value
            PolicyWallpaperStyle = $policyStyle.Value
            CurrentWallpaper     = $currentWallpaper.Value
            EffectiveWallpaper   = $expandedWallpaper
            WallpaperExists      = $exists
            WallpaperIsNetwork   = ($expandedWallpaper -match '^[\\]{2}')
            WallpaperSizeMB      = $sizeMB
        }
    }

    $allProfiles = $profiles |
        Select-Object User, Sid, Path, Loaded

    $allProfiles | Export-Csv (Join-Path $LogDir "20_PERFIS_LOCAIS.csv") -NoTypeInformation -Encoding UTF8
    $userStates | Export-Csv (Join-Path $LogDir "21_POLITICAS_WALLPAPER_USUARIOS_CARREGADOS.csv") -NoTypeInformation -Encoding UTF8

    [pscustomobject]@{
        LockScreen = [pscustomobject]@{
            Path          = $lockScreen.Path
            Name          = $lockScreen.Name
            Exists        = $lockScreen.Exists
            Value         = $lockScreen.Value
            RestrictionOn = ($lockScreen.Exists -and [int]$lockScreen.Value -eq 1)
        }
        Profiles   = @($allProfiles)
        Users      = @($userStates)
    }
}

function Get-RelevantEvents {
    param(
        [string]$LogDir,
        [int]$Days
    )

    Write-Section "Eventos recentes"

    $start = (Get-Date).AddDays(-1 * [math]::Abs($Days))
    $patterns = '(?i)xbox|gaming|gamebar|game dvr|wallpaper|personalization|active desktop|explorer\.exe|dwm\.exe|desktop window manager|group policy|appx|shell'

    $events = New-Object System.Collections.Generic.List[object]

    foreach ($logName in @("System", "Application")) {
        try {
            $items = Get-WinEvent -FilterHashtable @{
                LogName   = $logName
                StartTime = $start
                Level     = 1,2,3
            } -MaxEvents 2500 -ErrorAction Stop

            foreach ($evt in $items) {
                $text = "$($evt.ProviderName) $($evt.Message)"
                if ($text -match $patterns) {
                    $events.Add([pscustomobject]@{
                        TimeCreated = $evt.TimeCreated
                        LogName     = $logName
                        Provider    = $evt.ProviderName
                        Id          = $evt.Id
                        Level       = $evt.LevelDisplayName
                        Message     = ($evt.Message -replace '\s+', ' ').Trim()
                    }) | Out-Null
                }
            }
        }
        catch {
            [pscustomobject]@{
                TimeCreated = Get-Date
                LogName     = $logName
                Provider    = "Coleta"
                Id          = 0
                Level       = "Erro"
                Message     = $_.Exception.Message
            } | Export-Csv (Join-Path $LogDir ("EVENTOS_ERRO_{0}.csv" -f $logName)) -NoTypeInformation -Encoding UTF8
        }
    }

    $events |
        Sort-Object TimeCreated -Descending |
        Export-Csv (Join-Path $LogDir "30_EVENTOS_RELEVANTES.csv") -NoTypeInformation -Encoding UTF8

    Write-Host "Eventos relevantes encontrados: $($events.Count)"
    return $events.ToArray()
}

function Invoke-PerformanceSampling {
    param(
        [string]$LogDir,
        [int]$DurationSeconds,
        [int]$IntervalSeconds
    )

    Write-Section "Amostragem de performance"
    Write-Host "A coleta terá $DurationSeconds segundos. Use o notebook normalmente durante esse tempo." -ForegroundColor Yellow

    $logicalProcessors = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if ($logicalProcessors -lt 1) { $logicalProcessors = 1 }

    $samples = New-Object System.Collections.Generic.List[object]
    $processRows = New-Object System.Collections.Generic.List[object]
    $safeIntervalSeconds = [int]$IntervalSeconds
    if ($safeIntervalSeconds -lt 1) {
        $safeIntervalSeconds = 1
    }

    $safeDurationSeconds = [int]$DurationSeconds
    if ($safeDurationSeconds -lt 1) {
        $safeDurationSeconds = 1
    }

    $iterations = [int][math]::Ceiling([double]$safeDurationSeconds / [double]$safeIntervalSeconds)
    if ($iterations -lt 1) {
        $iterations = 1
    }

    for ($i = 1; $i -le $iterations; $i++) {
        try {
            $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
            $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
            $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk |
                Where-Object { $_.Name -eq "_Total" } |
                Select-Object -First 1
            $system = Get-CimInstance Win32_PerfFormattedData_PerfOS_System
            $proc = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
                Where-Object { $_.Name -notin @("_Total","Idle") -and $_.IDProcess -gt 0 }

            $topCpu = @($proc | Sort-Object {[double]$_.PercentProcessorTime} -Descending | Select-Object -First 8)
            $topIo = @($proc | Sort-Object {[double]$_.IODataBytesPersec} -Descending | Select-Object -First 8)

            foreach ($p in @($topCpu + $topIo | Sort-Object IDProcess, Name -Unique)) {
                $processRows.Add([pscustomobject]@{
                    TimeCreated = Get-Date
                    Name        = $p.Name
                    ProcessId   = $p.IDProcess
                    CpuPercent  = [math]::Round(([double]$p.PercentProcessorTime / $logicalProcessors), 2)
                    IO_MBps     = [math]::Round(([double]$p.IODataBytesPersec / 1MB), 2)
                    WorkingSetMB= [math]::Round(([double]$p.WorkingSet / 1MB), 1)
                }) | Out-Null
            }

            $samples.Add([pscustomobject]@{
                TimeCreated          = Get-Date
                CPUPercent           = [double]$cpu.PercentProcessorTime
                DPCPercent           = [double]$cpu.PercentDPCTime
                InterruptPercent     = [double]$cpu.PercentInterruptTime
                ProcessorQueueLength = [double]$system.ProcessorQueueLength
                AvailableMemoryMB    = [double]$mem.AvailableMBytes
                PagesPerSec          = [double]$mem.PagesPersec
                DiskPercent          = if ($disk) { [double]$disk.PercentDiskTime } else { 0 }
                DiskQueueLength      = if ($disk) { [double]$disk.AvgDiskQueueLength } else { 0 }
                DiskMBps             = if ($disk) { [math]::Round(([double]$disk.DiskBytesPersec / 1MB), 2) } else { 0 }
                TopCPU               = ($topCpu | ForEach-Object { "{0}={1}%" -f $_.Name, [math]::Round(([double]$_.PercentProcessorTime / $logicalProcessors), 1) }) -join " | "
                TopIO                = ($topIo | ForEach-Object { "{0}={1}MB/s" -f $_.Name, [math]::Round(([double]$_.IODataBytesPersec / 1MB), 2) }) -join " | "
            }) | Out-Null
        }
        catch {
            Save-Text -Path (Join-Path $LogDir ("ERRO_AMOSTRA_{0}.txt" -f $i)) -Content $_.Exception.Message
        }

        $remaining = $safeDurationSeconds - ($i * $safeIntervalSeconds)
        if ($remaining -lt 0) {
            $remaining = 0
        }
        Write-Progress -Activity "Coletando performance" -Status "$remaining segundos restantes" -PercentComplete (($i / $iterations) * 100)
        Start-Sleep -Seconds $safeIntervalSeconds
    }

    Write-Progress -Activity "Coletando performance" -Completed

    $sampleArray = @($samples.ToArray())
    $processArray = @($processRows.ToArray())

    $sampleArray | Export-Csv (Join-Path $LogDir "40_AMOSTRAS_PERFORMANCE.csv") -NoTypeInformation -Encoding UTF8
    $processArray | Export-Csv (Join-Path $LogDir "41_PROCESSOS_TOP_CPU_IO.csv") -NoTypeInformation -Encoding UTF8

    return @{
        Samples   = $sampleArray
        Processes = $processArray
    }
}

function New-ImpactSummary {
    param(
        [string]$LogDir,
        [object]$MachineIdentity,
        [object]$Gaming,
        [object]$Wallpaper,
        [object[]]$Events,
        [object]$Performance
    )

    Write-Section "Classificação"

    $findings = New-Object System.Collections.Generic.List[string]
    $evidence = New-Object System.Collections.Generic.List[string]
    $notEvidence = New-Object System.Collections.Generic.List[string]
    $recommendations = New-Object System.Collections.Generic.List[string]

    $gamingRegistryOn = @($Gaming.Registry | Where-Object RestrictionOn).Count
    $gamingServicesRunning = @($Gaming.Services | Where-Object Running)
    $gamingServicesDisabled = @($Gaming.Services | Where-Object { $_.Exists -and $_.Disabled })
    $wallpaperUsersLocked = @($Wallpaper.Users | Where-Object WallpaperLocked)
    $wallpaperMissing = @($Wallpaper.Users | Where-Object { $_.WallpaperLocked -and $_.EffectiveWallpaper -and -not $_.WallpaperExists })
    $wallpaperNetwork = @($Wallpaper.Users | Where-Object { $_.WallpaperLocked -and $_.WallpaperIsNetwork })
    $wallpaperLarge = @($Wallpaper.Users | Where-Object { $_.WallpaperLocked -and $_.WallpaperSizeMB -ge 20 })

    if ($gamingRegistryOn -gt 0 -or $gamingServicesDisabled.Count -gt 0 -or @($Gaming.Appx).Count -lt $GamingPackages.Count) {
        $evidence.Add("As restrições de jogos estão ativas ou parcialmente ativas: $gamingRegistryOn valor(es) de política e $($gamingServicesDisabled.Count) serviço(s) desabilitado(s).") | Out-Null
    }
    else {
        $notEvidence.Add("Não há sinal forte de que o Modo Clínica de jogos esteja ativo para o usuário atual.") | Out-Null
    }

    if ($gamingServicesRunning.Count -gt 0) {
        $findings.Add("Há serviço(s) de jogos ainda em execução: $(($gamingServicesRunning | Select-Object -ExpandProperty Name) -join ', '). Se algum aparecer também como alto CPU/I/O, pode haver impacto.") | Out-Null
    }
    else {
        $notEvidence.Add("Os serviços de jogos monitorados não estão em execução; quando parados/desabilitados, eles normalmente reduzem atividade de fundo em vez de piorar performance.") | Out-Null
    }

    if ($Wallpaper.LockScreen.RestrictionOn -or $wallpaperUsersLocked.Count -gt 0) {
        $evidence.Add("As restrições de wallpaper/tela de bloqueio estão ativas para $($wallpaperUsersLocked.Count) perfil(is) carregado(s).") | Out-Null
    }
    else {
        $notEvidence.Add("Não foi detectado bloqueio de wallpaper nos perfis carregados nem bloqueio de tela no HKLM.") | Out-Null
    }

    if ($wallpaperMissing.Count -gt 0) {
        $findings.Add("Há wallpaper de política apontando para arquivo inexistente. Isso pode atrasar logon/Explorer ou gerar tentativas repetidas de aplicar política.") | Out-Null
    }

    if ($wallpaperNetwork.Count -gt 0) {
        $findings.Add("Há wallpaper de política em caminho de rede. Se a rede estiver lenta/indisponível, isso pode afetar logon ou Explorer.") | Out-Null
    }

    if ($wallpaperLarge.Count -gt 0) {
        $findings.Add("Há arquivo de wallpaper com 20 MB ou mais. Isso raramente explica lentidão geral, mas pode pesar no logon ou na troca de sessão.") | Out-Null
    }

    $eventGaming = @($Events | Where-Object { "$($_.Provider) $($_.Message)" -match '(?i)xbox|gaming|gamebar|game dvr' })
    $eventWallpaper = @($Events | Where-Object { "$($_.Provider) $($_.Message)" -match '(?i)wallpaper|personalization|active desktop|group policy' })
    $eventShell = @($Events | Where-Object { "$($_.Provider) $($_.Message)" -match '(?i)explorer\.exe|dwm\.exe|desktop window manager|shell' })

    if ($eventGaming.Count -ge 5) {
        $findings.Add("Foram encontrados $($eventGaming.Count) eventos recentes ligados a Xbox/Gaming/Game Bar. Isso é indício fraco a moderado de impacto indireto se coincidir com os horários da lentidão.") | Out-Null
    }

    if ($eventWallpaper.Count -ge 3) {
        $findings.Add("Foram encontrados $($eventWallpaper.Count) eventos recentes ligados a wallpaper/personalização/política. Isso merece inspeção no CSV de eventos.") | Out-Null
    }

    if ($eventShell.Count -ge 3) {
        $findings.Add("Foram encontrados $($eventShell.Count) eventos recentes ligados a Explorer/DWM/Shell. Isso pode explicar sensação de travamento visual, mas não prova relação com as restrições.") | Out-Null
    }

    $samples = @($Performance.Samples)
    if ($samples.Count -gt 0) {
        $avgCpu = [math]::Round(($samples | Measure-Object CPUPercent -Average).Average, 1)
        $maxCpu = [math]::Round(($samples | Measure-Object CPUPercent -Maximum).Maximum, 1)
        $avgDpc = [math]::Round(($samples | Measure-Object DPCPercent -Average).Average, 2)
        $maxDpc = [math]::Round(($samples | Measure-Object DPCPercent -Maximum).Maximum, 2)
        $maxDisk = [math]::Round(($samples | Measure-Object DiskPercent -Maximum).Maximum, 1)
        $maxDiskQueue = [math]::Round(($samples | Measure-Object DiskQueueLength -Maximum).Maximum, 2)
        $minMemory = [math]::Round(($samples | Measure-Object AvailableMemoryMB -Minimum).Minimum, 0)

        if ($avgCpu -ge 70 -or $maxCpu -ge 95) {
            $findings.Add("A amostra mostrou CPU alta: média $avgCpu%, pico $maxCpu%. Verifique 41_PROCESSOS_TOP_CPU_IO.csv para o processo real.") | Out-Null
        }
        else {
            $notEvidence.Add("CPU sem saturação prolongada na amostra: média $avgCpu%, pico $maxCpu%.") | Out-Null
        }

        if ($avgDpc -ge 3 -or $maxDpc -ge 10) {
            $findings.Add("DPC elevado na amostra: média $avgDpc%, pico $maxDpc%. Isso aponta mais para driver/hardware do que para política de jogos/wallpaper.") | Out-Null
        }

        if ($maxDisk -ge 95 -and $maxDiskQueue -ge 2) {
            $findings.Add("Disco saturado na amostra: uso máximo $maxDisk%, fila máxima $maxDiskQueue. Isso costuma pesar mais que as restrições analisadas.") | Out-Null
        }

        if ($minMemory -lt 1024) {
            $findings.Add("Memória disponível caiu para $minMemory MB. Pressão de memória pode explicar lentidão.") | Out-Null
        }

        $relevantProcessRows = @($Performance.Processes | Where-Object {
            $_.Name -match '(?i)explorer|dwm|shellexperiencehost|startmenuexperiencehost|gamebar|gaming|xbox'
        })

        $hotRelevant = @($relevantProcessRows | Where-Object { $_.CpuPercent -ge 10 -or $_.IO_MBps -ge 10 })
        if ($hotRelevant.Count -gt 0) {
            $findings.Add("Processos de Shell/DWM/GameBar/Gaming apareceram com CPU ou I/O relevante durante a coleta. Consulte 41_PROCESSOS_TOP_CPU_IO.csv.") | Out-Null
        }
        else {
            $notEvidence.Add("Processos de Shell/DWM/GameBar/Gaming não apareceram como consumidores relevantes de CPU/I/O na amostra.") | Out-Null
        }

        $metricsText = @(
            "METRICAS DA AMOSTRA",
            "",
            "Amostras: $($samples.Count)",
            "CPU media: $avgCpu%",
            "CPU pico: $maxCpu%",
            "DPC medio: $avgDpc%",
            "DPC pico: $maxDpc%",
            "Disco pico: $maxDisk%",
            "Fila de disco pico: $maxDiskQueue",
            "Memoria disponivel minima: $minMemory MB"
        )
        Save-Text -Path (Join-Path $LogDir "42_RESUMO_METRICAS.txt") -Content $metricsText
    }
    else {
        $findings.Add("Não houve amostras válidas de performance.") | Out-Null
    }

    $verdict = if ($findings.Count -eq 0) {
        "SEM INDÍCIO DE IMPACTO DAS RESTRIÇÕES"
    }
    elseif (($wallpaperMissing.Count + $wallpaperNetwork.Count + $wallpaperLarge.Count) -gt 0 -or $eventWallpaper.Count -ge 3 -or $eventGaming.Count -ge 5) {
        "HÁ INDÍCIOS QUE MERECEM TESTE CONTROLADO"
    }
    else {
        "LENTIDÃO DETECTADA, MAS SEM PROVA DE CAUSA NAS RESTRIÇÕES"
    }

    $recommendations.Add("Nao reverta politicas as cegas. Se houver indicio, faca teste A/B em janela curta: medir, remover restricao, reiniciar/sair da sessao, medir novamente, e restaurar se necessario.") | Out-Null
    $recommendations.Add("Se o relatorio apontar CPU, DPC, disco ou memoria, priorize drivers, Windows Update, armazenamento e processos de fundo antes de culpar as restricoes.") | Out-Null
    $recommendations.Add("Para wallpaper: confirme que o arquivo existe localmente, nao esta em rede e nao e pesado demais.") | Out-Null
    $recommendations.Add("Para jogos: servicos Xbox/Gaming parados/desabilitados normalmente nao pioram performance; eventos repetidos e que seriam suspeitos.") | Out-Null

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add("ANALISE DE IMPACTO - RESTRICOES DE JOGOS E WALLPAPER")
    $summary.Add("Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
    $summary.Add("")
    $summary.Add("EQUIPAMENTO")
    $summary.Add("Computador: $($MachineIdentity.ComputerName)")
    $summary.Add("Fabricante: $($MachineIdentity.Vendor)")
    $summary.Add("Modelo: $($MachineIdentity.Model)")
    $summary.Add("Windows: $($MachineIdentity.WindowsVersion) build $($MachineIdentity.WindowsBuild)")
    $summary.Add("")
    $summary.Add("VEREDITO")
    $summary.Add($verdict)
    $summary.Add("")
    $summary.Add("EVIDÊNCIAS DE RESTRIÇÃO ATIVA")
    if ($evidence.Count -eq 0) { $summary.Add("- Nenhuma evidência de restrição ativa foi classificada.") }
    foreach ($item in $evidence) { $summary.Add("- $item") }
    $summary.Add("")
    $summary.Add("PONTOS DE ATENÇÃO")
    if ($findings.Count -eq 0) { $summary.Add("- Nenhum ponto de atenção encontrado.") }
    foreach ($item in $findings) { $summary.Add("- $item") }
    $summary.Add("")
    $summary.Add("O QUE NÃO APONTA PARA AS RESTRIÇÕES")
    foreach ($item in $notEvidence) { $summary.Add("- $item") }
    $summary.Add("")
    $summary.Add("RECOMENDAÇÕES")
    foreach ($item in $recommendations) { $summary.Add("- $item") }
    $summary.Add("")
    $summary.Add("ARQUIVOS ÚTEIS")
    $summary.Add("- 10_REGISTRO_JOGOS.csv")
    $summary.Add("- 11_SERVICOS_JOGOS.csv")
    $summary.Add("- 21_POLITICAS_WALLPAPER_USUARIOS_CARREGADOS.csv")
    $summary.Add("- 30_EVENTOS_RELEVANTES.csv")
    $summary.Add("- 40_AMOSTRAS_PERFORMANCE.csv")
    $summary.Add("- 41_PROCESSOS_TOP_CPU_IO.csv")

    Save-Text -Path (Join-Path $LogDir "RESULTADO_LEIA_PRIMEIRO.txt") -Content $summary

    Write-Host ""
    Write-Host $verdict -ForegroundColor Yellow
    return $verdict
}

if (-not (Test-Administrator)) {
    Write-Host "Solicitando permissao de Administrador..." -ForegroundColor Yellow
    Start-Process powershell.exe `
        -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -DurationSeconds $DurationSeconds -IntervalSeconds $IntervalSeconds -EventDays $EventDays" `
        -Verb RunAs
    exit
}

$machineIdentityModule = Find-MachineIdentityModule
if ($machineIdentityModule) {
    try {
        . $machineIdentityModule
    }
    catch {
        Write-Warning "Falha ao carregar MachineIdentity.ps1: $($_.Exception.Message). A identificacao basica interna sera usada."
    }
}
else {
    Write-Warning "MachineIdentity.ps1 nao foi encontrado. A identificacao basica interna sera usada."
}

if (-not (Get-Command -Name Get-MachineIdentity -CommandType Function -ErrorAction SilentlyContinue)) {
    function Get-MachineIdentity {
        Get-BasicMachineIdentity
    }
}

if (-not (Get-Command -Name Save-MachineIdentity -CommandType Function -ErrorAction SilentlyContinue)) {
    function Save-MachineIdentity {
        param(
            [Parameter(Mandatory)] [object]$Identity,
            [Parameter(Mandatory)] [string]$Path
        )

        Save-BasicMachineIdentity -Identity $Identity -Path $Path
    }
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$desktop = [Environment]::GetFolderPath("Desktop")
$logDir = Join-Path $desktop "Analise_Impacto_Restricoes_$timestamp"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Start-Transcript -Path (Join-Path $logDir "00_TRANSCRICAO.txt") -Force | Out-Null

try {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " ANALISE DE IMPACTO - JOGOS E WALLPAPER" -ForegroundColor Cyan
    Write-Host " Somente leitura: nenhuma restricao sera alterada" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    $machineIdentity = Get-MachineIdentity
    Save-MachineIdentity -Identity $machineIdentity -Path (Join-Path $logDir "01_IDENTIFICACAO.txt")

    $gaming = Get-GamingRestrictionState -LogDir $logDir
    $wallpaper = Get-WallpaperRestrictionState -LogDir $logDir
    $events = Get-RelevantEvents -LogDir $logDir -Days $EventDays
    $performance = Invoke-PerformanceSampling -LogDir $logDir -DurationSeconds $DurationSeconds -IntervalSeconds $IntervalSeconds
    $verdict = New-ImpactSummary -LogDir $logDir -MachineIdentity $machineIdentity -Gaming $gaming -Wallpaper $wallpaper -Events $events -Performance $performance

    Stop-Transcript | Out-Null

    $zipPath = "$logDir.zip"
    Compress-Archive -Path $logDir -DestinationPath $zipPath -CompressionLevel Optimal -Force

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " ANALISE CONCLUIDA" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "Resultado: $verdict"
    Write-Host ""
    Write-Host "Relatorio principal:"
    Write-Host (Join-Path $logDir "RESULTADO_LEIA_PRIMEIRO.txt") -ForegroundColor Cyan
    Write-Host ""
    Write-Host "ZIP:"
    Write-Host $zipPath -ForegroundColor Cyan
}
catch {
    $errorLines = New-Object System.Collections.Generic.List[string]
    $errorLines.Add("MENSAGEM") | Out-Null
    $errorLines.Add([string]$_.Exception.Message) | Out-Null
    $errorLines.Add("") | Out-Null
    $errorLines.Add("TIPO") | Out-Null
    $errorLines.Add([string]$_.Exception.GetType().FullName) | Out-Null
    $errorLines.Add("") | Out-Null
    $errorLines.Add("POSICAO") | Out-Null
    $errorLines.Add([string]$_.InvocationInfo.PositionMessage) | Out-Null
    $errorLines.Add("") | Out-Null
    $errorLines.Add("PILHA") | Out-Null
    $errorLines.Add([string]$_.ScriptStackTrace) | Out-Null
    $errorLines.Add("") | Out-Null
    $errorLines.Add("DETALHES") | Out-Null
    $errorLines.Add([string]($_ | Out-String)) | Out-Null
    $errorText = $errorLines

    Save-Text -Path (Join-Path $logDir "ERRO_FATAL.txt") -Content $errorText
    try { Stop-Transcript | Out-Null } catch {}
    Write-Host "Erro durante a analise: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host "Posicao do erro:" -ForegroundColor Yellow
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Yellow
    }
    Write-Host "Detalhes gravados em:" -ForegroundColor Yellow
    Write-Host (Join-Path $logDir "ERRO_FATAL.txt") -ForegroundColor Cyan
    exit 1
}

Read-Host "Pressione ENTER para fechar"
