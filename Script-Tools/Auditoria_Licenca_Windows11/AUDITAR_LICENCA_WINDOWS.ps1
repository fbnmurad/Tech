#requires -version 5.1
<#
AUDITORIA TÉCNICA DE LICENÇA DO WINDOWS 11
- Somente leitura
- Não instala, ativa, remove ou altera chaves
- Não exibe a chave OEM completa
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Host "Execute pelo arquivo EXECUTAR_AUDITORIA.cmd." -ForegroundColor Red
    Read-Host "Pressione ENTER para sair"
    exit 1
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$desktop = [Environment]::GetFolderPath("Desktop")
$outDir = Join-Path $desktop "Auditoria_Licenca_Windows_$timestamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$report = New-Object System.Collections.Generic.List[string]
$alerts = New-Object System.Collections.Generic.List[string]
$suspects = New-Object System.Collections.Generic.List[object]

function Add-ReportLine {
    param([string]$Text = "")
    $report.Add($Text) | Out-Null
}

function Add-Alert {
    param([string]$Text)
    $alerts.Add($Text) | Out-Null
}

function Get-FriendlyEdition {
    param([string]$EditionID)
    switch ($EditionID) {
        "Professional"            { "Pro" }
        "ProfessionalN"           { "Pro N" }
        "Core"                    { "Home" }
        "CoreN"                   { "Home N" }
        "CoreSingleLanguage"      { "Home Single Language" }
        "Education"               { "Education" }
        "EducationN"              { "Education N" }
        "Enterprise"              { "Enterprise" }
        "EnterpriseN"             { "Enterprise N" }
        "ProfessionalEducation"   { "Pro Education" }
        "ProfessionalWorkstation" { "Pro for Workstations" }
        default                   { $EditionID }
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " AUDITORIA TÉCNICA DA LICENÇA DO WINDOWS" -ForegroundColor Cyan
Write-Host " Somente leitura - nenhuma chave será alterada" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Start-Transcript -Path (Join-Path $outDir "TRANSCRICAO_COMPLETA.txt") -Force | Out-Null

# -------------------------------------------------------------------------
# 1. Versão e edição do Windows
# -------------------------------------------------------------------------
$cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$buildNumber = 0
[int]::TryParse([string]$cv.CurrentBuild, [ref]$buildNumber) | Out-Null

$windowsGeneration = if ($buildNumber -ge 22000) { "Windows 11" } else { "Windows 10 ou anterior" }
$editionFriendly = Get-FriendlyEdition -EditionID ([string]$cv.EditionID)
$fullBuild = "{0}.{1}" -f $cv.CurrentBuild, $cv.UBR

$osInfo = [pscustomobject]@{
    Sistema             = $windowsGeneration
    Edicao              = $editionFriendly
    EditionID           = $cv.EditionID
    Versao              = $cv.DisplayVersion
    Build               = $fullBuild
    Arquitetura         = (Get-CimInstance Win32_OperatingSystem).OSArchitecture
    DataDaInstalacao    = (Get-CimInstance Win32_OperatingSystem).InstallDate
    NomeDoComputador    = $env:COMPUTERNAME
}
$osInfo | Format-List | Out-File (Join-Path $outDir "01_VERSAO_WINDOWS.txt") -Encoding utf8 -Width 4096

# -------------------------------------------------------------------------
# 2. Licença ativa do Windows
# -------------------------------------------------------------------------
$windowsAppId = "55c92734-d682-4d71-983e-d6ec3f16059f"
$statusMap = @{
    0 = "Não licenciado"
    1 = "Licenciado"
    2 = "Período inicial de tolerância"
    3 = "Período adicional de tolerância"
    4 = "Licença não genuína / tolerância"
    5 = "Modo de notificação"
    6 = "Tolerância estendida"
}

$products = Get-CimInstance SoftwareLicensingProduct |
    Where-Object {
        $_.ApplicationID -eq $windowsAppId -and
        $_.Name -like "Windows*" -and
        $_.PartialProductKey
    }

$productsView = foreach ($p in $products) {
    [pscustomobject]@{
        Nome                 = $p.Name
        DescricaoCanal       = $p.Description
        FamiliaDaLicenca     = $p.LicenseFamily
        StatusCodigo         = $p.LicenseStatus
        Status               = $statusMap[[int]$p.LicenseStatus]
        ChaveParcial         = $p.PartialProductKey
        MotivoHexadecimal    = ("0x{0:X8}" -f [uint32]$p.LicenseStatusReason)
        ToleranciaRestanteMin= $p.GracePeriodRemaining
        LicencaAdicional     = $p.LicenseIsAddon
    }
}
$productsView | Format-List | Out-File (Join-Path $outDir "02_LICENCAS_WINDOWS.txt") -Encoding utf8 -Width 4096

$currentProduct = $products |
    Sort-Object `
        @{Expression={ if ($_.LicenseStatus -eq 1) { 0 } else { 1 } }}, `
        @{Expression={ if ($_.LicenseIsAddon) { 1 } else { 0 } }} |
    Select-Object -First 1

# -------------------------------------------------------------------------
# 3. Chave OEM no firmware e configuração KMS
# -------------------------------------------------------------------------
$sls = Get-CimInstance SoftwareLicensingService
$oemKeyPresent = -not [string]::IsNullOrWhiteSpace([string]$sls.OA3xOriginalProductKey)

$firmwareInfo = [pscustomobject]@{
    ChaveOEM_OA3_Presente       = $oemKeyPresent
    DescricaoDaChaveOEM         = $sls.OA3xOriginalProductKeyDescription
    ServidorKMS_WMI             = $sls.KeyManagementServiceMachine
    PortaKMS_WMI                = $sls.KeyManagementServicePort
    Observacao                  = "A chave completa não é exibida por segurança."
}
$firmwareInfo | Format-List | Out-File (Join-Path $outDir "03_OEM_E_KMS.txt") -Encoding utf8 -Width 4096

$sppPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform"
$spp = Get-ItemProperty $sppPath -ErrorAction SilentlyContinue
$manualKmsName = [string]$spp.KeyManagementServiceName
$manualKmsPort = [string]$spp.KeyManagementServicePort

if (-not [string]::IsNullOrWhiteSpace($manualKmsName)) {
    Add-Alert "Foi encontrado servidor KMS configurado manualmente: $manualKmsName."
}

# -------------------------------------------------------------------------
# 4. Relatórios oficiais SLMGR
# -------------------------------------------------------------------------
& cscript.exe //nologo "$env:windir\system32\slmgr.vbs" /dlv 2>&1 |
    Out-File (Join-Path $outDir "04_SLMGR_DLV.txt") -Encoding utf8 -Width 4096

& cscript.exe //nologo "$env:windir\system32\slmgr.vbs" /xpr 2>&1 |
    Out-File (Join-Path $outDir "05_SLMGR_XPR.txt") -Encoding utf8 -Width 4096

# -------------------------------------------------------------------------
# 5. Integridade dos principais componentes de licenciamento
# -------------------------------------------------------------------------
$licensingFiles = @(
    "$env:windir\System32\sppsvc.exe",
    "$env:windir\System32\slui.exe"
)

$signatureResults = foreach ($file in $licensingFiles) {
    if (Test-Path $file) {
        $sig = Get-AuthenticodeSignature -FilePath $file
        [pscustomobject]@{
            Arquivo       = $file
            Status        = $sig.Status
            Assinante     = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "" }
            Emissor       = if ($sig.SignerCertificate) { $sig.SignerCertificate.Issuer } else { "" }
        }
    } else {
        [pscustomobject]@{
            Arquivo       = $file
            Status        = "Arquivo ausente"
            Assinante     = ""
            Emissor       = ""
        }
    }
}
$signatureResults | Format-List | Out-File (Join-Path $outDir "06_ASSINATURAS_COMPONENTES.txt") -Encoding utf8 -Width 4096

foreach ($sigItem in $signatureResults) {
    if ([string]$sigItem.Status -ne "Valid") {
        Add-Alert "Componente de licenciamento com assinatura inválida ou ausente: $($sigItem.Arquivo) - $($sigItem.Status)."
    }
}

$serviceResults = Get-CimInstance Win32_Service |
    Where-Object { $_.Name -in @("sppsvc","ClipSVC") } |
    Select-Object Name, DisplayName, State, StartMode, Status, PathName
$serviceResults | Format-Table -AutoSize | Out-File (Join-Path $outDir "07_SERVICOS_LICENCIAMENTO.txt") -Encoding utf8 -Width 4096

foreach ($svc in $serviceResults) {
    if ($svc.StartMode -eq "Disabled") {
        Add-Alert "O serviço $($svc.Name) está desabilitado."
    }
}

# -------------------------------------------------------------------------
# 6. Busca por indícios comuns de ativadores
# -------------------------------------------------------------------------
$regexActivator = "(?i)KMSpico|KMSAuto|AutoKMS|AAct|HEU.?KMS|MAS_AIO|Microsoft.?Activation.?Scripts|HWID.?Activation|KMS_VL_ALL|Re-Loader"

try {
    Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
        $actionText = ($_.Actions | Out-String)
        $combined = "$($_.TaskName) $($_.TaskPath) $actionText"
        if ($combined -match $regexActivator) {
            $suspects.Add([pscustomobject]@{
                Tipo    = "Tarefa agendada"
                Nome    = "$($_.TaskPath)$($_.TaskName)"
                Detalhe = $actionText.Trim()
            }) | Out-Null
        }
    }
} catch {}

try {
    Get-CimInstance Win32_Service | ForEach-Object {
        $combined = "$($_.Name) $($_.DisplayName) $($_.PathName)"
        if ($combined -match $regexActivator) {
            $suspects.Add([pscustomobject]@{
                Tipo    = "Serviço"
                Nome    = $_.Name
                Detalhe = "$($_.DisplayName) | $($_.PathName)"
            }) | Out-Null
        }
    }
} catch {}

$uninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

foreach ($root in $uninstallRoots) {
    Get-ItemProperty $root -ErrorAction SilentlyContinue |
        Where-Object {
            "$($_.DisplayName) $($_.Publisher) $($_.InstallLocation)" -match $regexActivator
        } |
        ForEach-Object {
            $suspects.Add([pscustomobject]@{
                Tipo    = "Programa instalado"
                Nome    = $_.DisplayName
                Detalhe = "$($_.Publisher) | $($_.InstallLocation)"
            }) | Out-Null
        }
}

# Entradas suspeitas no arquivo hosts
$hostsPath = "$env:windir\System32\drivers\etc\hosts"
if (Test-Path $hostsPath) {
    $hostsMatches = Get-Content $hostsPath -ErrorAction SilentlyContinue |
        Where-Object {
            $_ -notmatch "^\s*#" -and
            $_ -match "(?i)activation|validation|sls\.microsoft|licensing\.mp\.microsoft"
        }
    foreach ($line in $hostsMatches) {
        $suspects.Add([pscustomobject]@{
            Tipo    = "Arquivo hosts"
            Nome    = "Entrada relacionada à ativação"
            Detalhe = $line.Trim()
        }) | Out-Null
    }
}

if ($suspects.Count -gt 0) {
    $suspects | Export-Csv (Join-Path $outDir "08_INDICIOS_ATIVADORES.csv") -NoTypeInformation -Encoding UTF8
    Add-Alert "Foram encontrados $($suspects.Count) indício(s) nominal(is) que precisam de análise."
} else {
    "Nenhum indício nominal conhecido de ativador foi encontrado." |
        Out-File (Join-Path $outDir "08_INDICIOS_ATIVADORES.txt") -Encoding utf8
}

# -------------------------------------------------------------------------
# 7. Exclusões do Microsoft Defender
# -------------------------------------------------------------------------
try {
    $mp = Get-MpPreference -ErrorAction Stop
    $defenderExclusions = @()
    $defenderExclusions += @($mp.ExclusionPath | Where-Object { $_ })
    $defenderExclusions += @($mp.ExclusionProcess | Where-Object { $_ })
    $defenderExclusions += @($mp.ExclusionExtension | Where-Object { $_ })

    if ($defenderExclusions.Count -gt 0) {
        $defenderExclusions |
            Out-File (Join-Path $outDir "09_EXCLUSOES_DEFENDER.txt") -Encoding utf8
        Add-Alert "Existem $($defenderExclusions.Count) exclusão(ões) no Microsoft Defender; revise o relatório."
    } else {
        "Nenhuma exclusão do Microsoft Defender foi encontrada." |
            Out-File (Join-Path $outDir "09_EXCLUSOES_DEFENDER.txt") -Encoding utf8
    }
} catch {
    "Não foi possível consultar as exclusões do Defender: $($_.Exception.Message)" |
        Out-File (Join-Path $outDir "09_EXCLUSOES_DEFENDER.txt") -Encoding utf8
}

# -------------------------------------------------------------------------
# 8. Classificação técnica
# -------------------------------------------------------------------------
$verdict = ""
$verdictLevel = ""
$channel = ""
$licenseStatusCode = -1

if ($null -ne $currentProduct) {
    $channel = [string]$currentProduct.Description
    $licenseStatusCode = [int]$currentProduct.LicenseStatus
}

$isKms = ($channel -match "(?i)VOLUME_KMSCLIENT|\bKMS\b") -or
         (-not [string]::IsNullOrWhiteSpace($manualKmsName)) -or
         (-not [string]::IsNullOrWhiteSpace([string]$sls.KeyManagementServiceMachine))

$isOem = $channel -match "(?i)OEM"
$isRetail = $channel -match "(?i)RETAIL"
$isMak = $channel -match "(?i)VOLUME_MAK|\bMAK\b"
$hasSeriousAlerts = $alerts.Count -gt 0

if ($null -eq $currentProduct) {
    $verdictLevel = "REPROVADO"
    $verdict = "Nenhuma licença ativa do Windows foi identificada."
}
elseif ($licenseStatusCode -ne 1) {
    $verdictLevel = "REPROVADO"
    $verdict = "O Windows não está no estado Licenciado. Estado: $($statusMap[$licenseStatusCode])."
}
elseif ($isKms) {
    $verdictLevel = "EXIGE COMPROVAÇÃO"
    $verdict = "O Windows está ativado por KMS/volume. Isso pode ser legítimo em empresa ou instituição, mas em computador pessoal exige prova de vínculo com a organização licenciada. Sem essa prova, é suspeito."
}
elseif ($isOem -and $oemKeyPresent -and -not $hasSeriousAlerts) {
    $verdictLevel = "FORTE EVIDÊNCIA DE LICENÇA OEM CORRETA"
    $verdict = "O Windows está licenciado, usa canal OEM, possui chave OEM OA3 no firmware, não há KMS manual e não foram encontrados indícios nominais de ativadores."
}
elseif ($isOem -and $oemKeyPresent) {
    $verdictLevel = "LICENCIADO, MAS REQUER REVISÃO"
    $verdict = "A ativação OEM e a chave no firmware são sinais positivos, porém existem alertas técnicos que devem ser analisados."
}
elseif ($isRetail -and -not $hasSeriousAlerts) {
    $verdictLevel = "ATIVADO CORRETAMENTE; ORIGEM COMERCIAL NÃO COMPROVADA"
    $verdict = "O Windows está licenciado por canal Retail e não foram encontrados indícios técnicos de ativador. Somente a nota fiscal, a conta Microsoft ou a confirmação da Microsoft comprovam a origem comercial da chave."
}
elseif ($isMak) {
    $verdictLevel = "ATIVADO POR LICENÇA DE VOLUME"
    $verdict = "O Windows está ativado por MAK. Pode ser legítimo, mas requer documentação da empresa ou instituição titular da licença."
}
else {
    $verdictLevel = "ATIVADO, CANAL REQUER ANÁLISE"
    $verdict = "O Windows aparece como licenciado, mas o canal não permitiu uma conclusão técnica forte."
}

# -------------------------------------------------------------------------
# 9. Relatório final
# -------------------------------------------------------------------------
Add-ReportLine "AUDITORIA TÉCNICA DA LICENÇA DO WINDOWS"
Add-ReportLine "Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
Add-ReportLine ""
Add-ReportLine "VERSÃO DO WINDOWS"
Add-ReportLine "Sistema: $windowsGeneration"
Add-ReportLine "Edição: $editionFriendly"
Add-ReportLine "Versão: $($cv.DisplayVersion)"
Add-ReportLine "Build: $fullBuild"
Add-ReportLine ""
Add-ReportLine "ATIVAÇÃO"
if ($null -ne $currentProduct) {
    Add-ReportLine "Nome da licença: $($currentProduct.Name)"
    Add-ReportLine "Canal: $channel"
    Add-ReportLine "Status: $($statusMap[$licenseStatusCode])"
    Add-ReportLine "Chave parcial: $($currentProduct.PartialProductKey)"
} else {
    Add-ReportLine "Nenhum produto Windows com chave parcial foi localizado."
}
Add-ReportLine "Chave OEM OA3 presente no firmware: $oemKeyPresent"
Add-ReportLine "Servidor KMS manual: $(if ([string]::IsNullOrWhiteSpace($manualKmsName)) { 'Não encontrado' } else { $manualKmsName })"
Add-ReportLine "Indícios nominais de ativadores: $($suspects.Count)"
Add-ReportLine ""
Add-ReportLine "VEREDITO TÉCNICO"
Add-ReportLine $verdictLevel
Add-ReportLine $verdict
Add-ReportLine ""
Add-ReportLine "ALERTAS"
if ($alerts.Count -eq 0) {
    Add-ReportLine "Nenhum alerta técnico relevante foi encontrado."
} else {
    foreach ($alert in $alerts) {
        Add-ReportLine "- $alert"
    }
}
Add-ReportLine ""
Add-ReportLine "LIMITAÇÃO IMPORTANTE"
Add-ReportLine "Nenhum script consegue provar com certeza absoluta a propriedade legal ou a origem comercial de uma licença."
Add-ReportLine "A ativação confirma que o Windows foi aceito tecnicamente pelo sistema de licenciamento da Microsoft."
Add-ReportLine "A certeza jurídica exige nota fiscal, comprovante de compra, vínculo com a conta Microsoft ou confirmação direta da Microsoft."
Add-ReportLine ""
Add-ReportLine "ARQUIVOS DE APOIO"
Add-ReportLine "Consulte também 04_SLMGR_DLV.txt e 05_SLMGR_XPR.txt."

$report | Out-File (Join-Path $outDir "RESULTADO_LEIA_PRIMEIRO.txt") -Encoding utf8 -Width 4096

$summary = [pscustomobject]@{
    Sistema                 = $windowsGeneration
    Edicao                  = $editionFriendly
    Versao                  = $cv.DisplayVersion
    Build                   = $fullBuild
    StatusLicenca           = if ($null -ne $currentProduct) { $statusMap[$licenseStatusCode] } else { "Não localizada" }
    Canal                   = $channel
    OEMNoFirmware           = $oemKeyPresent
    ServidorKMSManual       = $manualKmsName
    IndiciosAtivador        = $suspects.Count
    QuantidadeAlertas       = $alerts.Count
    Veredito                = $verdictLevel
    Explicacao              = $verdict
}
$summary | Export-Csv (Join-Path $outDir "RESULTADO_RESUMIDO.csv") -NoTypeInformation -Encoding UTF8

Stop-Transcript | Out-Null

$zipPath = Join-Path $desktop "Auditoria_Licenca_Windows_$timestamp.zip"
Compress-Archive -Path $outDir -DestinationPath $zipPath -CompressionLevel Optimal -Force

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " AUDITORIA CONCLUÍDA" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Resultado: $verdictLevel" -ForegroundColor Yellow
Write-Host ""
Write-Host $verdict
Write-Host ""
Write-Host "Abra primeiro:" -ForegroundColor Cyan
Write-Host (Join-Path $outDir "RESULTADO_LEIA_PRIMEIRO.txt")
Write-Host ""
Write-Host "ZIP gerado para análise:" -ForegroundColor Cyan
Write-Host $zipPath
Write-Host ""
Read-Host "Pressione ENTER para fechar"
