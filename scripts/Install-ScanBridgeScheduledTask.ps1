<#
.SYNOPSIS
    Plans or registers a local ScanBridge task using NSP.Win.ScheduledTask.
.DESCRIPTION
    Plan-only unless -Execute is supplied. Does not run ScanBridge, install dependencies,
    provision certificates, change permissions or start the task manually. Registration
    enables future scheduled execution: provision and validate the selected task account first.
    Runner, configuration and PowerShell paths must already exist on this computer.
    Supply -ReplaceExisting explicitly to replace an existing task with the same path/name.
.EXAMPLE
    .\Install-ScanBridgeScheduledTask.ps1 -RunnerPath C:\Jobs\Run-ScanBridge.ps1 `
        -ConfigurationPath C:\Private\ScanBridge.psd1 -RunAs 'CONTOSO\svc_scan$' `
        -PowerShellPath C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][string]$PowerShellPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunAs,
    [pscredential]$Credential,
    [ValidateRange(1,1440)][int]$EveryMinutes = 5,
    [datetime]$FirstRun = (Get-Date).AddMinutes(2),
    [ValidateRange(1,1440)][int]$TimeLimitMinutes = 30,
    [ValidateNotNullOrEmpty()][string]$TaskName = 'ScanBridge',
    [string]$TaskPath = '\NSP\',
    [string]$SchedulingModulePath,
    [switch]$SkipAlerts,
    [switch]$Execute,
    [switch]$ReplaceExisting
)
$ErrorActionPreference = 'Stop'

function Resolve-TaskFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'A required task file does not exist on this computer.' }
    $resolved = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    if ($resolved -match '["\r\n]') { throw 'Task file paths cannot contain quotation marks or newlines.' }
    $resolved
}
$runner = Resolve-TaskFile $RunnerPath
$configuration = Resolve-TaskFile $ConfigurationPath
$hostPath = Resolve-TaskFile $PowerShellPath
if ([IO.Path]::GetFileName($runner) -ine 'Run-ScanBridge.ps1') { throw 'RunnerPath must select Run-ScanBridge.ps1.' }
if ([IO.Path]::GetFileName($hostPath) -notin @('powershell.exe','pwsh.exe')) { throw 'PowerShellPath must select powershell.exe or pwsh.exe.' }
if ([IO.Path]::GetExtension($configuration) -ine '.psd1') { throw 'ConfigurationPath must select a PowerShell data file.' }
if ($TaskName -match '[\\/\r\n]' -or $TaskPath -match '["\r\n]') { throw 'Invalid task name or path.' }
if (-not $TaskPath.StartsWith('\')) { $TaskPath = '\' + $TaskPath }
if (-not $TaskPath.EndsWith('\')) { $TaskPath += '\' }
$isSystem = $RunAs -in @('SYSTEM','NT AUTHORITY\SYSTEM')
$needsCredential = -not $isSystem -and -not $RunAs.EndsWith('$')
if ($Credential -and $Credential.UserName -ine $RunAs) { throw 'Credential must belong to the selected RunAs account.' }
$arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -ConfigurationPath "{1}"' -f $runner,$configuration
if ($SkipAlerts) { $arguments += ' -SkipAlerts' }
$plan = [pscustomobject]@{
    Status = 'PlanOnly'; TaskName = $TaskName; TaskPath = $TaskPath
    ComputerName = [Environment]::MachineName; RunAs = $RunAs
    PowerShellPath = $hostPath; Arguments = $arguments
    WorkingDirectory = (Split-Path -Parent $runner)
    FirstRun = $FirstRun; EveryMinutes = $EveryMinutes
    TimeLimitMinutes = $TimeLimitMinutes; MultipleInstances = 'IgnoreNew'
    RunLevel = 'Limited'; StartWhenAvailable = $true
    CredentialRequired = $needsCredential
}
if (-not $Execute) { return $plan }
if (-not $PSCmdlet.ShouldProcess("$TaskPath$TaskName", "Register ScanBridge every $EveryMinutes minutes as $RunAs on this computer")) { return $plan }
if ($FirstRun -le (Get-Date)) { throw 'FirstRun must be in the future when registering the task.' }
if ($needsCredential -and -not $Credential) { throw 'Supply -Credential for the selected user account, or select an already provisioned gMSA or SYSTEM.' }

if ($SchedulingModulePath) { Import-Module $SchedulingModulePath -ErrorAction Stop }
else { Import-Module NSP.Win.ScheduledTask -ErrorAction Stop }
$existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
if ($existing -and -not $ReplaceExisting) { throw 'The task already exists. Review it before supplying -ReplaceExisting.' }
$trigger = New-ScheduledTaskTrigger -Once -At $FirstRun -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
$definitionArgs = @{
    TaskName = $TaskName; TaskPath = $TaskPath
    Description = 'Run one ScanBridge pass; exit 2 means held jobs or worker failure, exit 3 means alert failure.'
    Execute = $hostPath; Argument = $arguments; WorkingDirectory = $plan.WorkingDirectory
    RunAs = $RunAs; Trigger = $trigger; LimitedRunLevel = $true
    ExecutionTimeLimit = (New-TimeSpan -Minutes $TimeLimitMinutes)
    MultipleInstances = 'IgnoreNew'; StartWhenAvailable = $true
}
if ($Credential) { $definitionArgs.Credential = $Credential }
$definition = New-NSPScheduledTaskDefinition @definitionArgs
$null = Register-NSPScheduledTask -Definition $definition -Confirm:$false -ErrorAction Stop
$plan.Status = 'Registered'
$plan
