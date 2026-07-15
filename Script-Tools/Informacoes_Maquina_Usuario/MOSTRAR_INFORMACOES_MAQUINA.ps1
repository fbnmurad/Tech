#requires -version 5.1
<#
  Mostra informações básicas do computador para usuário final.

  Modo de operacao:
  - somente leitura;
  - não exige administrador;
  - mostra o resultado na tela;
  - salva um relatório TXT na pasta do aplicativo.
#>

[CmdletBinding()]
param(
    [switch]$NoPause,
    [string]$MachineNameOverride,
    [string]$LoggedUserOverride
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$PackageVersion = "2026.07.15.13"

function Test-CurrentUserAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-ValueOrDefault {
    param(
        [object]$Value,
        [string]$Default = "Não identificado"
    )

    if ($null -eq $Value) {
        return $Default
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    return $text.Trim()
}

function Get-SafeCimInstance {
    param(
        [Parameter(Mandatory)] [string]$ClassName
    )

    try {
        return Get-CimInstance -ClassName $ClassName -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function ConvertTo-SafeDateTime {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetime]) {
        return $Value
    }

    try {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)
    }
    catch {
        try {
            return [datetime]$Value
        }
        catch {
            return $null
        }
    }
}

function Format-TimeSpanPtBr {
    param([TimeSpan]$TimeSpan)

    $parts = New-Object System.Collections.Generic.List[string]

    if ($TimeSpan.Days -gt 0) {
        $parts.Add(("{0} dia(s)" -f $TimeSpan.Days)) | Out-Null
    }

    if ($TimeSpan.Hours -gt 0 -or $parts.Count -gt 0) {
        $parts.Add(("{0} hora(s)" -f $TimeSpan.Hours)) | Out-Null
    }

    $parts.Add(("{0} minuto(s)" -f $TimeSpan.Minutes)) | Out-Null

    return ($parts -join ", ")
}

function Get-WifiSsid {
    $ssids = New-Object System.Collections.Generic.List[string]

    try {
        $raw = & netsh.exe wlan show interfaces 2>$null
        foreach ($line in $raw) {
            if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') {
                $ssid = $matches[1].Trim()
                if ($ssid -and $ssid -ne "N/A" -and -not $ssids.Contains($ssid)) {
                    $ssids.Add($ssid) | Out-Null
                }
            }
        }
    }
    catch {}

    return $ssids.ToArray()
}

function Get-FirstUsable {
    param(
        [object[]]$Values,
        [string]$Default = "Não identificado"
    )

    foreach ($value in $Values) {
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text) -and $text.Trim() -ne "Não identificado") {
            return $text.Trim()
        }
    }

    return $Default
}

function Get-MachineNameValue {
    param(
        [object]$ComputerSystem,
        [string]$ExplicitMachineName
    )

    $dnsHostName = $null
    try { $dnsHostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName } catch {}

    Get-FirstUsable -Values @(
        $ExplicitMachineName,
        $env:COMPUTERNAME,
        [Environment]::MachineName,
        $ComputerSystem.Name,
        $dnsHostName
    )
}

function Get-CurrentIdentityValue {
    try {
        return (Get-ValueOrDefault ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name))
    }
    catch {
        return (Get-EnvironmentUserValue)
    }
}

function Get-EnvironmentUserValue {
    $domain = $env:USERDOMAIN
    $user = $env:USERNAME

    if (-not [string]::IsNullOrWhiteSpace($domain) -and -not [string]::IsNullOrWhiteSpace($user)) {
        return "$domain\$user"
    }

    Get-ValueOrDefault $user
}

function Get-HkcuVolatileUser {
    $candidates = New-Object System.Collections.Generic.List[string]
    $root = "HKCU:\Volatile Environment"

    try {
        if (Test-Path -LiteralPath $root) {
            $items = @((Get-Item -LiteralPath $root -ErrorAction SilentlyContinue))
            $items += @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)

            foreach ($item in $items) {
                $props = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
                $domain = $props.USERDOMAIN
                $user = $props.USERNAME

                if (-not [string]::IsNullOrWhiteSpace($domain) -and -not [string]::IsNullOrWhiteSpace($user)) {
                    $candidates.Add("$domain\$user") | Out-Null
                }
                elseif (-not [string]::IsNullOrWhiteSpace($user)) {
                    $candidates.Add($user) | Out-Null
                }
            }
        }
    }
    catch {}

    Get-FirstUsable -Values $candidates.ToArray() -Default $null
}

function Get-ExplorerLoggedUser {
    $currentSessionId = $null
    try { $currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch {}

    $owners = New-Object System.Collections.Generic.List[object]

    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop)
        foreach ($process in $processes) {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($owner -and $owner.ReturnValue -eq 0 -and -not [string]::IsNullOrWhiteSpace($owner.User)) {
                $name = if (-not [string]::IsNullOrWhiteSpace($owner.Domain)) { "$($owner.Domain)\$($owner.User)" } else { $owner.User }
                $owners.Add([pscustomobject]@{
                    SessionId = $process.SessionId
                    Name      = $name
                }) | Out-Null
            }
        }
    }
    catch {}

    if ($currentSessionId -ne $null) {
        $sameSession = $owners | Where-Object { $_.SessionId -eq $currentSessionId } | Select-Object -First 1
        if ($sameSession) {
            return $sameSession.Name
        }
    }

    $first = $owners | Select-Object -First 1
    if ($first) {
        return $first.Name
    }

    return $null
}

function Get-LoggedUserValue {
    param(
        [object]$ComputerSystem,
        [string]$CurrentIdentity,
        [string]$ExplicitUser
    )

    Get-FirstUsable -Values @(
        $ExplicitUser,
        $ComputerSystem.UserName,
        (Get-ExplorerLoggedUser),
        (Get-HkcuVolatileUser),
        (Get-EnvironmentUserValue),
        $CurrentIdentity
    )
}

function Get-NetworkSnapshot {
    $profiles = @()
    $ipConfigs = @()
    $routes = @()
    $adapters = @()

    try { $profiles = @(Get-NetConnectionProfile -ErrorAction Stop) } catch {}
    try { $ipConfigs = @(Get-NetIPConfiguration -ErrorAction Stop) } catch {}
    try { $routes = @(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop) } catch {}
    try { $adapters = @(Get-NetAdapter -ErrorAction Stop) } catch {}

    $defaultRoute = $routes |
        Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1

    $activeConfigs = foreach ($cfg in $ipConfigs) {
        $ipv4 = @($cfg.IPv4Address | Where-Object {
            $_.IPAddress -and
            $_.IPAddress -ne "127.0.0.1" -and
            $_.IPAddress -notlike "169.254.*"
        })

        if ($ipv4.Count -eq 0) {
            continue
        }

        $profile = $profiles | Where-Object { $_.InterfaceIndex -eq $cfg.InterfaceIndex } | Select-Object -First 1
        $adapter = $adapters | Where-Object { $_.ifIndex -eq $cfg.InterfaceIndex } | Select-Object -First 1
        $gateway = @($cfg.IPv4DefaultGateway | Where-Object NextHop | Select-Object -ExpandProperty NextHop) -join ", "
        $dns = @($cfg.DNSServer.ServerAddresses | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }) -join ", "

        [pscustomobject]@{
            InterfaceAlias  = Get-ValueOrDefault $cfg.InterfaceAlias
            InterfaceIndex  = $cfg.InterfaceIndex
            AdapterName     = Get-ValueOrDefault $adapter.Name
            AdapterStatus   = Get-ValueOrDefault $adapter.Status
            NetworkName     = Get-ValueOrDefault $profile.Name
            NetworkCategory = Get-ValueOrDefault $profile.NetworkCategory
            IPv4            = @($ipv4 | Select-Object -ExpandProperty IPAddress) -join ", "
            PrefixLength    = @($ipv4 | Select-Object -ExpandProperty PrefixLength) -join ", "
            Gateway         = Get-ValueOrDefault $gateway
            DnsServers      = Get-ValueOrDefault $dns
            MacAddress      = Get-ValueOrDefault $adapter.MacAddress
            IsPrimary       = ($defaultRoute -and $cfg.InterfaceIndex -eq $defaultRoute.ifIndex)
        }
    }

    $activeConfigs = @($activeConfigs)
    $primary = $activeConfigs | Where-Object IsPrimary | Select-Object -First 1
    if (-not $primary) {
        $primary = $activeConfigs | Where-Object { $_.Gateway -ne "Não identificado" } | Select-Object -First 1
    }
    if (-not $primary) {
        $primary = $activeConfigs | Select-Object -First 1
    }

    [pscustomobject]@{
        Primary      = $primary
        Active       = $activeConfigs
        Profiles     = $profiles
        WifiSsids    = @(Get-WifiSsid)
        DefaultRoute = $defaultRoute
    }
}

function Add-Line {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Text = ""
    )

    $Lines.Add($Text) | Out-Null
}

function Add-KeyValue {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Key,
        [object]$Value
    )

    Add-Line -Lines $Lines -Text ("{0,-28}: {1}" -f $Key, (Get-ValueOrDefault $Value))
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$now = Get-Date
$outputDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($outputDir) -or -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    $outputDir = Split-Path -Parent $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($outputDir) -or -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    $outputDir = (Get-Location).Path
}
if ([string]::IsNullOrWhiteSpace($outputDir) -or -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    $outputDir = $env:TEMP
}

$computerSystem = Get-SafeCimInstance -ClassName Win32_ComputerSystem
$bios = Get-SafeCimInstance -ClassName Win32_BIOS
$os = Get-SafeCimInstance -ClassName Win32_OperatingSystem
$network = Get-NetworkSnapshot

$lastBoot = ConvertTo-SafeDateTime $os.LastBootUpTime
$uptimeText = "Não identificado"
if ($lastBoot) {
    $uptimeText = Format-TimeSpanPtBr -TimeSpan ($now - $lastBoot)
}

$machineName = Get-MachineNameValue -ComputerSystem $computerSystem -ExplicitMachineName $MachineNameOverride
$currentIdentity = Get-CurrentIdentityValue
$loggedUser = Get-LoggedUserValue -ComputerSystem $computerSystem -CurrentIdentity $currentIdentity -ExplicitUser $LoggedUserOverride
$primaryNetwork = $network.Primary
$wifiText = if ($network.WifiSsids.Count -gt 0) {
    $network.WifiSsids -join ", "
}
elseif ($primaryNetwork -and $primaryNetwork.InterfaceAlias -match '(?i)wi-?fi|wireless|wlan|sem fio') {
    Get-ValueOrDefault $primaryNetwork.NetworkName
}
else {
    "Não identificado"
}

$model = Get-ValueOrDefault $computerSystem.Model
$serialNumber = Get-ValueOrDefault $bios.SerialNumber
$primaryNetworkName = if ($primaryNetwork) { Get-ValueOrDefault $primaryNetwork.NetworkName } else { "Não identificado" }
$primaryIPv4 = if ($primaryNetwork) { Get-ValueOrDefault $primaryNetwork.IPv4 } else { "Não identificado" }
$lastBootText = if ($lastBoot) { $lastBoot.ToString("dd/MM/yyyy HH:mm:ss") } else { "Não identificado" }

$lines = New-Object System.Collections.Generic.List[string]

Add-Line -Lines $lines -Text "============================================================"
Add-Line -Lines $lines -Text " ESTAÇÃO DE TRABALHO"
Add-Line -Lines $lines -Text "============================================================"
Add-Line -Lines $lines
Add-KeyValue -Lines $lines -Key "Versão do pacote" -Value $PackageVersion
Add-KeyValue -Lines $lines -Key "Nome da máquina" -Value $machineName
Add-KeyValue -Lines $lines -Key "Usuário logado" -Value $loggedUser
Add-KeyValue -Lines $lines -Key "Modelo" -Value $model
Add-KeyValue -Lines $lines -Key "Número de série" -Value $serialNumber
Add-KeyValue -Lines $lines -Key "IP IPv4" -Value $primaryIPv4
Add-KeyValue -Lines $lines -Key "Nome da rede" -Value $primaryNetworkName
Add-KeyValue -Lines $lines -Key "Última reinicialização" -Value $lastBootText
Add-KeyValue -Lines $lines -Key "Tempo sem reiniciar" -Value $uptimeText
Add-KeyValue -Lines $lines -Key "Data da coleta" -Value ($now.ToString("dd/MM/yyyy HH:mm:ss"))
Add-Line -Lines $lines

Add-Line -Lines $lines -Text "COMPUTADOR"
Add-KeyValue -Lines $lines -Key "Nome da máquina" -Value $machineName
Add-KeyValue -Lines $lines -Key "Nome do computador" -Value $machineName
Add-KeyValue -Lines $lines -Key "Nome via ambiente" -Value $env:COMPUTERNAME
Add-KeyValue -Lines $lines -Key "Nome via WMI" -Value $computerSystem.Name
Add-KeyValue -Lines $lines -Key "Fabricante" -Value $computerSystem.Manufacturer
Add-KeyValue -Lines $lines -Key "Modelo" -Value $model
Add-KeyValue -Lines $lines -Key "Número de série" -Value $serialNumber
Add-KeyValue -Lines $lines -Key "Domínio/Grupo de trabalho" -Value $computerSystem.Domain
Add-KeyValue -Lines $lines -Key "Usuário logado" -Value $loggedUser
Add-KeyValue -Lines $lines -Key "Usuário do processo" -Value $currentIdentity
Add-Line -Lines $lines

Add-Line -Lines $lines -Text "WINDOWS"
Add-KeyValue -Lines $lines -Key "Sistema" -Value $os.Caption
Add-KeyValue -Lines $lines -Key "Versão" -Value $os.Version
Add-KeyValue -Lines $lines -Key "Build" -Value $os.BuildNumber
Add-KeyValue -Lines $lines -Key "Arquitetura" -Value $os.OSArchitecture
Add-KeyValue -Lines $lines -Key "Última reinicialização" -Value $lastBootText
Add-KeyValue -Lines $lines -Key "Tempo sem reiniciar" -Value $uptimeText
Add-Line -Lines $lines

Add-Line -Lines $lines -Text "REDE PRINCIPAL"
if ($primaryNetwork) {
    Add-KeyValue -Lines $lines -Key "Nome da rede" -Value $primaryNetwork.NetworkName
    Add-KeyValue -Lines $lines -Key "SSID Wi-Fi" -Value $wifiText
    Add-KeyValue -Lines $lines -Key "Interface" -Value $primaryNetwork.InterfaceAlias
    Add-KeyValue -Lines $lines -Key "Categoria" -Value $primaryNetwork.NetworkCategory
    Add-KeyValue -Lines $lines -Key "IP IPv4" -Value $primaryNetwork.IPv4
    Add-KeyValue -Lines $lines -Key "Gateway" -Value $primaryNetwork.Gateway
    Add-KeyValue -Lines $lines -Key "DNS" -Value $primaryNetwork.DnsServers
    Add-KeyValue -Lines $lines -Key "MAC" -Value $primaryNetwork.MacAddress
}
else {
    Add-Line -Lines $lines -Text "Nenhuma conexão IPv4 ativa foi identificada."
}
Add-Line -Lines $lines

Add-Line -Lines $lines -Text "TODAS AS CONEXÕES IPv4 ATIVAS"
if ($network.Active.Count -gt 0) {
    foreach ($item in $network.Active) {
        $marker = if ($item.IsPrimary) { "principal" } else { "ativa" }
        Add-Line -Lines $lines -Text ("- {0} [{1}] | Rede: {2} | IP: {3} | Gateway: {4}" -f $item.InterfaceAlias, $marker, $item.NetworkName, $item.IPv4, $item.Gateway)
    }
}
else {
    Add-Line -Lines $lines -Text "- Nenhuma conexão IPv4 ativa encontrada."
}
Add-Line -Lines $lines
Add-Line -Lines $lines -Text "CONFIRMAÇÃO DOS CAMPOS PEDIDOS"
Add-KeyValue -Lines $lines -Key "Nome da máquina" -Value $machineName
Add-KeyValue -Lines $lines -Key "Usuário logado" -Value $loggedUser
Add-KeyValue -Lines $lines -Key "Modelo" -Value $model
Add-KeyValue -Lines $lines -Key "Número de série" -Value $serialNumber
Add-KeyValue -Lines $lines -Key "IP IPv4" -Value $primaryIPv4
Add-KeyValue -Lines $lines -Key "Nome da rede" -Value $primaryNetworkName
Add-KeyValue -Lines $lines -Key "Tempo sem reiniciar" -Value $uptimeText
Add-Line -Lines $lines
Add-Line -Lines $lines -Text "Observação: este script é somente leitura. Nenhuma configuração foi alterada."

$safeComputerName = ($env:COMPUTERNAME -replace '[^\w.-]', '_')
$reportPath = Join-Path $outputDir ("Informacoes_Maquina_{0}_{1}.txt" -f $safeComputerName, $timestamp)

try {
    $utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
    [System.IO.File]::WriteAllLines($reportPath, $lines, $utf8Bom)
}
catch {
    $reportPath = Join-Path $env:TEMP ("Informacoes_Maquina_{0}_{1}.txt" -f $safeComputerName, $timestamp)
    $utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
    [System.IO.File]::WriteAllLines($reportPath, $lines, $utf8Bom)
}

Clear-Host
foreach ($line in $lines) {
    Write-Host $line
}

Write-Host ""
if (Test-CurrentUserAdministrator) {
    Write-Host "Relatório salvo em:" -ForegroundColor Green
    Write-Host $reportPath -ForegroundColor Cyan
}
else {
    Write-Host "Relatório salvo automaticamente." -ForegroundColor Green
}

if (-not $NoPause) {
    Write-Host ""
    Read-Host "Pressione ENTER para fechar"
}
