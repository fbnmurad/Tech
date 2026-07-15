#requires -version 5.1
<#
  ANÁLISE DE DELAY/CONGELAMENTOS DO MOUSE
  Equipamento-alvo: qualquer computador Windows, com identificação automática

  O script:
  - coleta dados de CPU, DPC, interrupções, memória, disco e processos;
  - verifica mouse, touchpad, Bluetooth, USB, vídeo e eventos do Windows;
  - identifica processos de atualização que podem causar travamentos temporários;
  - oferece correções conservadoras e reversíveis;
  - não instala drivers de terceiros e não desabilita proteções do Windows.
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

function Write-Title {
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

function Get-ActivePowerSchemeGuid {
    $text = (& powercfg.exe /getactivescheme 2>&1 | Out-String)
    $match = [regex]::Match($text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($match.Success) {
        return $match.Value
    }
    return $null
}

function Get-PowerSettingIndices {
    param(
        [string]$SchemeGuid,
        [string]$SubGroupGuid,
        [string]$SettingGuid
    )

    $text = (& powercfg.exe /query $SchemeGuid $SubGroupGuid $SettingGuid 2>&1 | Out-String)
    $matches = [regex]::Matches($text, '0x[0-9a-fA-F]{8}')

    if ($matches.Count -ge 2) {
        $acText = $matches[$matches.Count - 2].Value.Substring(2)
        $dcText = $matches[$matches.Count - 1].Value.Substring(2)

        return [pscustomobject]@{
            AC = [Convert]::ToInt32($acText, 16)
            DC = [Convert]::ToInt32($dcText, 16)
            Raw = $text
        }
    }

    return [pscustomobject]@{
        AC = $null
        DC = $null
        Raw = $text
    }
}

function Get-RelevantDevices {
    Get-CimInstance Win32_PnPEntity |
        Where-Object {
            $_.PNPClass -in @("Mouse","Keyboard","HIDClass","Bluetooth","USB","Display","Net") -or
            $_.Name -match "(?i)mouse|touchpad|trackpoint|synaptics|elan|ultranav|bluetooth|usb input|integrated camera|intel.*graphics"
        } |
        Select-Object Name, PNPClass, Manufacturer, Status, ConfigManagerErrorCode, DeviceID |
        Sort-Object PNPClass, Name
}

function Get-RelevantDrivers {
    Get-CimInstance Win32_PnPSignedDriver |
        Where-Object {
            $_.DeviceClass -in @("MOUSE","KEYBOARD","HIDCLASS","BLUETOOTH","USB","DISPLAY","NET") -or
            $_.DeviceName -match "(?i)mouse|touchpad|trackpoint|synaptics|elan|ultranav|bluetooth|usb input|intel.*graphics"
        } |
        Select-Object DeviceName, DeviceClass, Manufacturer, DriverProviderName,
            DriverVersion, DriverDate, IsSigned, InfName, DeviceID |
        Sort-Object DeviceClass, DeviceName
}

function Get-ProblemDevices {
    Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
        Select-Object Name, PNPClass, Manufacturer, Status, ConfigManagerErrorCode, DeviceID |
        Sort-Object ConfigManagerErrorCode, Name
}

function Find-LenovoSystemUpdate {
    $paths = @(
        "$env:ProgramFiles\Lenovo\System Update\tvsu.exe",
        "${env:ProgramFiles(x86)}\Lenovo\System Update\tvsu.exe"
    )

    foreach ($path in $paths) {
        if ($path -and (Test-Path $path)) {
            return $path
        }
    }

    return $null
}

function Open-OemUpdateTool {
    param(
        [object]$Identity,
        [object]$SupportInfo
    )

    if ($null -eq $SupportInfo) {
        $SupportInfo = Get-OemSupportInfo -Identity $Identity
    }

    if ([string]::IsNullOrWhiteSpace([string]$SupportInfo.ToolPath)) {
        Write-Host "$($SupportInfo.ToolName) não foi encontrado." -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace([string]$SupportInfo.InstallUrl)) {
            Start-Process $SupportInfo.InstallUrl
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$SupportInfo.SupportUrl)) {
            Start-Process $SupportInfo.SupportUrl
        }
        else {
            Write-Host "Sem ferramenta OEM conhecida para este fabricante. Use Windows Update ou o site oficial do fabricante." -ForegroundColor Yellow
        }
        return
    }

    try {
        $item = Get-Item -LiteralPath ([string]$SupportInfo.ToolPath) -ErrorAction Stop
        $leafName = [IO.Path]::GetFileName($item.FullName)
        if ($leafName -ieq "dcu-cli.exe") {
            Write-Host "Dell Command Update CLI detectado. Abrindo a página oficial e a pasta da ferramenta para uso manual." -ForegroundColor Yellow
            if ($SupportInfo.InstallUrl) { Start-Process $SupportInfo.InstallUrl }
            Start-Process explorer.exe -ArgumentList "/select,`"$($item.FullName)`""
        }
        else {
            Start-Process -FilePath $item.FullName -Verb RunAs
        }
    }
    catch {
        Write-Host "Não foi possível abrir a ferramenta OEM: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-ResultZip {
    param([string]$LogDir)

    $zipPath = "$LogDir.zip"
    try {
        if (Test-Path $zipPath) {
            Remove-Item $zipPath -Force
        }
        Compress-Archive -Path $LogDir -DestinationPath $zipPath -CompressionLevel Optimal -Force
        return $zipPath
    }
    catch {
        return $null
    }
}

function Collect-StaticDiagnostics {
    param([string]$LogDir)

    Write-Title "Inventário do sistema e dos dispositivos"

    $machineIdentity = Get-MachineIdentity
    $supportInfo = Get-OemSupportInfo -Identity $machineIdentity
    $cs = $machineIdentity.RawComputerSystem
    $csp = $machineIdentity.RawProduct
    $bios = $machineIdentity.RawBios
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

    $identity = [pscustomobject]@{
        Fabricante        = $machineIdentity.Manufacturer
        FabricanteNormalizado = $machineIdentity.Vendor
        Modelo            = $machineIdentity.Model
        Produto           = $machineIdentity.ProductName
        VersaoProduto     = $machineIdentity.ProductVersion
        TipoLenovo        = $machineIdentity.LenovoMachineType
        ServiceTagDell    = $machineIdentity.DellServiceTag
        NumeroSerie       = $machineIdentity.SerialNumber
        BIOS              = $machineIdentity.BiosVersion
        WindowsEdicao     = $cv.EditionID
        WindowsVersao     = $cv.DisplayVersion
        WindowsBuild      = "$($cv.CurrentBuild).$($cv.UBR)"
        RAMTotalGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        UltimaInicializacao = $os.LastBootUpTime
        FerramentaOEM     = $supportInfo.ToolName
        CaminhoFerramentaOEM = $supportInfo.ToolPath
    }

    $identity | Format-List | Out-String -Width 4096 |
        Save-Text -Path (Join-Path $LogDir "01_IDENTIFICACAO.txt")

    Get-CimInstance Win32_PointingDevice |
        Select-Object Name, Manufacturer, Description, DeviceID, PNPDeviceID,
            Status, ConfigManagerErrorCode, NumberOfButtons, HardwareType |
        Format-List |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $LogDir "02_DISPOSITIVOS_APONTADORES.txt")

    $devices = Get-RelevantDevices
    $devices |
        Export-Csv (Join-Path $LogDir "03_DISPOSITIVOS_RELEVANTES.csv") -NoTypeInformation -Encoding UTF8

    $drivers = Get-RelevantDrivers
    $drivers |
        Export-Csv (Join-Path $LogDir "04_DRIVERS_RELEVANTES.csv") -NoTypeInformation -Encoding UTF8

    $problemDevices = Get-ProblemDevices
    $problemDevices |
        Export-Csv (Join-Path $LogDir "05_DISPOSITIVOS_COM_ERRO.csv") -NoTypeInformation -Encoding UTF8

    Get-CimInstance Win32_Service |
        Where-Object {
            $_.Name -in @("bthserv","hidserv","DeviceAssociationService","DPS","SysMain","WSearch") -or
            $_.DisplayName -match "(?i)bluetooth|human interface|dispositivo|diagnostic|sysmain|pesquisa"
        } |
        Select-Object Name, DisplayName, State, StartMode, Status, PathName |
        Format-Table -AutoSize |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $LogDir "06_SERVICOS_RELEVANTES.txt")

    Get-ItemProperty "HKCU:\Control Panel\Mouse" -ErrorAction SilentlyContinue |
        Select-Object MouseSensitivity, MouseSpeed, MouseThreshold1, MouseThreshold2,
            MouseTrails, SwapMouseButtons |
        Format-List |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $LogDir "07_CONFIGURACAO_MOUSE.txt")

    (& powercfg.exe /getactivescheme 2>&1 | Out-String) |
        Save-Text -Path (Join-Path $LogDir "08_PLANO_ENERGIA_ATIVO.txt")

    (& powercfg.exe /requests 2>&1 | Out-String) |
        Save-Text -Path (Join-Path $LogDir "09_POWER_REQUESTS.txt")

    (& netsh.exe wlan show interfaces 2>&1 | Out-String) |
        Save-Text -Path (Join-Path $LogDir "10_WIFI_INTERFACE.txt")

    (& netsh.exe wlan show drivers 2>&1 | Out-String) |
        Save-Text -Path (Join-Path $LogDir "11_WIFI_DRIVERS.txt")

    Get-Process |
        Sort-Object CPU -Descending |
        Select-Object -First 30 Name, Id, CPU, WorkingSet64, StartTime, Path |
        Format-Table -AutoSize |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $LogDir "12_PROCESSOS_INICIAIS.txt")

    $updateProcesses = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match "^(SetupHost|TiWorker|MoUsoCoreWorker|TrustedInstaller|Windows10UpgraderApp|Windows11InstallationAssistant|UsoClient|MsMpEng|SearchIndexer|OneDrive)$"
        } |
        Select-Object Name, Id, CPU, WorkingSet64, StartTime, Path

    $updateProcesses |
        Format-Table -AutoSize |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $LogDir "13_PROCESSOS_ATUALIZACAO_E_INDEXACAO.txt")

    $systemProviders = @(
        "Microsoft-Windows-WHEA-Logger",
        "disk",
        "stornvme",
        "storahci",
        "Ntfs",
        "Display",
        "igfx",
        "BTHUSB",
        "Microsoft-Windows-Kernel-PnP",
        "Microsoft-Windows-DriverFrameworks-UserMode",
        "Microsoft-Windows-USB-USBHUB3",
        "Microsoft-Windows-USB-USBXHCI",
        "Microsoft-Windows-Resource-Exhaustion-Detector",
        "Microsoft-Windows-Kernel-Power"
    )

    $systemEvents = Get-WinEvent -FilterHashtable @{
        LogName = "System"
        StartTime = (Get-Date).AddDays(-30)
        Level = 1,2,3
    } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -in $systemProviders } |
        Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message

    $systemEvents |
        Format-List |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $LogDir "14_EVENTOS_SISTEMA_30_DIAS.txt")

    $applicationEvents = Get-WinEvent -FilterHashtable @{
        LogName = "Application"
        StartTime = (Get-Date).AddDays(-30)
        Level = 1,2,3
    } -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProviderName -in @("Application Hang","Application Error","Windows Error Reporting")
        } |
        Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message

    $applicationEvents |
        Format-List |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $LogDir "15_TRAVAMENTOS_APLICACOES_30_DIAS.txt")

    try {
        Get-CimInstance Win32_ReliabilityRecords -ErrorAction Stop |
            Where-Object { $_.TimeGenerated -ge (Get-Date).AddDays(-30) } |
            Sort-Object TimeGenerated -Descending |
            Select-Object TimeGenerated, SourceName, ProductName, EventIdentifier, Message |
            Format-List |
            Out-String -Width 4096 |
            Save-Text -Path (Join-Path $LogDir "16_HISTORICO_CONFIABILIDADE.txt")
    }
    catch {
        Save-Text -Path (Join-Path $LogDir "16_HISTORICO_CONFIABILIDADE.txt") `
            -Content "Histórico indisponível: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        ComputerSystem  = $cs
        Identity        = $identity
        MachineIdentity = $machineIdentity
        SupportInfo     = $supportInfo
        Devices         = $devices
        Drivers         = $drivers
        ProblemDevices  = $problemDevices
        UpdateProcesses = $updateProcesses
        SystemEvents    = $systemEvents
        ApplicationEvents = $applicationEvents
    }
}

function Run-PerformanceSampling {
    param(
        [string]$LogDir,
        [int]$DurationSeconds = 90,
        [int]$IntervalSeconds = 2
    )

    Write-Title "Monitoramento de desempenho por $DurationSeconds segundos"
    Write-Host "Durante o teste, use o notebook normalmente e movimente o mouse." -ForegroundColor Yellow
    Write-Host "Tente reproduzir o pequeno congelamento. Não abra programas pesados de propósito." -ForegroundColor Yellow
    Write-Host ""

    $logicalProcessors = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if ($logicalProcessors -lt 1) { $logicalProcessors = 1 }

    $samples = New-Object System.Collections.Generic.List[object]
    $processTotals = @{}
    $iterations = [math]::Max(1, [math]::Floor($DurationSeconds / $IntervalSeconds))

    for ($i = 1; $i -le $iterations; $i++) {
        try {
            $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
            $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
            $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk |
                Where-Object { $_.Name -eq "_Total" } |
                Select-Object -First 1
            $system = Get-CimInstance Win32_PerfFormattedData_PerfOS_System
            $procPerf = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
                Where-Object {
                    $_.Name -notin @("_Total","Idle") -and $_.IDProcess -gt 0
                }

            $topCpu = $procPerf |
                Sort-Object {[double]$_.PercentProcessorTime} -Descending |
                Select-Object -First 5

            $topIo = $procPerf |
                Sort-Object {[double]$_.IODataBytesPersec} -Descending |
                Select-Object -First 5

            foreach ($p in $topCpu) {
                $normalized = [math]::Round(([double]$p.PercentProcessorTime / $logicalProcessors), 2)
                if (-not $processTotals.ContainsKey($p.Name)) {
                    $processTotals[$p.Name] = 0.0
                }
                $processTotals[$p.Name] += $normalized
            }

            $topCpuText = ($topCpu | ForEach-Object {
                $pct = [math]::Round(([double]$_.PercentProcessorTime / $logicalProcessors), 1)
                "{0}={1}%" -f $_.Name, $pct
            }) -join " | "

            $topIoText = ($topIo | ForEach-Object {
                $mb = [math]::Round(([double]$_.IODataBytesPersec / 1MB), 2)
                "{0}={1}MB/s" -f $_.Name, $mb
            }) -join " | "

            $sample = [pscustomobject]@{
                DataHora              = Get-Date
                CPUPercentual         = [double]$cpu.PercentProcessorTime
                DPCPercentual         = [double]$cpu.PercentDPCTime
                InterrupcaoPercentual = [double]$cpu.PercentInterruptTime
                FilaProcessador       = [double]$system.ProcessorQueueLength
                MemoriaDisponivelMB   = [double]$mem.AvailableMBytes
                PaginasPorSegundo     = [double]$mem.PagesPersec
                DiscoPercentual       = if ($disk) { [double]$disk.PercentDiskTime } else { 0 }
                FilaDisco             = if ($disk) { [double]$disk.AvgDiskQueueLength } else { 0 }
                DiscoMBPorSegundo     = if ($disk) { [math]::Round(([double]$disk.DiskBytesPersec / 1MB), 2) } else { 0 }
                TopCPU                = $topCpuText
                TopIO                 = $topIoText
            }

            $samples.Add($sample) | Out-Null

            $remaining = [math]::Max(0, $DurationSeconds - ($i * $IntervalSeconds))
            Write-Progress -Activity "Monitorando CPU, DPC, memória e disco" `
                -Status "$remaining segundos restantes" `
                -PercentComplete (($i / $iterations) * 100)
        }
        catch {
            Save-Text -Path (Join-Path $LogDir ("ERRO_AMOSTRA_{0}.txt" -f $i)) `
                -Content $_.Exception.Message
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    Write-Progress -Activity "Monitorando CPU, DPC, memória e disco" -Completed

    $samples |
        Export-Csv (Join-Path $LogDir "20_AMOSTRAS_DESEMPENHO.csv") -NoTypeInformation -Encoding UTF8

    $topAggregated = foreach ($name in $processTotals.Keys) {
        [pscustomobject]@{
            Processo = $name
            PontuacaoCPUAcumulada = [math]::Round([double]$processTotals[$name], 2)
        }
    }

    $topAggregated |
        Sort-Object PontuacaoCPUAcumulada -Descending |
        Select-Object -First 20 |
        Export-Csv (Join-Path $LogDir "21_PROCESSOS_MAIS_RECORRENTES.csv") -NoTypeInformation -Encoding UTF8

    return [pscustomobject]@{
        Samples = $samples
        TopProcesses = $topAggregated
    }
}

function Build-DiagnosticSummary {
    param(
        [string]$LogDir,
        [object]$Static,
        [object]$Performance
    )

    Write-Title "Análise automática dos resultados"

    $samples = @($Performance.Samples)
    $findings = New-Object System.Collections.Generic.List[string]
    $positives = New-Object System.Collections.Generic.List[string]

    if ($samples.Count -eq 0) {
        $findings.Add("O monitoramento de desempenho não produziu amostras válidas.") | Out-Null
    }
    else {
        $avgCpu = [math]::Round(($samples | Measure-Object CPUPercentual -Average).Average, 1)
        $maxCpu = [math]::Round(($samples | Measure-Object CPUPercentual -Maximum).Maximum, 1)
        $avgDpc = [math]::Round(($samples | Measure-Object DPCPercentual -Average).Average, 2)
        $maxDpc = [math]::Round(($samples | Measure-Object DPCPercentual -Maximum).Maximum, 2)
        $avgInterrupt = [math]::Round(($samples | Measure-Object InterrupcaoPercentual -Average).Average, 2)
        $maxInterrupt = [math]::Round(($samples | Measure-Object InterrupcaoPercentual -Maximum).Maximum, 2)
        $maxDisk = [math]::Round(($samples | Measure-Object DiscoPercentual -Maximum).Maximum, 1)
        $maxDiskQueue = [math]::Round(($samples | Measure-Object FilaDisco -Maximum).Maximum, 2)
        $minMemory = [math]::Round(($samples | Measure-Object MemoriaDisponivelMB -Minimum).Minimum, 0)
        $maxProcessorQueue = [math]::Round(($samples | Measure-Object FilaProcessador -Maximum).Maximum, 1)

        $logical = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
        $totalMemoryMB = [math]::Round(([double]$Static.ComputerSystem.TotalPhysicalMemory / 1MB), 0)
        $memoryThreshold = [math]::Max([double]1024, [double]($totalMemoryMB * 0.10))

        if ($avgCpu -ge 70 -or $maxCpu -ge 95) {
            $findings.Add("Foram encontrados picos relevantes de CPU: média $avgCpu%, máximo $maxCpu%. Consulte os processos recorrentes.") | Out-Null
        } else {
            $positives.Add("CPU sem saturação prolongada: média $avgCpu%, máximo $maxCpu%.") | Out-Null
        }

        if ($avgDpc -ge 3 -or $maxDpc -ge 10) {
            $findings.Add("Tempo de DPC elevado: média $avgDpc%, máximo $maxDpc%. Isso pode indicar latência de driver, frequentemente rede, Bluetooth, USB, áudio ou vídeo.") | Out-Null
        } else {
            $positives.Add("Tempo de DPC sem elevação importante: média $avgDpc%, máximo $maxDpc%.") | Out-Null
        }

        if ($avgInterrupt -ge 2 -or $maxInterrupt -ge 5) {
            $findings.Add("Tempo de interrupções de hardware elevado: média $avgInterrupt%, máximo $maxInterrupt%.") | Out-Null
        } else {
            $positives.Add("Interrupções de hardware sem elevação importante: média $avgInterrupt%, máximo $maxInterrupt%.") | Out-Null
        }

        if ($maxDisk -ge 95 -and $maxDiskQueue -ge 2) {
            $findings.Add("O armazenamento apresentou saturação: uso máximo $maxDisk% e fila máxima $maxDiskQueue.") | Out-Null
        } else {
            $positives.Add("Nenhuma saturação conjunta relevante de disco e fila foi detectada.") | Out-Null
        }

        if ($minMemory -lt $memoryThreshold) {
            $findings.Add("A memória disponível caiu para $minMemory MB, indicando pressão de memória.") | Out-Null
        } else {
            $positives.Add("Memória disponível mínima durante o teste: $minMemory MB.") | Out-Null
        }

        if ($maxProcessorQueue -gt ($logical * 2)) {
            $findings.Add("A fila do processador chegou a $maxProcessorQueue para $logical processadores lógicos.") | Out-Null
        }

        $performanceText = @"
MÉTRICAS DO TESTE

Amostras válidas: $($samples.Count)
CPU média: $avgCpu%
CPU máxima: $maxCpu%
DPC médio: $avgDpc%
DPC máximo: $maxDpc%
Interrupção média: $avgInterrupt%
Interrupção máxima: $maxInterrupt%
Disco máximo: $maxDisk%
Fila máxima do disco: $maxDiskQueue
Memória disponível mínima: $minMemory MB
Fila máxima do processador: $maxProcessorQueue
"@
        Save-Text -Path (Join-Path $LogDir "22_RESUMO_METRICAS.txt") -Content $performanceText
    }

    if (@($Static.ProblemDevices).Count -gt 0) {
        $findings.Add("Há $(@($Static.ProblemDevices).Count) dispositivo(s) com código de erro no Gerenciador de Dispositivos.") | Out-Null
    } else {
        $positives.Add("Nenhum dispositivo com código de erro foi encontrado.") | Out-Null
    }

    if (@($Static.UpdateProcesses).Count -gt 0) {
        $names = (@($Static.UpdateProcesses) | Select-Object -ExpandProperty Name -Unique) -join ", "
        $findings.Add("Processos de atualização, indexação ou segurança estavam ativos: $names. Eles podem causar travamentos temporários.") | Out-Null
    }

    $seriousSystemEvents = @($Static.SystemEvents | Where-Object {
        $_.ProviderName -in @(
            "Microsoft-Windows-WHEA-Logger",
            "disk",
            "stornvme",
            "storahci",
            "Display",
            "igfx",
            "BTHUSB",
            "Microsoft-Windows-USB-USBHUB3",
            "Microsoft-Windows-USB-USBXHCI",
            "Microsoft-Windows-Resource-Exhaustion-Detector"
        )
    })

    if ($seriousSystemEvents.Count -gt 0) {
        $findings.Add("Existem $($seriousSystemEvents.Count) eventos recentes relacionados a hardware, vídeo, Bluetooth, USB, armazenamento ou falta de recursos. Consulte 14_EVENTOS_SISTEMA_30_DIAS.txt.") | Out-Null
    } else {
        $positives.Add("Nenhum evento selecionado de hardware, vídeo, Bluetooth, USB ou armazenamento foi encontrado nos últimos 30 dias.") | Out-Null
    }

    $wirelessText = (& netsh.exe wlan show interfaces 2>&1 | Out-String)
    $channelMatch = [regex]::Match($wirelessText, '(?im)^\s*(Channel|Canal)\s*:\s*(\d+)\s*$')
    $bluetoothInput = @($Static.Devices | Where-Object {
        ($_.PNPClass -in @("Mouse","HIDClass")) -and $_.DeviceID -match "(?i)BTH|Bluetooth"
    })

    if ($channelMatch.Success -and $bluetoothInput.Count -gt 0) {
        $channel = [int]$channelMatch.Groups[2].Value
        if ($channel -le 14) {
            $findings.Add("Foi detectado dispositivo apontador Bluetooth enquanto o Wi-Fi usa canal 2,4 GHz ($channel). Interferência de rádio é uma causa possível; teste a rede de 5 GHz.") | Out-Null
        }
    }

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add("ANÁLISE DE DELAY/CONGELAMENTOS DO MOUSE")
    $summary.Add("Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
    $summary.Add("")
    $summary.Add("Equipamento: $($Static.Identity.Fabricante) $($Static.Identity.Modelo)")
    $summary.Add("Fabricante normalizado: $($Static.Identity.FabricanteNormalizado)")
    $summary.Add("Tipo Lenovo: $($Static.Identity.TipoLenovo)")
    $summary.Add("Service Tag Dell: $($Static.Identity.ServiceTagDell)")
    $summary.Add("Windows: $($Static.Identity.WindowsVersao) build $($Static.Identity.WindowsBuild)")
    $summary.Add("")
    $summary.Add("PONTOS DE ATENÇÃO")
    if ($findings.Count -eq 0) {
        $summary.Add("Nenhuma causa objetiva foi encontrada na janela monitorada.")
        $summary.Add("Como o sintoma é intermitente, execute a coleta WPR exatamente enquanto o congelamento acontece.")
    }
    else {
        foreach ($item in $findings) {
            $summary.Add("- $item")
        }
    }
    $summary.Add("")
    $summary.Add("RESULTADOS POSITIVOS")
    if ($positives.Count -eq 0) {
        $summary.Add("Nenhum resultado positivo adicional foi classificado automaticamente.")
    }
    else {
        foreach ($item in $positives) {
            $summary.Add("- $item")
        }
    }
    $summary.Add("")
    $summary.Add("PRÓXIMAS AÇÕES")
    $summary.Add("1. Reinicie o computador caso existam atualizações ou instalações pendentes.")
    $summary.Add("2. Atualize drivers pela ferramenta oficial do fabricante, quando disponível: $($Static.Identity.FerramentaOEM).")
    $summary.Add("3. Para mouse USB ou receptor sem fio, teste outra porta diretamente no computador.")
    $summary.Add("4. Para Bluetooth, teste com Wi-Fi em 5 GHz e sem outros dispositivos Bluetooth próximos.")
    $summary.Add("5. Se o travamento continuar, execute a coleta avançada WPR.")
    $summary.Add("")
    $summary.Add("O script não certifica defeitos físicos no mouse, touchpad, placa-mãe ou portas.")

    $summary |
        Out-File (Join-Path $LogDir "RESULTADO_LEIA_PRIMEIRO.txt") -Encoding utf8 -Width 4096

    Write-Host ""
    if ($findings.Count -eq 0) {
        Write-Host "Nenhuma causa objetiva foi encontrada durante a amostra." -ForegroundColor Yellow
    } else {
        Write-Host "Foram encontrados $($findings.Count) ponto(s) de atenção." -ForegroundColor Yellow
    }

    return [pscustomobject]@{
        Findings = $findings
        Positives = $positives
    }
}

function Run-FullDiagnostic {
    param(
        [string]$BaseLogDir,
        [int]$DurationSeconds = 90
    )

    $logDir = Join-Path $BaseLogDir ("Diagnostico_{0}" -f (Get-Date -Format "HHmmss"))
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    Start-Transcript -Path (Join-Path $logDir "00_TRANSCRICAO.txt") -Force | Out-Null

    try {
        $static = Collect-StaticDiagnostics -LogDir $logDir
        $performance = Run-PerformanceSampling -LogDir $logDir -DurationSeconds $DurationSeconds -IntervalSeconds 2
        $null = Build-DiagnosticSummary -LogDir $logDir -Static $static -Performance $performance
    }
    catch {
        $errorDetail = @"
MENSAGEM
$($_.Exception.Message)

TIPO
$($_.Exception.GetType().FullName)

POSIÇÃO
$($_.InvocationInfo.PositionMessage)

PILHA DO POWERSHELL
$($_.ScriptStackTrace)

DETALHES COMPLETOS
$($_ | Out-String)
"@
        Save-Text -Path (Join-Path $logDir "ERRO_FATAL.txt") -Content $errorDetail

        # Mesmo que a classificação automática falhe, preserva um resumo útil
        # confirmando que os dados brutos foram coletados.
        if (-not (Test-Path (Join-Path $logDir "RESULTADO_LEIA_PRIMEIRO.txt"))) {
            @"
ANÁLISE DE DELAY/CONGELAMENTOS DO MOUSE

A coleta de dados foi concluída, porém a geração automática do resumo encontrou um erro.

Os dados brutos permanecem disponíveis, principalmente:
- 20_AMOSTRAS_DESEMPENHO.csv
- 21_PROCESSOS_MAIS_RECORRENTES.csv
- 14_EVENTOS_SISTEMA_30_DIAS.txt
- 15_TRAVAMENTOS_APLICACOES_30_DIAS.txt
- 04_DRIVERS_RELEVANTES.csv
- 05_DISPOSITIVOS_COM_ERRO.csv

Consulte ERRO_FATAL.txt para a linha e a pilha exatas.
"@ | Out-File (Join-Path $logDir "RESULTADO_LEIA_PRIMEIRO.txt") -Encoding utf8 -Width 4096
        }

        Write-Host "O diagnóstico encontrou um erro na geração do resumo: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Os dados brutos foram preservados no ZIP." -ForegroundColor Yellow
    }

    Stop-Transcript | Out-Null

    $zip = New-ResultZip -LogDir $logDir

    Write-Host ""
    Write-Host "Relatório:" -ForegroundColor Cyan
    Write-Host (Join-Path $logDir "RESULTADO_LEIA_PRIMEIRO.txt")
    if ($zip) {
        Write-Host "ZIP para análise:" -ForegroundColor Cyan
        Write-Host $zip
    }

    return $logDir
}

function Apply-ConservativeFixes {
    param([string]$BaseLogDir)

    $logDir = Join-Path $BaseLogDir ("Correcoes_{0}" -f (Get-Date -Format "HHmmss"))
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    Start-Transcript -Path (Join-Path $logDir "00_TRANSCRICAO.txt") -Force | Out-Null

    Write-Title "Correções conservadoras"

    Write-Host "Estas correções são voltadas a pausas de dispositivos USB/Bluetooth e energia." -ForegroundColor Yellow
    Write-Host "Elas podem aumentar um pouco o consumo da bateria." -ForegroundColor Yellow
    Write-Host "Nenhum driver será removido e nenhum ajuste obscuro de Registro será aplicado." -ForegroundColor Yellow
    Write-Host ""

    $confirmation = Read-Host "Digite CORRIGIR para continuar"
    if ($confirmation.Trim().ToUpperInvariant() -ne "CORRIGIR") {
        Stop-Transcript | Out-Null
        return
    }

    $usbSubGroup = "2a737441-1930-4402-8d77-b2bebba308a3"
    $usbSelective = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
    $wifiSubGroup = "19cbb8fa-5279-450e-9fac-8a3d5fedd0c1"
    $wifiPowerMode = "12bbebe6-58d6-4636-95bb-3217ef867c1a"

    $activeScheme = Get-ActivePowerSchemeGuid
    $usbBefore = Get-PowerSettingIndices -SchemeGuid $activeScheme -SubGroupGuid $usbSubGroup -SettingGuid $usbSelective
    $wifiBefore = Get-PowerSettingIndices -SchemeGuid $activeScheme -SubGroupGuid $wifiSubGroup -SettingGuid $wifiPowerMode

    $beforeText = @"
Plano ativo antes: $activeScheme

USB Selective Suspend:
AC: $($usbBefore.AC)
DC: $($usbBefore.DC)

Wi-Fi Power Saving Mode:
AC: $($wifiBefore.AC)
DC: $($wifiBefore.DC)
"@
    Save-Text -Path (Join-Path $logDir "01_CONFIGURACAO_ANTES.txt") -Content $beforeText

    try {
        Checkpoint-Computer -Description "Antes de corrigir lag de mouse $(Get-Date -Format 'yyyyMMdd_HHmmss')" `
            -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-Host "Ponto de restauração criado." -ForegroundColor Green
    }
    catch {
        Write-Host "Não foi possível criar ponto de restauração: $($_.Exception.Message)" -ForegroundColor Yellow
        Save-Text -Path (Join-Path $logDir "02_PONTO_RESTAURACAO.txt") -Content $_.Exception.Message
    }

    $revertPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "REVERTER_CORRECOES_LAG_MOUSE.cmd"
    $revertLines = New-Object System.Collections.Generic.List[string]
    $revertLines.Add("@echo off")
    $revertLines.Add("fltmc >nul 2>&1")
    $revertLines.Add("if errorlevel 1 (powershell.exe -NoProfile -Command `"Start-Process -FilePath '%~f0' -Verb RunAs`" & exit /b)")
    $revertLines.Add("echo Restaurando configuracoes anteriores...")

    if ($null -ne $usbBefore.AC) {
        $revertLines.Add("powercfg /setacvalueindex $activeScheme $usbSubGroup $usbSelective $($usbBefore.AC)")
    }
    if ($null -ne $usbBefore.DC) {
        $revertLines.Add("powercfg /setdcvalueindex $activeScheme $usbSubGroup $usbSelective $($usbBefore.DC)")
    }
    if ($null -ne $wifiBefore.AC) {
        $revertLines.Add("powercfg /setacvalueindex $activeScheme $wifiSubGroup $wifiPowerMode $($wifiBefore.AC)")
    }
    if ($null -ne $wifiBefore.DC) {
        $revertLines.Add("powercfg /setdcvalueindex $activeScheme $wifiSubGroup $wifiPowerMode $($wifiBefore.DC)")
    }

    $revertLines.Add("powercfg /setactive $activeScheme")
    $revertLines.Add("echo Configuracoes restauradas. Reinicie o notebook.")
    $revertLines.Add("pause")
    $revertLines | Out-File -FilePath $revertPath -Encoding ascii

    Write-Host "Arquivo de reversão criado em:" -ForegroundColor Green
    Write-Host $revertPath

    Write-Host ""
    Write-Host "Desabilitando a suspensão seletiva USB no plano atual..." -ForegroundColor Cyan
    & powercfg.exe /setacvalueindex $activeScheme $usbSubGroup $usbSelective 0 | Out-Null
    & powercfg.exe /setdcvalueindex $activeScheme $usbSubGroup $usbSelective 0 | Out-Null

    Write-Host "Definindo o adaptador sem fio para máximo desempenho quando ligado à tomada..." -ForegroundColor Cyan
    & powercfg.exe /setacvalueindex $activeScheme $wifiSubGroup $wifiPowerMode 0 | Out-Null

    & powercfg.exe /setactive $activeScheme | Out-Null

    Write-Host "Solicitando nova varredura de dispositivos..." -ForegroundColor Cyan
    & pnputil.exe /scan-devices 2>&1 |
        Out-File (Join-Path $logDir "03_PNPUTIL_SCAN_DEVICES.txt") -Encoding utf8 -Width 4096

    $bluetoothInput = Get-RelevantDevices |
        Where-Object {
            ($_.PNPClass -in @("Mouse","HIDClass")) -and $_.DeviceID -match "(?i)BTH|Bluetooth"
        }

    if (@($bluetoothInput).Count -gt 0) {
        Write-Host ""
        Write-Host "Foi detectado dispositivo apontador Bluetooth." -ForegroundColor Yellow
        $restartBluetooth = Read-Host "Reiniciar agora o serviço Bluetooth? O mouse pode desconectar por alguns segundos. Digite SIM"
        if ($restartBluetooth.Trim().ToUpperInvariant() -eq "SIM") {
            try {
                Restart-Service -Name bthserv -Force -ErrorAction Stop
                Write-Host "Serviço Bluetooth reiniciado." -ForegroundColor Green
            }
            catch {
                Write-Host "Não foi possível reiniciar o Bluetooth: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    $afterScheme = Get-ActivePowerSchemeGuid
    $usbAfter = Get-PowerSettingIndices -SchemeGuid $afterScheme -SubGroupGuid $usbSubGroup -SettingGuid $usbSelective
    $wifiAfter = Get-PowerSettingIndices -SchemeGuid $afterScheme -SubGroupGuid $wifiSubGroup -SettingGuid $wifiPowerMode

    $afterText = @"
Plano ativo depois: $afterScheme

USB Selective Suspend:
AC: $($usbAfter.AC)
DC: $($usbAfter.DC)

Wi-Fi Power Saving Mode:
AC: $($wifiAfter.AC)
DC: $($wifiAfter.DC)

Reversão:
$revertPath
"@
    Save-Text -Path (Join-Path $logDir "04_CONFIGURACAO_DEPOIS.txt") -Content $afterText

    $machineIdentity = Get-MachineIdentity
    $supportInfo = Get-OemSupportInfo -Identity $machineIdentity
    if ($supportInfo.ToolPath) {
        Write-Host ""
        $openOemTool = Read-Host "Abrir $($supportInfo.ToolName) para verificar drivers de vídeo, chipset, touchpad, Bluetooth e rede? Digite SIM"
        if ($openOemTool.Trim().ToUpperInvariant() -eq "SIM") {
            Open-OemUpdateTool -Identity $machineIdentity -SupportInfo $supportInfo
        }
    }

    Stop-Transcript | Out-Null
    $zip = New-ResultZip -LogDir $logDir

    Write-Host ""
    Write-Host "Correções aplicadas. Reinicie o notebook antes de avaliar o resultado." -ForegroundColor Green
    Write-Host "Caso piore, execute o arquivo de reversão criado na Área de Trabalho." -ForegroundColor Yellow
    if ($zip) {
        Write-Host "Relatório das alterações:" -ForegroundColor Cyan
        Write-Host $zip
    }
}

function Run-WprTrace {
    param([string]$BaseLogDir)

    $logDir = Join-Path $BaseLogDir ("WPR_{0}" -f (Get-Date -Format "HHmmss"))
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $etlPath = Join-Path $logDir "LAG_MOUSE_WPR.etl"

    Write-Title "Coleta avançada WPR"
    Write-Host "A gravação terá 60 segundos." -ForegroundColor Yellow
    Write-Host "Durante esse tempo, movimente o mouse e tente reproduzir o congelamento." -ForegroundColor Yellow
    Write-Host "O arquivo ETL pode ficar grande." -ForegroundColor Yellow
    Write-Host ""

    if (-not (Get-Command wpr.exe -ErrorAction SilentlyContinue)) {
        Write-Host "O Windows Performance Recorder não está disponível neste sistema." -ForegroundColor Red
        return
    }

    $statusText = (& wpr.exe -status 2>&1 | Out-String)
    if ($statusText -match "(?i)recording|grava") {
        Write-Host "Já existe uma sessão WPR ativa. Ela não será interrompida." -ForegroundColor Red
        Save-Text -Path (Join-Path $logDir "WPR_STATUS.txt") -Content $statusText
        return
    }

    Write-Host "Iniciando gravação..." -ForegroundColor Cyan
    & wpr.exe -start GeneralProfile -filemode 2>&1 |
        Out-File (Join-Path $logDir "WPR_START.txt") -Encoding utf8 -Width 4096

    Start-Sleep -Seconds 2

    for ($remaining = 60; $remaining -gt 0; $remaining -= 5) {
        Write-Progress -Activity "Gravando desempenho detalhado" `
            -Status "$remaining segundos restantes" `
            -PercentComplete (((60 - $remaining) / 60) * 100)
        Start-Sleep -Seconds 5
    }

    Write-Progress -Activity "Gravando desempenho detalhado" -Completed

    Write-Host "Finalizando e salvando a gravação..." -ForegroundColor Cyan
    & wpr.exe -stop $etlPath 2>&1 |
        Out-File (Join-Path $logDir "WPR_STOP.txt") -Encoding utf8 -Width 4096

    if (Test-Path $etlPath) {
        $sizeMB = [math]::Round((Get-Item $etlPath).Length / 1MB, 1)
        Write-Host "ETL criado: $etlPath ($sizeMB MB)" -ForegroundColor Green
        Save-Text -Path (Join-Path $logDir "LEIA-ME_WPR.txt") -Content @"
Arquivo: $etlPath
Tamanho: $sizeMB MB

Este arquivo deve ser aberto no Windows Performance Analyzer.
Ele permite investigar DPC/ISR, CPU, disco, drivers e travamentos de interface.
"@
    }
    else {
        Write-Host "A gravação não gerou o arquivo ETL esperado." -ForegroundColor Red
    }
}

if (-not (Test-Administrator)) {
    Write-Host "Execute pelo arquivo EXECUTAR_ANALISE_E_CORRECAO.cmd." -ForegroundColor Red
    Read-Host "Pressione ENTER para sair"
    exit 1
}

Import-MachineIdentityModule

$machineIdentity = Get-MachineIdentity
$supportInfo = Get-OemSupportInfo -Identity $machineIdentity

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$desktop = [Environment]::GetFolderPath("Desktop")
$baseLogDir = Join-Path $desktop "Analise_Lag_Mouse_$timestamp"
New-Item -ItemType Directory -Path $baseLogDir -Force | Out-Null

do {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " ANÁLISE DE DELAY E CONGELAMENTOS DO MOUSE" -ForegroundColor Cyan
    Write-Host " $($machineIdentity.Vendor): $($machineIdentity.Model)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[1] Diagnóstico completo de 90 segundos"
    Write-Host "[2] Aplicar correções conservadoras e reversíveis"
    Write-Host "[3] Coleta avançada WPR de 60 segundos"
    Write-Host "[4] Abrir ferramenta oficial do fabricante"
    Write-Host "[5] Sair"
    Write-Host ""

    $choice = Read-Host "Escolha uma opção"

    switch ($choice) {
        "1" {
            $null = Run-FullDiagnostic -BaseLogDir $baseLogDir -DurationSeconds 90
            Read-Host "Pressione ENTER para voltar ao menu"
        }
        "2" {
            Apply-ConservativeFixes -BaseLogDir $baseLogDir
            Read-Host "Pressione ENTER para voltar ao menu"
        }
        "3" {
            Run-WprTrace -BaseLogDir $baseLogDir
            Read-Host "Pressione ENTER para voltar ao menu"
        }
        "4" {
            $machineIdentity = Get-MachineIdentity
            $supportInfo = Get-OemSupportInfo -Identity $machineIdentity
            Open-OemUpdateTool -Identity $machineIdentity -SupportInfo $supportInfo
            Read-Host "Pressione ENTER para voltar ao menu"
        }
        "5" {
            break
        }
        default {
            Write-Host "Opção inválida." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }
} while ($choice -ne "5")
