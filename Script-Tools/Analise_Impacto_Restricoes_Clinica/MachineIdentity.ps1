#requires -version 5.1

function Get-NormalizedManufacturer {
    param([string]$Manufacturer)

    if ($Manufacturer -match '(?i)lenovo') { return 'Lenovo' }
    if ($Manufacturer -match '(?i)dell') { return 'Dell' }
    if ($Manufacturer -match '(?i)hp|hewlett') { return 'HP' }
    if ($Manufacturer -match '(?i)asus') { return 'ASUS' }
    if ($Manufacturer -match '(?i)acer') { return 'Acer' }

    if ([string]::IsNullOrWhiteSpace($Manufacturer)) {
        return 'Desconhecido'
    }

    return $Manufacturer.Trim()
}

function Get-LenovoMachineType {
    param([string[]]$Values)

    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $match = [regex]::Match($value, '(?i)\b([0-9A-Z]{4})[0-9A-Z]{0,8}\b')
        if ($match.Success -and $match.Groups[1].Value -match '^[0-9][0-9A-Z]{3}$') {
            return $match.Groups[1].Value.ToUpperInvariant()
        }
    }

    return $null
}

function Get-MachineIdentity {
    $cs = Get-CimInstance Win32_ComputerSystem
    $csp = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $baseboard = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $manufacturer = Get-NormalizedManufacturer -Manufacturer ([string]$cs.Manufacturer)
    $identityValues = @(
        [string]$cs.Model,
        [string]$csp.Name,
        [string]$csp.Version,
        [string]$csp.SKUNumber,
        [string]$baseboard.Product
    )

    $lenovoType = $null
    if ($manufacturer -eq 'Lenovo') {
        $lenovoType = Get-LenovoMachineType -Values $identityValues
    }

    $serviceTag = $null
    if ($manufacturer -eq 'Dell') {
        $serviceTag = [string]$bios.SerialNumber
    }

    return [pscustomobject]@{
        ComputerName        = [string]$env:COMPUTERNAME
        Manufacturer        = [string]$cs.Manufacturer
        Vendor              = [string]$manufacturer
        Model               = [string]$cs.Model
        ProductName         = [string]$csp.Name
        ProductVersion      = [string]$csp.Version
        Sku                 = [string]$csp.SKUNumber
        LenovoMachineType   = $lenovoType
        DellServiceTag      = $serviceTag
        SerialNumber        = [string]$bios.SerialNumber
        BiosVersion         = [string]$bios.SMBIOSBIOSVersion
        BiosReleaseDate     = [string]$bios.ReleaseDate
        WindowsEdition      = [string]$cv.EditionID
        WindowsVersion      = [string]$cv.DisplayVersion
        WindowsBuild        = "$($cv.CurrentBuild).$($cv.UBR)"
        OSArchitecture      = [string]$os.OSArchitecture
        TotalMemoryGB       = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 2)
        UserName            = [string]$cs.UserName
        RawComputerSystem   = $cs
        RawProduct          = $csp
        RawBios             = $bios
    }
}

function Save-MachineIdentity {
    param(
        [Parameter(Mandatory)]
        [object]$Identity,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $Identity |
        Select-Object ComputerName, Vendor, Manufacturer, Model, ProductName,
            ProductVersion, Sku, LenovoMachineType, DellServiceTag, SerialNumber,
            BiosVersion, BiosReleaseDate, WindowsEdition, WindowsVersion,
            WindowsBuild, OSArchitecture, TotalMemoryGB, UserName |
        Format-List |
        Out-String -Width 4096 |
        Out-File -FilePath $Path -Encoding utf8 -Width 4096
}

function Find-InstalledProgramPath {
    param(
        [string]$DisplayNamePattern,
        [string[]]$ExecutableNames
    )

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($root in $roots) {
        $apps = Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.DisplayName -match $DisplayNamePattern }

        foreach ($app in @($apps)) {
            $installLocation = [string]$app.InstallLocation
            if ([string]::IsNullOrWhiteSpace($installLocation)) {
                continue
            }

            foreach ($exe in $ExecutableNames) {
                $candidate = Join-Path $installLocation $exe
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return (Resolve-Path -LiteralPath $candidate).Path
                }
            }
        }
    }

    return $null
}

function Find-LenovoSystemUpdate {
    $paths = @(
        "$env:ProgramFiles\Lenovo\System Update\tvsu.exe",
        "${env:ProgramFiles(x86)}\Lenovo\System Update\tvsu.exe"
    )

    foreach ($path in $paths) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and
            (Test-Path -LiteralPath $path -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return Find-InstalledProgramPath `
        -DisplayNamePattern '^Lenovo System Update' `
        -ExecutableNames @('tvsu.exe', 'Tvsu.exe')
}

function Find-DellUpdateTool {
    $paths = @(
        "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe",
        "$env:ProgramFiles\Dell\CommandUpdate\DellCommandUpdate.exe",
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\DellCommandUpdate.exe",
        "$env:ProgramFiles\Dell\SupportAssistAgent\bin\SupportAssistUI.exe",
        "${env:ProgramFiles(x86)}\Dell\SupportAssistAgent\bin\SupportAssistUI.exe"
    )

    foreach ($path in $paths) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and
            (Test-Path -LiteralPath $path -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return Find-InstalledProgramPath `
        -DisplayNamePattern 'Dell.*(Command|Update|SupportAssist)' `
        -ExecutableNames @('dcu-cli.exe', 'DellCommandUpdate.exe', 'SupportAssistUI.exe')
}

function Get-OemSupportInfo {
    param(
        [Parameter(Mandatory)]
        [object]$Identity
    )

    switch ($Identity.Vendor) {
        'Lenovo' {
            return [pscustomobject]@{
                Vendor              = 'Lenovo'
                ToolName            = 'Lenovo System Update'
                ToolPath            = Find-LenovoSystemUpdate
                InstallUrl          = 'https://support.lenovo.com/us/en/solutions/ht003029'
                SupportUrl          = 'https://support.lenovo.com/'
                DnsNames            = @('download.lenovo.com', 'support.lenovo.com')
                PreferOemBeforeWU   = $true
            }
        }
        'Dell' {
            return [pscustomobject]@{
                Vendor              = 'Dell'
                ToolName            = 'Dell Command Update ou SupportAssist'
                ToolPath            = Find-DellUpdateTool
                InstallUrl          = 'https://www.dell.com/support/kbdoc/000177325/dell-command-update'
                SupportUrl          = if ($Identity.DellServiceTag) { "https://www.dell.com/support/home/servicetag/$($Identity.DellServiceTag)" } else { 'https://www.dell.com/support/home' }
                DnsNames            = @('downloads.dell.com', 'www.dell.com')
                PreferOemBeforeWU   = $true
            }
        }
        default {
            return [pscustomobject]@{
                Vendor              = [string]$Identity.Vendor
                ToolName            = 'Ferramenta OEM não identificada'
                ToolPath            = $null
                InstallUrl          = $null
                SupportUrl          = $null
                DnsNames            = @()
                PreferOemBeforeWU   = $false
            }
        }
    }
}

function Test-OemDns {
    param([object]$SupportInfo)

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($name in @($SupportInfo.DnsNames)) {
        try {
            Resolve-DnsName $name -ErrorAction Stop | Out-Null
            $results.Add([pscustomobject]@{ Host = $name; Ok = $true; Error = $null }) | Out-Null
        }
        catch {
            $results.Add([pscustomobject]@{ Host = $name; Ok = $false; Error = $_.Exception.Message }) | Out-Null
        }
    }

    return @($results)
}

function New-ClinicComputerName {
    param(
        [Parameter(Mandatory)]
        [object]$Identity,

        [string]$Suffix = 'RECEP'
    )

    $vendorPrefix = switch ($Identity.Vendor) {
        'Lenovo' { 'L' }
        'Dell'   { 'D' }
        default  { 'PC' }
    }

    $modelSource = if ($Identity.Vendor -eq 'Lenovo' -and $Identity.LenovoMachineType) {
        $familyText = "$($Identity.ProductVersion) $($Identity.ProductName) $($Identity.Model)"
        $familyMatch = [regex]::Match($familyText, '(?i)\b(T\d{2}|X\d{2,3}|E\d{2}|L\d{2}|P\d{1,2})\b')
        if ($familyMatch.Success) {
            "$($Identity.LenovoMachineType)-$($familyMatch.Groups[1].Value.ToUpperInvariant())"
        }
        else {
            $Identity.LenovoMachineType
        }
    }
    elseif ($Identity.Vendor -eq 'Dell' -and $Identity.Model) {
        $Identity.Model
    }
    elseif ($Identity.ProductName) {
        $Identity.ProductName
    }
    else {
        $Identity.Model
    }

    $modelToken = ([string]$modelSource).ToUpperInvariant()
    $modelToken = [regex]::Replace($modelToken, '[^A-Z0-9-]+', '')
    $modelToken = [regex]::Replace($modelToken, '-+', '-').Trim('-')
    $maxModelChars = if ($Identity.Vendor -eq 'Lenovo' -and $modelToken -match '-') { 8 } else { 7 }
    if ($modelToken.Length -gt $maxModelChars) {
        $modelToken = $modelToken.Substring(0, $maxModelChars).TrimEnd('-')
    }
    if ([string]::IsNullOrWhiteSpace($modelToken)) {
        $modelToken = 'GEN'
    }

    $suffixToken = ([string]$Suffix).ToUpperInvariant()
    $suffixToken = [regex]::Replace($suffixToken, '[^A-Z0-9]+', '')
    if ([string]::IsNullOrWhiteSpace($suffixToken)) {
        $suffixToken = 'PC'
    }

    $name = "$vendorPrefix$modelToken-$suffixToken"
    if ($name.Length -gt 15) {
        $name = $name.Substring(0, 15).TrimEnd('-')
    }

    return $name
}
