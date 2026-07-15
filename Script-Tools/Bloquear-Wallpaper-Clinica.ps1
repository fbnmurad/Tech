#requires -version 5.1
<#
Bloqueia ou libera a troca do wallpaper da area de trabalho e da tela de bloqueio.

Exemplos:
  .\Bloquear-Wallpaper-Clinica.ps1 -Acao Aplicar -Usuario recep -WallpaperPath "C:\ProgramData\BGInfo\Wallpaper_APQPP.bmp"
  .\Bloquear-Wallpaper-Clinica.ps1 -Acao Aplicar -WallpaperPath "C:\ProgramData\Clinica\Wallpaper.jpg"
  .\Bloquear-Wallpaper-Clinica.ps1 -Acao Verificar -Usuario recep
  .\Bloquear-Wallpaper-Clinica.ps1 -Acao Remover -Usuario recep
#>

[CmdletBinding()]
param(
    [ValidateSet("Aplicar", "Remover", "Verificar")]
    [string]$Acao = "Aplicar",

    [string]$Usuario,

    [string]$WallpaperPath,

    [ValidateSet("Preencher", "Ajustar", "Estender", "Centralizar", "LadoALado")]
    [string]$Estilo = "Preencher"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Administrador {
    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identidade)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrador)) {
    throw "Abra o PowerShell como administrador e execute o script novamente."
}

$estilos = @{
    Preencher   = @{ WallpaperStyle = "10"; TileWallpaper = "0" }
    Ajustar     = @{ WallpaperStyle = "6";  TileWallpaper = "0" }
    Estender    = @{ WallpaperStyle = "22"; TileWallpaper = "0" }
    Centralizar = @{ WallpaperStyle = "0";  TileWallpaper = "0" }
    LadoALado   = @{ WallpaperStyle = "0";  TileWallpaper = "1" }
}

function Get-PerfisLocais {
    $profileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

    $itens = foreach ($chave in Get-ChildItem $profileList) {
        $sid = $chave.PSChildName

        if ($sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') {
            continue
        }

        $dados = Get-ItemProperty $chave.PSPath
        $caminho = [Environment]::ExpandEnvironmentVariables([string]$dados.ProfileImagePath)

        if (-not (Test-Path -LiteralPath $caminho)) {
            continue
        }

        [pscustomobject]@{
            Sid     = $sid
            Nome    = Split-Path -Path $caminho -Leaf
            Caminho = $caminho
        }
    }

    if ($Usuario) {
        $conta = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" |
            Where-Object { $_.Name -ieq $Usuario } |
            Select-Object -First 1

        if (-not $conta) {
            throw "O usuario local '$Usuario' nao foi encontrado."
        }

        $selecionado = $itens | Where-Object { $_.Sid -eq $conta.SID }

        if (-not $selecionado) {
            throw "O perfil do usuario '$Usuario' ainda nao existe ou nao foi inicializado."
        }

        return @($selecionado)
    }

    return @($itens)
}

function Invoke-NoHiveUsuario {
    param(
        [Parameter(Mandatory)] [pscustomobject]$Perfil,
        [Parameter(Mandatory)] [scriptblock]$Operacao
    )

    $jaCarregado = Test-Path "Registry::HKEY_USERS\$($Perfil.Sid)"
    $nomeTemporario = "APQPP_$([Guid]::NewGuid().ToString('N'))"
    $raiz = $null
    $carregadoPeloScript = $false

    try {
        if ($jaCarregado) {
            $raiz = "Registry::HKEY_USERS\$($Perfil.Sid)"
        }
        else {
            $ntUser = Join-Path $Perfil.Caminho "NTUSER.DAT"

            if (-not (Test-Path -LiteralPath $ntUser)) {
                throw "NTUSER.DAT nao encontrado para o perfil '$($Perfil.Nome)'."
            }

            & reg.exe load "HKU\$nomeTemporario" "$ntUser" | Out-Null

            if ($LASTEXITCODE -ne 0) {
                throw "Nao foi possivel carregar o Registro do perfil '$($Perfil.Nome)'."
            }

            $raiz = "Registry::HKEY_USERS\$nomeTemporario"
            $carregadoPeloScript = $true
        }

        & $Operacao $raiz $Perfil
    }
    finally {
        if ($carregadoPeloScript) {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 300
            & reg.exe unload "HKU\$nomeTemporario" | Out-Null
        }
    }
}

function Get-WallpaperAtual {
    param([string]$Raiz)

    $desktop = Join-Path $Raiz "Control Panel\Desktop"

    try {
        $valor = (Get-ItemProperty -Path $desktop -Name WallPaper -ErrorAction Stop).WallPaper

        if ($valor -and (Test-Path -LiteralPath $valor)) {
            return [string]$valor
        }
    }
    catch {}

    return $null
}

function Set-BloqueioUsuario {
    param(
        [string]$Raiz,
        [pscustomobject]$Perfil,
        [string]$Imagem
    )

    $activeDesktop = Join-Path $Raiz "Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop"
    $systemPolicy  = Join-Path $Raiz "Software\Microsoft\Windows\CurrentVersion\Policies\System"
    $desktop       = Join-Path $Raiz "Control Panel\Desktop"

    New-Item -Path $activeDesktop -Force | Out-Null
    New-Item -Path $systemPolicy  -Force | Out-Null
    New-Item -Path $desktop       -Force | Out-Null

    New-ItemProperty -Path $activeDesktop -Name "NoChangingWallPaper" `
        -PropertyType DWord -Value 1 -Force | Out-Null

    if (-not $Imagem) {
        $Imagem = Get-WallpaperAtual -Raiz $Raiz
    }

    if (-not $Imagem) {
        Write-Warning "Wallpaper nao localizado para '$($Perfil.Nome)'. Execute novamente usando -WallpaperPath."
        return
    }

    if (-not (Test-Path -LiteralPath $Imagem)) {
        throw "A imagem '$Imagem' nao existe."
    }

    New-ItemProperty -Path $systemPolicy -Name "Wallpaper" `
        -PropertyType String -Value $Imagem -Force | Out-Null

    New-ItemProperty -Path $systemPolicy -Name "WallpaperStyle" `
        -PropertyType String -Value $estilos[$Estilo].WallpaperStyle -Force | Out-Null

    New-ItemProperty -Path $desktop -Name "WallPaper" `
        -PropertyType String -Value $Imagem -Force | Out-Null

    New-ItemProperty -Path $desktop -Name "WallpaperStyle" `
        -PropertyType String -Value $estilos[$Estilo].WallpaperStyle -Force | Out-Null

    New-ItemProperty -Path $desktop -Name "TileWallpaper" `
        -PropertyType String -Value $estilos[$Estilo].TileWallpaper -Force | Out-Null

    Write-Host "[OK] Wallpaper bloqueado para: $($Perfil.Nome)"
    Write-Host "     Imagem: $Imagem"
}

function Remove-BloqueioUsuario {
    param(
        [string]$Raiz,
        [pscustomobject]$Perfil
    )

    $activeDesktop = Join-Path $Raiz "Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop"
    $systemPolicy  = Join-Path $Raiz "Software\Microsoft\Windows\CurrentVersion\Policies\System"

    Remove-ItemProperty -Path $activeDesktop -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $systemPolicy -Name "Wallpaper" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $systemPolicy -Name "WallpaperStyle" -ErrorAction SilentlyContinue

    Write-Host "[OK] Troca de wallpaper liberada para: $($Perfil.Nome)"
}

function Get-EstadoUsuario {
    param(
        [string]$Raiz,
        [pscustomobject]$Perfil
    )

    $activeDesktop = Join-Path $Raiz "Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop"
    $systemPolicy  = Join-Path $Raiz "Software\Microsoft\Windows\CurrentVersion\Policies\System"
    $bloqueado = $false
    $imagem = $null

    try {
        $bloqueado = (
            Get-ItemProperty -Path $activeDesktop -Name "NoChangingWallPaper" -ErrorAction Stop
        ).NoChangingWallPaper -eq 1
    }
    catch {}

    try {
        $imagem = (
            Get-ItemProperty -Path $systemPolicy -Name "Wallpaper" -ErrorAction Stop
        ).Wallpaper
    }
    catch {}

    [pscustomobject]@{
        Usuario             = $Perfil.Nome
        SID                 = $Perfil.Sid
        WallpaperBloqueado  = $bloqueado
        WallpaperDaPolitica = $imagem
    }
}

$chavePersonalizacao = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
$perfis = Get-PerfisLocais

if ($WallpaperPath) {
    $WallpaperPath = [Environment]::ExpandEnvironmentVariables($WallpaperPath)

    if (-not (Test-Path -LiteralPath $WallpaperPath)) {
        throw "O arquivo informado nao existe: $WallpaperPath"
    }

    $WallpaperPath = (Resolve-Path -LiteralPath $WallpaperPath).Path
}

switch ($Acao) {
    "Aplicar" {
        foreach ($perfil in $perfis) {
            Invoke-NoHiveUsuario -Perfil $perfil -Operacao {
                param($raiz, $dadosPerfil)
                Set-BloqueioUsuario -Raiz $raiz -Perfil $dadosPerfil -Imagem $WallpaperPath
            }
        }

        New-Item -Path $chavePersonalizacao -Force | Out-Null
        New-ItemProperty -Path $chavePersonalizacao -Name "NoChangingLockScreen" `
            -PropertyType DWord -Value 1 -Force | Out-Null

        Write-Host ""
        Write-Host "[OK] Troca da tela de bloqueio bloqueada para todo o computador."
        Write-Host "Reinicie ou encerre a sessao para aplicar completamente."
    }

    "Remover" {
        foreach ($perfil in $perfis) {
            Invoke-NoHiveUsuario -Perfil $perfil -Operacao {
                param($raiz, $dadosPerfil)
                Remove-BloqueioUsuario -Raiz $raiz -Perfil $dadosPerfil
            }
        }

        Remove-ItemProperty -Path $chavePersonalizacao -Name "NoChangingLockScreen" `
            -ErrorAction SilentlyContinue

        Write-Host ""
        Write-Host "[OK] Troca da tela de bloqueio liberada."
        Write-Host "Reinicie ou encerre a sessao para concluir."
    }

    "Verificar" {
        $resultado = foreach ($perfil in $perfis) {
            $estadoLocal = $null

            Invoke-NoHiveUsuario -Perfil $perfil -Operacao {
                param($raiz, $dadosPerfil)
                $script:estadoLocal = Get-EstadoUsuario -Raiz $raiz -Perfil $dadosPerfil
            }

            $script:estadoLocal
        }

        $lockBloqueado = $false

        try {
            $lockBloqueado = (
                Get-ItemProperty -Path $chavePersonalizacao -Name "NoChangingLockScreen" `
                    -ErrorAction Stop
            ).NoChangingLockScreen -eq 1
        }
        catch {}

        $resultado | Format-Table -AutoSize
        Write-Host ""
        Write-Host "Tela de bloqueio protegida: $lockBloqueado"
    }
}
