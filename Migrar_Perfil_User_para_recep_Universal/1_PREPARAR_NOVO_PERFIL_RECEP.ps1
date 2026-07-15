#requires -version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$StateRoot='C:\ProgramData\APX-PerfilRecep'
$StateFile=Join-Path $StateRoot 'estado.json'
$PublicDesktop='C:\Users\Public\Desktop'

function IsAdmin {
 $i=[Security.Principal.WindowsIdentity]::GetCurrent();
 $p=New-Object Security.Principal.WindowsPrincipal($i)
 $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function SecureToPlain([Security.SecureString]$s){
 $p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
 try{[Runtime.InteropServices.Marshal]::PtrToStringBSTR($p)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}
}
function Import-MachineIdentityModule{
 $candidates=@((Join-Path $PSScriptRoot 'MachineIdentity.ps1'),(Join-Path $PSScriptRoot 'Shared\MachineIdentity.ps1'),(Join-Path $PSScriptRoot '..\Shared\MachineIdentity.ps1'))
 foreach($candidate in $candidates){if(Test-Path -LiteralPath $candidate -PathType Leaf){. $candidate;return}}
 throw 'MachineIdentity.ps1 não foi encontrado. Mantenha a pasta Shared junto ao pacote ou copie o arquivo para a pasta do script.'
}
if(-not (IsAdmin)){
 Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""; exit
}
Import-MachineIdentityModule
Clear-Host
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' ETAPA 1 - CRIAR NOVO PERFIL C:\Users\recep' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$machineIdentity=Get-MachineIdentity
$cs=$machineIdentity.RawComputerSystem
New-Item -ItemType Directory -Path $StateRoot -Force|Out-Null
Save-MachineIdentity -Identity $machineIdentity -Path (Join-Path $StateRoot 'identificacao_etapa1.txt')
Write-Host "Computador: $($machineIdentity.ComputerName)"
Write-Host "Fabricante: $($machineIdentity.Vendor)"
Write-Host "Modelo: $($machineIdentity.Model)"
Write-Host "Windows: $($machineIdentity.WindowsVersion) build $($machineIdentity.WindowsBuild)"
$interactive=([string]$cs.UserName -split '\\')[-1]
if($interactive -ne 'recep'){throw "Entre na conta recep. Conta detectada: $interactive"}
$old=Get-LocalUser -Name 'recep' -ErrorAction Stop
$profile=Get-CimInstance Win32_UserProfile|Where-Object SID -eq $old.SID.Value|Select-Object -First 1
if(-not $profile){throw 'Perfil da conta recep não encontrado.'}
if($profile.LocalPath -ne 'C:\Users\User'){throw "Caminho atual diferente do esperado: $($profile.LocalPath)"}
if(Test-Path 'C:\Users\recep'){throw 'C:\Users\recep já existe. Processo cancelado.'}
if(Get-LocalUser -Name 'recep_antigo' -ErrorAction SilentlyContinue){throw 'Já existe a conta recep_antigo.'}

$adminGroup=Get-LocalGroup -SID 'S-1-5-32-544'
$adminMembers=Get-LocalGroupMember -Group $adminGroup.Name
if($adminMembers.SID.Value -notcontains $old.SID.Value){throw 'A conta recep precisa ser administradora para esta migração.'}

$groups=@()
foreach($g in Get-LocalGroup){
 try{if((Get-LocalGroupMember -Group $g.Name).SID.Value -contains $old.SID.Value){$groups+=$g.Name}}catch{}
}
$groups=$groups|Select-Object -Unique

Write-Host "Conta atual : $($old.Name)"
Write-Host "Perfil atual: $($profile.LocalPath)"
Write-Host ''
Write-Host 'Será criada uma NOVA conta recep, gerando C:\Users\recep.' -ForegroundColor Yellow
Write-Host 'A conta antiga será preservada como recep_antigo.' -ForegroundColor Yellow
Write-Host 'O PIN deverá ser criado novamente e alguns aplicativos pedirão novo login.' -ForegroundColor Yellow
Write-Host ''
if((Read-Host 'Digite MIGRAR para continuar').ToUpperInvariant() -ne 'MIGRAR'){exit}

do{
 $s1=Read-Host 'Crie uma senha para a nova conta recep' -AsSecureString
 $s2=Read-Host 'Repita a senha' -AsSecureString
 $p1=SecureToPlain $s1; $p2=SecureToPlain $s2
 $ok=($p1 -ceq $p2 -and $p1.Length -ge 8)
 $p1=$null;$p2=$null
 if(-not $ok){Write-Host 'As senhas devem ser iguais e ter pelo menos 8 caracteres.' -ForegroundColor Red}
}until($ok)

$src=Split-Path -Parent $PSCommandPath
$machineIdentityModule=@((Join-Path $src 'MachineIdentity.ps1'),(Join-Path $src 'Shared\MachineIdentity.ps1'),(Join-Path $src '..\Shared\MachineIdentity.ps1'))|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
Copy-Item (Join-Path $src '2_CONCLUIR_MIGRACAO.ps1') $StateRoot -Force
Copy-Item (Join-Path $src '2_CONCLUIR_MIGRACAO.cmd') $PublicDesktop -Force
Copy-Item (Join-Path $src 'REVERTER_MIGRACAO.ps1') $StateRoot -Force
Copy-Item (Join-Path $src 'REVERTER_MIGRACAO.cmd') $PublicDesktop -Force
if($machineIdentityModule){Copy-Item $machineIdentityModule $StateRoot -Force}

$state=[ordered]@{OldAccount='recep_antigo';NewAccount='recep';OldSid=$old.SID.Value;OldProfile='C:\Users\User';NewProfile='C:\Users\recep';Groups=$groups;Completed=$false;ComputerName=$machineIdentity.ComputerName;Vendor=$machineIdentity.Vendor;Model=$machineIdentity.Model;LenovoMachineType=$machineIdentity.LenovoMachineType;DellServiceTag=$machineIdentity.DellServiceTag}
$state|ConvertTo-Json -Depth 4|Out-File $StateFile -Encoding utf8

Rename-LocalUser -SID $old.SID -NewName 'recep_antigo'
try{
 New-LocalUser -Name 'recep' -Password $s1 -FullName 'Apaixonados Itaipuaçu Recepção' -Description 'Recepção - Apaixonados Itaipuaçu' -AccountNeverExpires|Out-Null
 $new=Get-LocalUser -Name 'recep'
 foreach($g in $groups){try{Add-LocalGroupMember -Group $g -Member $new.Name -ErrorAction Stop}catch{}}
 try{Add-LocalGroupMember -Group $adminGroup.Name -Member $new.Name -ErrorAction SilentlyContinue}catch{}
}catch{
 $r=Get-LocalUser -Name 'recep_antigo' -ErrorAction SilentlyContinue
 if($r){Rename-LocalUser -SID $r.SID -NewName 'recep'}
 throw
}

Write-Host ''
Write-Host 'ETAPA 1 CONCLUÍDA.' -ForegroundColor Green
Write-Host 'Encerre a sessão e entre na NOVA conta recep com a senha criada.' -ForegroundColor Yellow
Write-Host 'Depois execute no Desktop: 2_CONCLUIR_MIGRACAO.cmd' -ForegroundColor Cyan
if((Read-Host 'Digite SAIR para encerrar a sessão agora').ToUpperInvariant() -eq 'SAIR'){shutdown.exe /l}
