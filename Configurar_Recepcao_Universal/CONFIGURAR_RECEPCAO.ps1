#requires -version 5.1
<#
  RENOMEAÇÃO DO COMPUTADOR E DO USUÁRIO DA RECEPÇÃO

  Equipamento atendido:
  - Lenovo, Dell ou outro computador Windows com identificação automática.

  Alterações:
  - Nome válido do computador gerado pelo fabricante/modelo detectado;
  - Nome de entrada da conta local: recep
  - Nome completo: Apaixonados Itaipuaçu Recepção
  - Descrição de rede: Apaixonados Itaipuaçu Recepção

  Observação:
  O nome do computador no Windows deve ter no máximo 15 caracteres e usar
  letras, números ou hífen.

  O script NÃO renomeia C:\Users\<perfil>, pois isso pode danificar o perfil.
#>

[CmdletBinding()]
param(
    [string]$TargetUserName = "recep",
    [string]$TargetFullName = "Apaixonados Itaipuaçu Recepção",
    [string]$TargetDescription = "Recepção - Apaixonados Itaipuaçu",
    [string]$TargetComputerDescription = "Apaixonados Itaipuaçu Recepção",
    [string]$ComputerNameSuffix = "RECEP"
)

$ErrorActionPreference = "Stop"

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

function Test-ValidComputerName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 15) { return $false }
    if ($Name -notmatch '^[A-Za-z0-9-]+$') { return $false }
    if ($Name.StartsWith("-") -or $Name.EndsWith("-")) { return $false }
    if ($Name -match '^\d+$') { return $false }

    return $true
}

if (-not (Test-Administrator)) {
    Write-Host "Solicitando permissão de Administrador..." -ForegroundColor Yellow
    Start-Process powershell.exe `
        -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
        -Verb RunAs
    exit
}

if (-not [Environment]::Is64BitProcess) {
    Write-Host "Execute este script no PowerShell de 64 bits." -ForegroundColor Red
    Read-Host "Pressione ENTER para sair"
    exit 2
}

Import-MachineIdentityModule

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$desktop = [Environment]::GetFolderPath("Desktop")
$logDir = Join-Path $desktop "Renomeacao_Recepcao_$timestamp"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Start-Transcript -Path (Join-Path $logDir "00_TRANSCRICAO.txt") -Force | Out-Null

try {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " CONFIGURAÇÃO DO COMPUTADOR DA RECEPÇÃO" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Write-Section "Identificação do equipamento"

    $machineIdentity = Get-MachineIdentity
    $cs = $machineIdentity.RawComputerSystem
    $csp = $machineIdentity.RawProduct
    $bios = $machineIdentity.RawBios
    $TargetComputerName = New-ClinicComputerName -Identity $machineIdentity -Suffix $ComputerNameSuffix

    if ($TargetDescription.Length -gt 48) {
        throw "A descrição da conta deve ter até 48 caracteres. Valor atual: $($TargetDescription.Length)."
    }

    $equipmentInfo = [pscustomobject]@{
        Fabricante             = $machineIdentity.Manufacturer
        FabricanteNormalizado  = $machineIdentity.Vendor
        NomeAtual              = $env:COMPUTERNAME
        Modelo                 = $machineIdentity.Model
        Produto                = $machineIdentity.ProductName
        VersaoProduto          = $machineIdentity.ProductVersion
        TipoLenovo             = $machineIdentity.LenovoMachineType
        ServiceTagDell         = $machineIdentity.DellServiceTag
        NumeroSerie            = $machineIdentity.SerialNumber
        BIOS                   = $machineIdentity.BiosVersion
        NomeComputadorProposto = $TargetComputerName
    }

    $equipmentInfo | Format-List
    $equipmentInfo |
        Format-List |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $logDir "01_EQUIPAMENTO_ANTES.txt")

    if (-not (Test-ValidComputerName -Name $TargetComputerName)) {
        throw "O nome de computador definido no script é inválido: $TargetComputerName"
    }

    Write-Host "Computador identificado e nome proposto validado." -ForegroundColor Green

    Write-Section "Identificação da conta em uso"

    $interactiveLogon = [string]$cs.UserName
    if ([string]::IsNullOrWhiteSpace($interactiveLogon)) {
        throw "Não foi possível identificar a conta conectada ao Windows."
    }

    $interactiveUserName = ($interactiveLogon -split '\\')[-1]
    $currentLocalUser = Get-LocalUser -Name $interactiveUserName -ErrorAction SilentlyContinue

    if ($null -eq $currentLocalUser) {
        # Segunda tentativa: localizar a conta pelo SID da sessão elevada.
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $currentLocalUser = Get-LocalUser -SID $currentSid -ErrorAction SilentlyContinue
    }

    if ($null -eq $currentLocalUser) {
        throw ("A conta conectada '{0}' não foi localizada como conta local. " +
               "O script não renomeará automaticamente uma conta corporativa, de domínio ou somente Microsoft.") -f $interactiveLogon
    }

    if ($currentLocalUser.SID.Value -match '-(500|501|503|504)$') {
        throw "Por segurança, o script não renomeia contas internas do Windows."
    }

    $oldUserName = [string]$currentLocalUser.Name
    $oldFullName = [string]$currentLocalUser.FullName
    $oldDescription = [string]$currentLocalUser.Description
    $oldComputerName = [string]$env:COMPUTERNAME

    $userProfilePath = $null
    try {
        $profile = Get-CimInstance Win32_UserProfile |
            Where-Object { $_.SID -eq $currentLocalUser.SID.Value } |
            Select-Object -First 1
        $userProfilePath = [string]$profile.LocalPath
    }
    catch {}

    $accountInfo = [pscustomobject]@{
        SessaoInterativa  = $interactiveLogon
        UsuarioAtual      = $oldUserName
        NomeCompletoAtual = $oldFullName
        SID               = $currentLocalUser.SID.Value
        PerfilAtual       = $userProfilePath
        UsuarioDestino    = $TargetUserName
        NomeCompletoNovo  = $TargetFullName
    }

    $accountInfo | Format-List
    $accountInfo |
        Format-List |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $logDir "02_USUARIO_ANTES.txt")

    $targetExisting = Get-LocalUser -Name $TargetUserName -ErrorAction SilentlyContinue
    if ($targetExisting -and $targetExisting.SID.Value -ne $currentLocalUser.SID.Value) {
        throw "Já existe outra conta local chamada '$TargetUserName'. Nenhuma alteração foi realizada."
    }

    Write-Section "Alterações planejadas"

    Write-Host "Nome atual do computador : $oldComputerName"
    Write-Host "Novo nome do computador  : $TargetComputerName" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Usuário atual             : $oldUserName"
    Write-Host "Novo usuário              : $TargetUserName" -ForegroundColor Yellow
    Write-Host "Nome completo             : $TargetFullName" -ForegroundColor Yellow
    Write-Host "Descrição do computador   : $TargetComputerDescription" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "O perfil continuará em: $userProfilePath" -ForegroundColor Cyan
    Write-Host "A senha, o PIN, os arquivos e as permissões da conta serão preservados." -ForegroundColor Cyan
    Write-Host ""

    $confirmation = Read-Host "Digite ALTERAR para confirmar"
    if ($confirmation.Trim().ToUpperInvariant() -ne "ALTERAR") {
        Write-Host "Operação cancelada. Nenhuma alteração foi feita." -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit 0
    }

    Write-Section "Criação do arquivo de reversão"

    $rollbackPs1 = Join-Path $desktop "REVERTER_NOMES_RECEPCAO.ps1"
    $rollbackCmd = Join-Path $desktop "REVERTER_NOMES_RECEPCAO.cmd"

    $escapedOldUserName = $oldUserName.Replace("'", "''")
    $escapedOldFullName = $oldFullName.Replace("'", "''")
    $escapedOldDescription = $oldDescription.Replace("'", "''")
    $escapedOldComputerName = $oldComputerName.Replace("'", "''")

    $rollbackContent = @"
#requires -version 5.1
`$ErrorActionPreference = 'Stop'

function Test-Administrator {
    `$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    `$principal = New-Object Security.Principal.WindowsPrincipal(`$identity)
    return `$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ```"`$PSCommandPath```"" -Verb RunAs
    exit
}

`$target = Get-LocalUser -Name '$TargetUserName' -ErrorAction SilentlyContinue
if (`$target) {
    Rename-LocalUser -SID `$target.SID -NewName '$escapedOldUserName'
    Set-LocalUser -Name '$escapedOldUserName' -FullName '$escapedOldFullName' -Description '$escapedOldDescription'
}

Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'srvcomment' -Value '' -Type String

if (`$env:COMPUTERNAME -ne '$escapedOldComputerName') {
    Rename-Computer -NewName '$escapedOldComputerName' -Force
}

Write-Host ''
Write-Host 'Nomes anteriores restaurados. Reinicie o computador.' -ForegroundColor Green
`$restart = Read-Host 'Digite REINICIAR para reiniciar agora'
if (`$restart.Trim().ToUpperInvariant() -eq 'REINICIAR') {
    Restart-Computer -Force
}
"@

    $rollbackContent |
        Out-File -FilePath $rollbackPs1 -Encoding utf8 -Width 4096

    $rollbackCmdContent = @"
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\Desktop\REVERTER_NOMES_RECEPCAO.ps1"
pause
"@
    $rollbackCmdContent |
        Out-File -FilePath $rollbackCmd -Encoding ascii -Width 4096

    Write-Host "Arquivos de reversão criados na Área de Trabalho." -ForegroundColor Green

    Write-Section "Alteração da conta"

    if ($oldUserName -ne $TargetUserName) {
        Rename-LocalUser -SID $currentLocalUser.SID -NewName $TargetUserName
        Write-Host "Usuário renomeado para: $TargetUserName" -ForegroundColor Green
    }
    else {
        Write-Host "A conta já possui o nome de usuário '$TargetUserName'." -ForegroundColor Green
    }

    Set-LocalUser `
        -Name $TargetUserName `
        -FullName $TargetFullName `
        -Description $TargetDescription

    Write-Host "Nome completo e descrição da conta atualizados." -ForegroundColor Green

    Write-Section "Descrição do computador"

    $serverParameters = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"
    if (-not (Test-Path $serverParameters)) {
        New-Item -Path $serverParameters -Force | Out-Null
    }

    New-ItemProperty `
        -Path $serverParameters `
        -Name "srvcomment" `
        -Value $TargetComputerDescription `
        -PropertyType String `
        -Force | Out-Null

    Write-Host "Descrição configurada: $TargetComputerDescription" -ForegroundColor Green

    Write-Section "Alteração do nome do computador"

    $computerRenamePending = $false

    if ($oldComputerName -ne $TargetComputerName) {
        Rename-Computer -NewName $TargetComputerName -Force
        $computerRenamePending = $true
        Write-Host "Nome do computador preparado para: $TargetComputerName" -ForegroundColor Green
    }
    else {
        Write-Host "O computador já possui o nome '$TargetComputerName'." -ForegroundColor Green
    }

    Write-Section "Verificação final"

    $renamedUser = Get-LocalUser -Name $TargetUserName -ErrorAction Stop
    $configuredDescription = (
        Get-ItemProperty $serverParameters -Name "srvcomment" -ErrorAction Stop
    ).srvcomment

    $result = [pscustomobject]@{
        Data                     = Get-Date
        Fabricante               = $machineIdentity.Vendor
        Modelo                   = $machineIdentity.Model
        TipoLenovo               = $machineIdentity.LenovoMachineType
        ServiceTagDell           = $machineIdentity.DellServiceTag
        ComputadorAntes          = $oldComputerName
        ComputadorDepois         = $TargetComputerName
        ReinicioPendente         = $computerRenamePending
        UsuarioAntes             = $oldUserName
        UsuarioDepois            = $renamedUser.Name
        NomeCompletoDepois       = $renamedUser.FullName
        SIDPreservado            = ($renamedUser.SID.Value -eq $currentLocalUser.SID.Value)
        PerfilPreservado         = $userProfilePath
        DescricaoComputador      = $configuredDescription
        ArquivoReversaoPowerShell= $rollbackPs1
        ArquivoReversaoCMD       = $rollbackCmd
    }

    $result | Format-List
    $result |
        Format-List |
        Out-String -Width 4096 |
        Save-Text -Path (Join-Path $logDir "RESULTADO_LEIA_PRIMEIRO.txt")

    $result |
        Export-Csv (Join-Path $logDir "RESULTADO_RESUMIDO.csv") `
            -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " ALTERAÇÕES CONCLUÍDAS" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Novo computador : $TargetComputerName"
    Write-Host "Novo usuário    : $TargetUserName"
    Write-Host "Nome completo   : $TargetFullName"
    Write-Host ""
    Write-Host "O perfil continuará em $userProfilePath — isso é esperado." -ForegroundColor Cyan
    Write-Host "É necessário reiniciar para concluir o nome do computador." -ForegroundColor Yellow
    Write-Host ""

    Stop-Transcript | Out-Null

    $zipPath = Join-Path $desktop "Relatorio_Renomeacao_Recepcao_$timestamp.zip"
    Compress-Archive -Path $logDir -DestinationPath $zipPath -CompressionLevel Optimal -Force

    $restart = Read-Host "Digite REINICIAR para reiniciar agora, ou pressione ENTER para reiniciar depois"
    if ($restart.Trim().ToUpperInvariant() -eq "REINICIAR") {
        Restart-Computer -Force
    }
}
catch {
    $errorText = @"
MENSAGEM
$($_.Exception.Message)

POSIÇÃO
$($_.InvocationInfo.PositionMessage)

PILHA
$($_.ScriptStackTrace)

DETALHES
$($_ | Out-String)
"@

    Save-Text -Path (Join-Path $logDir "ERRO.txt") -Content $errorText

    Write-Host ""
    Write-Host "A operação foi interrompida:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    try { Stop-Transcript | Out-Null } catch {}

    Read-Host "Pressione ENTER para fechar"
    exit 1
}
