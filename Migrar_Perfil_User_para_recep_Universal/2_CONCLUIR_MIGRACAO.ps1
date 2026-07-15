#requires -version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$StateFile='C:\ProgramData\APX-PerfilRecep\estado.json'
function IsAdmin{$i=[Security.Principal.WindowsIdentity]::GetCurrent();$p=New-Object Security.Principal.WindowsPrincipal($i);$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
function Import-MachineIdentityModule{
 $candidates=@((Join-Path $PSScriptRoot 'MachineIdentity.ps1'),(Join-Path $PSScriptRoot 'Shared\MachineIdentity.ps1'),(Join-Path $PSScriptRoot '..\Shared\MachineIdentity.ps1'))
 foreach($candidate in $candidates){if(Test-Path -LiteralPath $candidate -PathType Leaf){. $candidate;return}}
 throw 'MachineIdentity.ps1 não foi encontrado. Execute novamente a etapa 1 para copiar o módulo de identificação.'
}
if(-not (IsAdmin)){Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"";exit}
Import-MachineIdentityModule
if(-not(Test-Path $StateFile)){throw 'Estado da etapa 1 não encontrado.'}
$state=Get-Content $StateFile -Raw -Encoding UTF8|ConvertFrom-Json
$machineIdentity=Get-MachineIdentity
$current=([Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\')[-1]
if($current -ne 'recep'){throw "Entre na NOVA conta recep. Conta atual: $current"}
if($env:USERPROFILE -ne 'C:\Users\recep'){throw "Perfil atual: $env:USERPROFILE. Esperado: C:\Users\recep"}
if(-not(Test-Path 'C:\Users\User')){throw 'C:\Users\User não foi encontrado.'}
Clear-Host
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' ETAPA 2 - COPIAR DADOS PARA C:\Users\recep' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host 'AppData e NTUSER.DAT não serão copiados.' -ForegroundColor Yellow
Write-Host 'C:\Users\User permanecerá intacta como recuperação.' -ForegroundColor Yellow
if((Read-Host 'Digite COPIAR para continuar').ToUpperInvariant() -ne 'COPIAR'){exit}

$timestamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$logDir=Join-Path ([Environment]::GetFolderPath('Desktop')) "Migracao_Perfil_Recep_$timestamp"
New-Item -ItemType Directory -Path $logDir -Force|Out-Null
Start-Transcript (Join-Path $logDir 'transcricao.txt') -Force|Out-Null
Save-MachineIdentity -Identity $machineIdentity -Path (Join-Path $logDir '00_IDENTIFICACAO_MAQUINA.txt')
$folders='Desktop','Documents','Downloads','Pictures','Music','Videos','Favorites','Links','Contacts','Saved Games'
$results=@()
foreach($f in $folders){
 $src=Join-Path 'C:\Users\User' $f; $dst=Join-Path 'C:\Users\recep' $f
 if(Test-Path $src){
  New-Item -ItemType Directory -Path $dst -Force|Out-Null
  $log=Join-Path $logDir ("robocopy_"+($f -replace '[^\w-]','_')+'.log')
  & robocopy.exe $src $dst /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /FFT /NP /LOG:$log
  $code=$LASTEXITCODE
  $results+=[pscustomobject]@{Pasta=$f;Codigo=$code;Resultado=$(if($code -lt 8){'Concluído'}else{'Falha'})}
 }else{$results+=[pscustomobject]@{Pasta=$f;Codigo=0;Resultado='Origem inexistente'}}
}
$results|Export-Csv (Join-Path $logDir 'resultado_copia.csv') -NoTypeInformation -Encoding UTF8
$failed=@($results|Where-Object Codigo -ge 8)
if($failed.Count -eq 0){
 try{Disable-LocalUser -Name 'recep_antigo'}catch{}
 $state.Completed=$true;$state.CompletedAt=(Get-Date).ToString('o')
 $state|ConvertTo-Json -Depth 4|Out-File $StateFile -Encoding utf8
}
Stop-Transcript|Out-Null
Compress-Archive -Path $logDir -DestinationPath "$logDir.zip" -Force
Write-Host ''
if($failed.Count -eq 0){Write-Host 'MIGRAÇÃO CONCLUÍDA.' -ForegroundColor Green}else{Write-Host "Falha em $($failed.Count) pasta(s). Consulte o relatório." -ForegroundColor Red}
Write-Host "Perfil atual: $env:USERPROFILE" -ForegroundColor Green
Write-Host 'Mantenha C:\Users\User por alguns dias antes de pensar em apagar.' -ForegroundColor Yellow
Write-Host 'Crie novamente o PIN em Configurações > Contas > Opções de entrada.' -ForegroundColor Cyan
Read-Host 'Pressione ENTER para fechar'
