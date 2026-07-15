#requires -version 5.1
$ErrorActionPreference='Stop'
function IsAdmin{$i=[Security.Principal.WindowsIdentity]::GetCurrent();$p=New-Object Security.Principal.WindowsPrincipal($i);$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
function Import-MachineIdentityModule{
 $candidates=@((Join-Path $PSScriptRoot 'MachineIdentity.ps1'),(Join-Path $PSScriptRoot 'Shared\MachineIdentity.ps1'),(Join-Path $PSScriptRoot '..\Shared\MachineIdentity.ps1'))
 foreach($candidate in $candidates){if(Test-Path -LiteralPath $candidate -PathType Leaf){. $candidate;return}}
 throw 'MachineIdentity.ps1 não foi encontrado. Execute novamente a etapa 1 para copiar o módulo de identificação.'
}
if(-not(IsAdmin)){Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"";exit}
Import-MachineIdentityModule
$state='C:\ProgramData\APX-PerfilRecep\estado.json'
if(-not(Test-Path $state)){throw 'Estado não encontrado.'}
$machineIdentity=Get-MachineIdentity
Save-MachineIdentity -Identity $machineIdentity -Path 'C:\ProgramData\APX-PerfilRecep\identificacao_reversao.txt'
Write-Host 'A reversão não apaga arquivos. Ela devolve o nome recep à conta antiga.' -ForegroundColor Yellow
if((Read-Host 'Digite REVERTER').ToUpperInvariant() -ne 'REVERTER'){exit}
$new=Get-LocalUser -Name 'recep' -ErrorAction SilentlyContinue
$old=Get-LocalUser -Name 'recep_antigo' -ErrorAction SilentlyContinue
if($new){$name='recep_novo';if(Get-LocalUser -Name $name -ErrorAction SilentlyContinue){$name='recep_novo_'+(Get-Date -Format HHmmss)};Rename-LocalUser -SID $new.SID -NewName $name}
if($old){Enable-LocalUser -Name 'recep_antigo';Rename-LocalUser -SID $old.SID -NewName 'recep'}
Write-Host 'Reversão preparada. Reinicie e entre em recep.' -ForegroundColor Green
if((Read-Host 'Digite REINICIAR para reiniciar agora').ToUpperInvariant() -eq 'REINICIAR'){Restart-Computer -Force}
