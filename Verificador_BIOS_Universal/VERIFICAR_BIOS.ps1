#requires -version 5.1
<#
  VERIFICADOR DE BIOS — UNIVERSAL

  Equipamentos atendidos:
  - qualquer computador Windows para inventário e verificação genérica;
  - Lenovo ThinkPad T14 Gen 1 Intel, tipos 20S0 e 20S1, com comparação
    automática pela referência Lenovo DS544549.

  O script SOMENTE CONSULTA:
  - não baixa;
  - não instala;
  - não altera;
  - não regrava a BIOS.

  A referência oficial conhecida em 12/07/2026 é:
  - Pacote: N2XUJ28W
  - UEFI BIOS: 1.36 (N2XET46W)
  - Embedded Controller: 1.18 (N2XHT28W)
  - Documento oficial Lenovo: DS544549

  O script também tenta consultar a página oficial da Lenovo ao vivo para
  detectar se uma versão mais nova foi publicada depois dessa referência.
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

function Get-NumericSuffix {
    param(
        [string]$Text,
        [string]$Prefix
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $pattern = "(?i)" + [regex]::Escape($Prefix) + "(?<n>\d+)W"
    $match = [regex]::Match($Text, $pattern)

    if ($match.Success) {
        return [int]$match.Groups["n"].Value
    }

    return $null
}

function Convert-ToVersionSafe {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, '(?<v>\d+\.\d+(?:\.\d+)*)')
    if (-not $match.Success) {
        return $null
    }

    try {
        return [version]$match.Groups["v"].Value
    }
    catch {
        return $null
    }
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

    $selected = $candidatePaths |
        Select-Object -Unique |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace([string]$selected)) {
        return $null
    }

    return [string]$selected
}

function Get-LiveLenovoReference {
    param(
        [string]$SupportUrl,
        [string]$LogDir
    )

    $result = [ordered]@{
        Success        = $false
        Source         = $SupportUrl
        Package        = $null
        BiosVersion    = $null
        BiosCode       = $null
        EcVersion      = $null
        EcCode         = $null
        RawMatchCount  = 0
        Error          = $null
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $response = Invoke-WebRequest `
            -Uri $SupportUrl `
            -UseBasicParsing `
            -TimeoutSec 35 `
            -Headers @{
                "User-Agent" = "Mozilla/5.0 Windows BIOS Verification"
                "Accept-Language" = "pt-BR,pt;q=0.9,en;q=0.8"
            } `
            -ErrorAction Stop

        $html = [string]$response.Content
        Save-Text -Path (Join-Path $LogDir "20_PAGINA_LENOVO_CONSULTADA.html") -Content $html

        # Captura pares do histórico oficial:
        # N2XUJ28W, 1.36 (N2XET46W), 1.18 (N2XHT28W)
        $pattern = '(?is)(?<package>N2XUJ\d+W).*?(?<biosver>\d+\.\d+)\s*\((?<bioscode>N2XET\d+W)\).*?(?<ecver>\d+\.\d+)\s*\((?<eccode>N2XHT\d+W)\)'
        $matches = [regex]::Matches($html, $pattern)
        $result.RawMatchCount = $matches.Count

        $records = New-Object System.Collections.Generic.List[object]

        foreach ($match in $matches) {
            $package = $match.Groups["package"].Value.ToUpperInvariant()
            $biosVersion = $match.Groups["biosver"].Value
            $biosCode = $match.Groups["bioscode"].Value.ToUpperInvariant()
            $ecVersion = $match.Groups["ecver"].Value
            $ecCode = $match.Groups["eccode"].Value.ToUpperInvariant()
            $biosNumber = Get-NumericSuffix -Text $biosCode -Prefix "N2XET"
            $packageNumber = Get-NumericSuffix -Text $package -Prefix "N2XUJ"

            if ($null -ne $biosNumber -and $null -ne $packageNumber) {
                $records.Add([pscustomobject]@{
                    PackageNumber = $packageNumber
                    Package       = $package
                    BiosNumber    = $biosNumber
                    BiosVersion   = $biosVersion
                    BiosCode      = $biosCode
                    EcVersion     = $ecVersion
                    EcCode        = $ecCode
                }) | Out-Null
            }
        }

        if ($records.Count -gt 0) {
            $latest = $records |
                Sort-Object BiosNumber, PackageNumber -Descending |
                Select-Object -First 1

            $result.Success = $true
            $result.Package = $latest.Package
            $result.BiosVersion = $latest.BiosVersion
            $result.BiosCode = $latest.BiosCode
            $result.EcVersion = $latest.EcVersion
            $result.EcCode = $latest.EcCode

            $records |
                Sort-Object BiosNumber -Descending |
                Export-Csv (Join-Path $LogDir "21_REFERENCIAS_ENCONTRADAS_LENOVO.csv") `
                    -NoTypeInformation -Encoding UTF8
        }
        else {
            $result.Error = "A página respondeu, mas o conteúdo dinâmico não apresentou os códigos de BIOS no HTML recebido."
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return [pscustomobject]$result
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
$logDir = Join-Path $desktop "Verificacao_BIOS_$timestamp"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Start-Transcript -Path (Join-Path $logDir "00_TRANSCRICAO.txt") -Force | Out-Null

# Referência oficial confirmada em 12/07/2026
$knownPackage = "N2XUJ28W"
$knownBiosVersionText = "1.36"
$knownBiosCode = "N2XET46W"
$knownEcVersionText = "1.18"
$knownEcCode = "N2XHT28W"
$knownReferenceDate = "12/07/2026"
$supportUrl = "https://support.lenovo.com/br/pt/downloads/ds544549"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " VERIFICADOR DE BIOS — UNIVERSAL" -ForegroundColor Cyan
Write-Host " Somente consulta: nenhuma atualização será instalada" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Write-Section "Identificação do computador"

$machineIdentity = Get-MachineIdentity
$supportInfo = Get-OemSupportInfo -Identity $machineIdentity
$cs = $machineIdentity.RawComputerSystem
$csp = $machineIdentity.RawProduct
$bios = $machineIdentity.RawBios
$cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

$machineType = $machineIdentity.LenovoMachineType
$isLenovoT14Reference = ($machineIdentity.Vendor -eq "Lenovo" -and $machineType -in @("20S0", "20S1"))

$installedBiosRaw = [string]$bios.SMBIOSBIOSVersion
$installedBiosCode = $null
$installedBiosVersionText = $null

$installedCodeMatch = [regex]::Match($installedBiosRaw, '(?i)(N2XET\d+W)')
if ($installedCodeMatch.Success) {
    $installedBiosCode = $installedCodeMatch.Groups[1].Value.ToUpperInvariant()
}

$installedVersionMatch = [regex]::Match($installedBiosRaw, '(?<v>\d+\.\d+)')
if ($installedVersionMatch.Success) {
    $installedBiosVersionText = $installedVersionMatch.Groups["v"].Value
}

$biosDate = $null
try {
    $biosDate = [Management.ManagementDateTimeConverter]::ToDateTime([string]$bios.ReleaseDate)
}
catch {
    $biosDate = $bios.ReleaseDate
}

$firmwareMode = "Indeterminado"
$uefiMode = $null

try {
    if (-not ("Firmware.NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Firmware {
    public static class NativeMethods {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetFirmwareType(out uint FirmwareType);
    }
}
"@ -ErrorAction Stop
    }

    [uint32]$nativeFirmwareType = 0
    $ok = [Firmware.NativeMethods]::GetFirmwareType([ref]$nativeFirmwareType)

    if ($ok) {
        switch ($nativeFirmwareType) {
            1 {
                $firmwareMode = "Legacy BIOS"
                $uefiMode = $false
            }
            2 {
                $firmwareMode = "UEFI"
                $uefiMode = $true
            }
            default {
                $firmwareMode = "Indeterminado"
                $uefiMode = $null
            }
        }
    }
}
catch {
    # Fallback: no modo UEFI o carregador normalmente é winload.efi.
    try {
        $bcdText = (& bcdedit.exe /enum "{current}" 2>&1 | Out-String)

        if ($bcdText -match '(?i)winload\.efi') {
            $firmwareMode = "UEFI"
            $uefiMode = $true
        }
        elseif ($bcdText -match '(?i)winload\.exe') {
            $firmwareMode = "Legacy BIOS"
            $uefiMode = $false
        }
    }
    catch {}
}

$secureBoot = $null
try {
    $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
}
catch {
    $secureBoot = "Indisponível ou não consultável"
}

$identity = [pscustomobject]@{
    Fabricante          = $machineIdentity.Manufacturer
    FabricanteNormalizado = $machineIdentity.Vendor
    Modelo              = $machineIdentity.Model
    Produto             = $machineIdentity.ProductName
    VersaoProduto       = $machineIdentity.ProductVersion
    TipoDetectado       = $machineType
    ServiceTagDell      = $machineIdentity.DellServiceTag
    NumeroSerie         = $machineIdentity.SerialNumber
    BIOSInstaladaBruta  = $installedBiosRaw
    CodigoBIOSInstalada = $installedBiosCode
    VersaoBIOSInstalada = $installedBiosVersionText
    DataBIOS             = $biosDate
    ModoUEFI             = $uefiMode
    SecureBoot           = $secureBoot
    WindowsVersao        = $cv.DisplayVersion
    WindowsBuild         = "$($cv.CurrentBuild).$($cv.UBR)"
    FerramentaOEM        = $supportInfo.ToolName
    CaminhoFerramentaOEM = $supportInfo.ToolPath
    ComparacaoAutomatica = $isLenovoT14Reference
}

$identity | Format-List
$identity |
    Format-List |
    Out-String -Width 4096 |
    Save-Text -Path (Join-Path $logDir "01_IDENTIFICACAO_E_BIOS_INSTALADA.txt")

if ($isLenovoT14Reference) {
    Write-Host "Referência automática habilitada: Lenovo tipo $machineType, documento DS544549." -ForegroundColor Green
}
else {
    Write-Host "Comparação automática específica não disponível para este modelo." -ForegroundColor Yellow
    Write-Host "Será gerado inventário da BIOS e links/ferramentas oficiais para conferência manual." -ForegroundColor Yellow
}

$live = [pscustomobject]@{
    Success = $false
    Error = "Comparação automática específica não aplicada para este equipamento."
}
$referenceSource = "Não aplicada"
$latestPackage = $null
$latestBiosVersionText = $null
$latestBiosCode = $null
$latestEcVersionText = $null
$latestEcCode = $null
$verdict = "BIOS REGISTRADA PARA VERIFICAÇÃO MANUAL"
$explanation = "A versão instalada foi registrada, mas este pacote só possui comparação automática para Lenovo ThinkPad T14 Gen 1 tipos 20S0/20S1. Use a ferramenta oficial do fabricante ou a página de suporte para confirmar a versão mais recente."
$verdictColor = "Yellow"

if ($isLenovoT14Reference) {
Write-Section "Referência oficial conhecida"

$knownReference = [pscustomobject]@{
    DataDaVerificacao = $knownReferenceDate
    DocumentoLenovo   = "DS544549"
    Pacote            = $knownPackage
    UEFIBIOS          = "$knownBiosVersionText ($knownBiosCode)"
    EmbeddedController= "$knownEcVersionText ($knownEcCode)"
    URL               = $supportUrl
}

$knownReference | Format-List
$knownReference |
    Format-List |
    Out-String -Width 4096 |
    Save-Text -Path (Join-Path $logDir "10_REFERENCIA_OFICIAL_CONHECIDA.txt")

Write-Section "Consulta ao vivo no suporte oficial Lenovo"
Write-Host "Consultando: $supportUrl"
$live = Get-LiveLenovoReference -SupportUrl $supportUrl -LogDir $logDir

if ($live.Success) {
    Write-Host "Consulta ao vivo concluída." -ForegroundColor Green
    Write-Host "Pacote mais recente encontrado: $($live.Package)"
    Write-Host "BIOS mais recente encontrada: $($live.BiosVersion) ($($live.BiosCode))"
    Write-Host "EC mais recente encontrado: $($live.EcVersion) ($($live.EcCode))"
}
else {
    Write-Host "Não foi possível extrair uma referência ao vivo automaticamente." -ForegroundColor Yellow
    Write-Host "Motivo: $($live.Error)" -ForegroundColor Yellow
    Write-Host "Será usada a referência oficial confirmada em $knownReferenceDate." -ForegroundColor Yellow
}

$live |
    Format-List |
    Out-String -Width 4096 |
    Save-Text -Path (Join-Path $logDir "11_RESULTADO_CONSULTA_AO_VIVO.txt")

# Define a referência final. A consulta ao vivo só substitui a referência
# conhecida quando apresenta um código de BIOS numérico válido.
$referenceSource = "Referência oficial confirmada em $knownReferenceDate"
$latestPackage = $knownPackage
$latestBiosVersionText = $knownBiosVersionText
$latestBiosCode = $knownBiosCode
$latestEcVersionText = $knownEcVersionText
$latestEcCode = $knownEcCode

if ($live.Success) {
    $liveBiosNumber = Get-NumericSuffix -Text $live.BiosCode -Prefix "N2XET"
    $knownBiosNumber = Get-NumericSuffix -Text $knownBiosCode -Prefix "N2XET"

    if ($null -ne $liveBiosNumber -and
        ($null -eq $knownBiosNumber -or $liveBiosNumber -ge $knownBiosNumber)) {
        $referenceSource = "Consulta ao vivo no suporte oficial Lenovo"
        $latestPackage = $live.Package
        $latestBiosVersionText = $live.BiosVersion
        $latestBiosCode = $live.BiosCode
        $latestEcVersionText = $live.EcVersion
        $latestEcCode = $live.EcCode
    }
}

Write-Section "Comparação"

$installedBiosNumber = Get-NumericSuffix -Text $installedBiosCode -Prefix "N2XET"
$latestBiosNumber = Get-NumericSuffix -Text $latestBiosCode -Prefix "N2XET"
$installedVersion = Convert-ToVersionSafe -Text $installedBiosVersionText
$latestVersion = Convert-ToVersionSafe -Text $latestBiosVersionText

$verdict = ""
$explanation = ""
$verdictColor = "Yellow"

if ($null -eq $installedBiosNumber -or $null -eq $latestBiosNumber) {
    $verdict = "NÃO FOI POSSÍVEL COMPARAR AUTOMATICAMENTE"
    $explanation = "Um dos códigos de BIOS não pôde ser interpretado. Compare manualmente o relatório com a página oficial."
    $verdictColor = "Yellow"
}
elseif ($installedBiosNumber -gt $latestBiosNumber) {
    $verdict = "BIOS INSTALADA É MAIS NOVA QUE A REFERÊNCIA"
    $explanation = "O código instalado $installedBiosCode é numericamente superior ao código de referência $latestBiosCode. Confirme no Lenovo System Update, pois a página consultada pode estar em cache."
    $verdictColor = "Green"
}
elseif ($installedBiosNumber -eq $latestBiosNumber) {
    if ($null -ne $installedVersion -and $null -ne $latestVersion -and $installedVersion -lt $latestVersion) {
        $verdict = "BIOS PROVAVELMENTE DESATUALIZADA"
        $explanation = "O código é semelhante, mas a versão instalada $installedBiosVersionText é inferior à versão oficial $latestBiosVersionText."
        $verdictColor = "Red"
    }
    else {
        $verdict = "BIOS ATUALIZADA"
        $explanation = "A BIOS instalada $installedBiosVersionText ($installedBiosCode) corresponde à versão oficial mais recente identificada: $latestBiosVersionText ($latestBiosCode)."
        $verdictColor = "Green"
    }
}
else {
    $verdict = "BIOS DESATUALIZADA"
    $explanation = "A BIOS instalada $installedBiosVersionText ($installedBiosCode) é anterior à versão oficial $latestBiosVersionText ($latestBiosCode), pacote $latestPackage."
    $verdictColor = "Red"
}

Write-Host ""
Write-Host "BIOS instalada : $installedBiosVersionText ($installedBiosCode)"
Write-Host "BIOS de referência: $latestBiosVersionText ($latestBiosCode)"
Write-Host "Fonte: $referenceSource"
Write-Host ""
Write-Host $verdict -ForegroundColor $verdictColor
Write-Host $explanation
}
else {
    Write-Section "Verificação manual pelo fabricante"
    Write-Host "BIOS instalada: $installedBiosRaw"
    Write-Host "Data da BIOS: $biosDate"
    Write-Host "Ferramenta OEM: $($supportInfo.ToolName)"
    if ($supportInfo.ToolPath) {
        Write-Host "Caminho: $($supportInfo.ToolPath)"
    }
    if ($supportInfo.SupportUrl) {
        Write-Host "Suporte oficial: $($supportInfo.SupportUrl)"
    }
    Write-Host ""
    Write-Host $verdict -ForegroundColor $verdictColor
    Write-Host $explanation
}

$oemToolPath = $supportInfo.ToolPath
$oemToolVersion = $null

if ($oemToolPath -and (Test-Path -LiteralPath $oemToolPath -PathType Leaf)) {
    try {
        $oemToolVersion = (Get-Item -LiteralPath $oemToolPath).VersionInfo.FileVersion
    }
    catch {}
}

$summary = New-Object System.Collections.Generic.List[string]
$effectiveSupportUrl = if ($isLenovoT14Reference) { $supportUrl } else { $supportInfo.SupportUrl }
$referenceDocument = if ($isLenovoT14Reference) { "DS544549" } else { "Não aplicado" }

$summary.Add("VERIFICAÇÃO DA BIOS — UNIVERSAL")
$summary.Add("Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
$summary.Add("")
$summary.Add("EQUIPAMENTO")
$summary.Add("Fabricante: $($machineIdentity.Manufacturer)")
$summary.Add("Fabricante normalizado: $($machineIdentity.Vendor)")
$summary.Add("Modelo: $($machineIdentity.Model)")
$summary.Add("Produto: $($machineIdentity.ProductName)")
$summary.Add("Tipo Lenovo: $machineType")
$summary.Add("Service Tag Dell: $($machineIdentity.DellServiceTag)")
$summary.Add("Número de série: $($machineIdentity.SerialNumber)")
$summary.Add("")
$summary.Add("BIOS INSTALADA")
$summary.Add("Versão bruta: $installedBiosRaw")
$summary.Add("Versão: $installedBiosVersionText")
$summary.Add("Código: $installedBiosCode")
$summary.Add("Data: $biosDate")
$summary.Add("")
$summary.Add("REFERÊNCIA MAIS RECENTE UTILIZADA")
$summary.Add("Fonte: $referenceSource")
$summary.Add("Pacote: $latestPackage")
$summary.Add("UEFI BIOS: $latestBiosVersionText ($latestBiosCode)")
$summary.Add("Embedded Controller: $latestEcVersionText ($latestEcCode)")
$summary.Add("Documento: $referenceDocument")
$summary.Add("Página oficial: $effectiveSupportUrl")
$summary.Add("")
$summary.Add("RESULTADO")
$summary.Add($verdict)
$summary.Add($explanation)
$summary.Add("")
$summary.Add("INFORMAÇÕES ADICIONAIS")
$summary.Add("Modo de firmware: $firmwareMode")
$summary.Add("Modo UEFI: $uefiMode")
$summary.Add("Secure Boot: $secureBoot")
$summary.Add("Observação: Secure Boot desativado não significa que o computador esteja em modo Legacy.")
$summary.Add("Windows: $($cv.DisplayVersion) build $($cv.CurrentBuild).$($cv.UBR)")
$summary.Add("Ferramenta OEM: $($supportInfo.ToolName)")
$summary.Add("Ferramenta OEM encontrada: $([bool]$oemToolPath)")
$summary.Add("Caminho ferramenta OEM: $oemToolPath")
$summary.Add("Versão ferramenta OEM: $oemToolVersion")
$summary.Add("")
$summary.Add("IMPORTANTE")
$summary.Add("Este script apenas verifica. Ele não instala nem regrava a BIOS.")
$summary.Add("Uma consulta online pode falhar por bloqueio regional, DNS, proxy ou conteúdo dinâmico.")
$summary.Add("Antes de qualquer atualização futura, confirme BitLocker, chave de recuperação, carregador e bateria.")

$summary |
    Out-File (Join-Path $logDir "RESULTADO_LEIA_PRIMEIRO.txt") -Encoding utf8 -Width 4096

$resultObject = [pscustomobject]@{
    Data                    = Get-Date
    Fabricante              = $machineIdentity.Manufacturer
    FabricanteNormalizado   = $machineIdentity.Vendor
    Modelo                  = $machineIdentity.Model
    TipoLenovo              = $machineType
    ServiceTagDell          = $machineIdentity.DellServiceTag
    NumeroSerie             = $machineIdentity.SerialNumber
    BiosInstaladaVersao     = $installedBiosVersionText
    BiosInstaladaCodigo     = $installedBiosCode
    BiosReferenciaVersao    = $latestBiosVersionText
    BiosReferenciaCodigo    = $latestBiosCode
    PacoteReferencia        = $latestPackage
    FonteReferencia         = $referenceSource
    ConsultaAoVivoSucesso   = $live.Success
    Veredito                = $verdict
    Explicacao              = $explanation
}

$resultObject |
    Export-Csv (Join-Path $logDir "RESULTADO_RESUMIDO.csv") -NoTypeInformation -Encoding UTF8

Stop-Transcript | Out-Null

$zipPath = Join-Path $desktop "Relatorio_Verificacao_BIOS_$timestamp.zip"
Compress-Archive -Path $logDir -DestinationPath $zipPath -CompressionLevel Optimal -Force

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " VERIFICAÇÃO CONCLUÍDA" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Resultado: $verdict" -ForegroundColor $verdictColor
Write-Host ""
Write-Host "Relatório principal:"
Write-Host (Join-Path $logDir "RESULTADO_LEIA_PRIMEIRO.txt") -ForegroundColor Cyan
Write-Host ""
Write-Host "ZIP gerado:"
Write-Host $zipPath -ForegroundColor Cyan
Write-Host ""

if ($oemToolPath -and (Test-Path -LiteralPath $oemToolPath -PathType Leaf)) {
    $openOemTool = Read-Host "Abrir $($supportInfo.ToolName) apenas para uma segunda confirmação? Digite SIM"
    if ($openOemTool.Trim().ToUpperInvariant() -eq "SIM") {
        try {
            $leafName = [IO.Path]::GetFileName($oemToolPath)
            if ($leafName -ieq "dcu-cli.exe") {
                Start-Process explorer.exe -ArgumentList "/select,`"$oemToolPath`""
            }
            else {
                Start-Process -FilePath $oemToolPath -Verb RunAs
            }
        }
        catch {
            Write-Host "Não foi possível abrir a ferramenta OEM: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace([string]$effectiveSupportUrl)) {
    $openPage = Read-Host "Abrir a página oficial de suporte no navegador? Digite SIM"
    if ($openPage.Trim().ToUpperInvariant() -eq "SIM") {
        Start-Process $effectiveSupportUrl
    }
}

Read-Host "Pressione ENTER para fechar"
