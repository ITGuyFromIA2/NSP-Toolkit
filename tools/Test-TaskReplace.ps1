[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','',Justification='State is read by the shadowed commands.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess','',Justification='Shadowed commands mirror the real signatures and record calls instead of changing anything.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Synthetic credential; never reaches a real scheduler.')]
[CmdletBinding()]
param([string]$SourceRoot)
$ErrorActionPreference='Stop'
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
foreach($file in 'ScanBridgeSettingsSetup.ps1','ScanBridgeTaskReplace.ps1') { . (Join-Path $SourceRoot "Private/$file") }
$state=@{Checks=0}
function Check($condition,$message) {if(-not $condition){throw $message};$state.Checks++}
$realElevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$realAcl=${function:Set-NSPScanBridgePrivateAcl}
$password=ConvertTo-SecureString 'synthetic' -AsPlainText -Force
# Load the real module first: autoloading it later would replace the stubs below, and the real
# commands would run. The task name below does not exist, as a second guard.
Import-Module ScheduledTasks -ErrorAction Stop
$syntheticName='NSP-Contract-NoSuchTask'; $syntheticPath='\NSP-Contract\'
function Test-NSPScanBridgeElevated { $state.Elevated }
function Write-NSPConsoleLine { param($Text,$Role) $state.Lines+=,$Text; if($Role -eq 'Error'){$state.Errors+=,$Text}; if($Role -eq 'Warning'){$state.Warnings+=,$Text} }
function Read-NSPConfirm { param($Prompt) $state.Log+=,'Confirm'; $state.Confirm }
function Get-Credential { param($UserName,$Message) $state.Log+=,'Credential'; if($state.CredentialFails){throw 'Cancelled'}; New-Object pscredential($UserName,$password) }
function Export-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) $state.Log+=,'Export'; if($state.ExportFails){throw 'Export failed'}; $state.Xml }
function Disable-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) $state.Log+=,'Disable'; if($state.DisableFails){throw 'Access is denied'} }
$installer={
    [CmdletBinding(SupportsShouldProcess)] param($RunAs,[pscredential]$Credential,[switch]$Execute,[switch]$ReplaceExisting)
    $state.Log+=,'Install'; $state.Replace=[bool]$ReplaceExisting; $state.Given=$Credential
    if($state.InstallFails){throw 'Register failed'}
    [pscustomobject]@{Status='Registered'}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('nsp-toolkit-taskreplace-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$runner010=Join-Path $root 'NSP.ScanBridge\0.1.0\scripts\Run-ScanBridge.ps1'
$runner011=Join-Path $root 'NSP.ScanBridge\0.1.1\scripts\Run-ScanBridge.ps1'
New-Item -ItemType Directory -Path (Split-Path -Parent $runner011) -Force | Out-Null
[IO.File]::WriteAllText($runner011,'# runner')
$settings=Join-Path $root 'ScanBridge.psd1'
$pwsh='C:\Program Files\PowerShell\7\pwsh.exe'
$subscription="<QueryList><Query Id=`"0`" Path=`"Sysmon`"><Select Path=`"Sysmon`">*[EventData[Data[@Name='RuleName']='NSP ScanBridge']]</Select></Query></QueryList>"
function New-SyntheticPlan {
    param([string]$Runner=$runner011,[string]$RunAs='PC\ScanBridge',[int]$Minutes=15)
    [pscustomobject]@{TaskName=$syntheticName;TaskPath=$syntheticPath;RunAs=$RunAs;PowerShellPath=$pwsh;Arguments=('-NoLogo -File "{0}" -ConfigurationPath "{1}"' -f $Runner,$settings);EveryMinutes=$Minutes;EventSubscription=$subscription;EventDelaySeconds=50;MultipleInstances='Queue'}
}
function New-SyntheticTask {
    # Real scheduler objects where they can be built offline; only the event trigger is a stand-in.
    param([string]$Runner=$runner010,[string]$State='Disabled',[string]$User='ScanBridge',[string]$Interval='PT15M')
    $action=New-ScheduledTaskAction -Execute $pwsh -Argument ('-NoLogo -File "{0}" -ConfigurationPath "{1}"' -f $Runner,$settings)
    $time=New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1) -RepetitionInterval ([Xml.XmlConvert]::ToTimeSpan($Interval))
    $sysmon=[pscustomobject]@{Subscription=$subscription;Delay='PT50S'}
    [pscustomobject]@{TaskName=$syntheticName;TaskPath=$syntheticPath;State=$State;Actions=@($action);Triggers=@($sysmon,$time);Principal=(New-ScheduledTaskPrincipal -UserId $User -LogonType Password);Settings=(New-ScheduledTaskSettingsSet -MultipleInstances Queue)}
}
function Reset-Flow {
    $state.Lines=@(); $state.Errors=@(); $state.Warnings=@(); $state.Log=@(); $state.Elevated=$true; $state.Confirm=$true
    $state.Xml='<Task/>'; $state.ExportFails=$false; $state.DisableFails=$false; $state.InstallFails=$false; $state.CredentialFails=$false
    $state.Replace=$false; $state.Given=$null
    Get-ChildItem -LiteralPath $root -Filter '*.task.xml' -File | Remove-Item -Force
}
function Invoke-Flow {
    param($Comparison,[hashtable]$Options=@{RunAs='PC\ScanBridge'})
    Invoke-NSPScanBridgeTaskRegistration -Installer $installer -Options $Options -Plan (New-SyntheticPlan) -Comparison $Comparison -ConfigurationPath $settings
}
function Get-Row { param($Comparison,$Field) @($Comparison.Rows | Where-Object { $_.Field -eq $Field })[0] }
function Get-ExportCount { @(Get-ChildItem -LiteralPath $root -Filter '*.task.xml' -File).Count }
try {
    foreach($name in 'Export-ScheduledTask','Disable-ScheduledTask') { Check (-not (Get-Command $name).Source) "$name is the real command, not the stub." }

    # What the review shows.
    $upgrade=Get-NSPScanBridgeTaskComparison -Task (New-SyntheticTask) -Plan (New-SyntheticPlan)
    Check ((Get-Row $upgrade 'ScanBridge version').Current -eq '0.1.0' -and (Get-Row $upgrade 'ScanBridge version').Planned -eq '0.1.1') 'The runner versions were not read from the paths.'
    Check ((Get-Row $upgrade 'ScanBridge version').Changed -and (Get-Row $upgrade 'Arguments').Changed) 'An upgrade did not show as a change.'
    Check ($upgrade.RunnerMissing) 'A removed runner was not flagged.'
    Check ($upgrade.Disabled -and -not $upgrade.Busy) 'The task state was misread.'
    Check (-not (Get-Row $upgrade 'Account').Changed) 'COMPUTER\name and name were not the same account.'
    Check (-not (Get-Row $upgrade 'PowerShell').Changed -and -not (Get-Row $upgrade 'Overlapping runs').Changed) 'An unchanged setting showed as a change.'
    Check ((Get-Row $upgrade 'Triggers').Current -eq "Every 15 minutes; Sysmon file create 'NSP ScanBridge', 50 s later") 'Registered triggers were misread.'
    Check (-not (Get-Row $upgrade 'Triggers').Changed) 'Identical triggers showed as a change.'
    $hourly=Get-NSPScanBridgeTaskComparison -Task (New-SyntheticTask -Interval 'PT1H') -Plan (New-SyntheticPlan)
    Check ((Get-Row $hourly 'Triggers').Current -like 'Every 60 minutes*' -and (Get-Row $hourly 'Triggers').Changed) 'An hourly interval was misread.'
    $other=Get-NSPScanBridgeTaskComparison -Task (New-SyntheticTask -User 'OtherAccount') -Plan (New-SyntheticPlan)
    Check ((Get-Row $other 'Account').Changed) 'A different account did not show as a change.'
    $same=Get-NSPScanBridgeTaskComparison -Task (New-SyntheticTask -Runner $runner011) -Plan (New-SyntheticPlan)
    Check (-not @($same.Rows | Where-Object Changed).Count -and -not $same.RunnerMissing) 'An identical task showed a difference.'
    Reset-Flow
    Show-NSPScanBridgeTaskComparison -Comparison $upgrade
    Check (@($state.Lines) -match '\[change\]: 0\.1\.0 -> 0\.1\.1') 'The version change was not shown.'
    Check (@($state.Warnings) -match 'no longer exists') 'A removed runner was not warned about.'
    Check (@($state.Lines) -match 'stays Disabled') 'The review did not say the task stays Disabled.'
    foreach($busy in 'Running','Queued') { Check (Get-NSPScanBridgeTaskComparison -Task (New-SyntheticTask -State $busy) -Plan (New-SyntheticPlan)).Busy "$busy was not treated as busy." }

    ${function:Set-NSPScanBridgePrivateAcl}={ param($Path) $state.Log+=,'Restrict' }

    # No existing task: the original path, with no export and no replace.
    Reset-Flow; $options=@{RunAs='PC\ScanBridge'}
    Invoke-Flow -Comparison $null -Options $options | Out-Null
    Check (($state.Log -join ',') -eq 'Credential,Install' -and -not $state.Replace) 'A first registration did not take the original path.'
    Check (-not $options.ContainsKey('Credential')) 'The credential stayed in the options.'

    # A Disabled task: confirm, then export, then replace, then disable.
    Reset-Flow; $options=@{RunAs='PC\ScanBridge'}
    Invoke-Flow -Comparison $upgrade -Options $options | Out-Null
    Check (($state.Log -join ',') -eq 'Confirm,Credential,Export,Restrict,Install,Disable') "Replace order was wrong: $($state.Log -join ',')"
    Check ($state.Replace -and $state.Given) 'The replace did not reach the installer with its credential.'
    Check (-not $options.ContainsKey('Credential')) 'The replace left the credential in the options.'
    Check ((Get-ExportCount) -eq 1) 'The old definition was not saved.'
    Check (@($state.Lines) -match 'stays Disabled') 'The replace did not report the task staying Disabled.'

    # An enabled task is not disabled.
    Reset-Flow
    Invoke-Flow -Comparison (Get-NSPScanBridgeTaskComparison -Task (New-SyntheticTask -State 'Ready') -Plan (New-SyntheticPlan)) | Out-Null
    Check (($state.Log -join ',') -notmatch 'Disable' -and $state.Replace) 'A Ready task was disabled.'

    # Each refusal leaves the task alone.
    Reset-Flow
    Invoke-Flow -Comparison (Get-NSPScanBridgeTaskComparison -Task (New-SyntheticTask -State 'Running') -Plan (New-SyntheticPlan)) | Out-Null
    Check ($state.Log.Count -eq 0 -and @($state.Errors) -match 'pass has finished') 'A running task was not refused first.'
    Reset-Flow; $state.Elevated=$false
    Invoke-Flow -Comparison $upgrade | Out-Null
    Check ($state.Log.Count -eq 0 -and @($state.Errors) -match 'elevated') 'An unelevated replace was not refused first.'
    Reset-Flow; $state.Confirm=$false
    Invoke-Flow -Comparison $upgrade | Out-Null
    Check (($state.Log -join ',') -eq 'Confirm' -and -not (Get-ExportCount)) 'Declining changed something.'

    # Cancelling the password leaves no export behind.
    Reset-Flow; $state.CredentialFails=$true
    $threw=$false; try { Invoke-Flow -Comparison $upgrade | Out-Null } catch { $threw=$true }
    Check ($threw -and $state.Log -notcontains 'Export' -and $state.Log -notcontains 'Install') 'A cancelled password still exported or replaced.'

    # No export, no replace.
    Reset-Flow; $state.ExportFails=$true
    $threw=$false; try { Invoke-Flow -Comparison $upgrade | Out-Null } catch { $threw=$true }
    Check ($threw -and $state.Log -notcontains 'Install') 'A failed export still replaced the task.'
    Reset-Flow; $state.Xml=$null
    $threw=$false; try { Invoke-Flow -Comparison $upgrade | Out-Null } catch { $threw=$true }
    Check ($threw -and $state.Log -notcontains 'Install' -and -not (Get-ExportCount)) 'An empty export still replaced the task.'
    Reset-Flow
    ${function:Set-NSPScanBridgePrivateAcl}={ param($Path) throw 'Access is denied' }
    $threw=$false; try { Invoke-Flow -Comparison $upgrade | Out-Null } catch { $threw=$true }
    Check ($threw -and $state.Log -notcontains 'Install' -and -not (Get-ExportCount)) 'An export that could not be restricted was kept or replaced the task.'
    ${function:Set-NSPScanBridgePrivateAcl}={ param($Path) $state.Log+=,'Restrict' }

    # A failed replace keeps the export and does not touch the old task's state.
    Reset-Flow; $state.InstallFails=$true; $options=@{RunAs='PC\ScanBridge'}
    $threw=$false; try { Invoke-Flow -Comparison $upgrade -Options $options | Out-Null } catch { $threw=$true }
    Check ($threw -and (Get-ExportCount) -eq 1 -and $state.Log -notcontains 'Disable') 'A failed replace lost the export or disabled something.'
    Check (-not $options.ContainsKey('Credential')) 'A failed replace left the credential in the options.'

    # A replaced task that cannot be disabled says so loudly.
    Reset-Flow; $state.DisableFails=$true
    $message=$null; try { Invoke-Flow -Comparison $upgrade | Out-Null } catch { $message=$_.Exception.Message }
    Check ($message -match 'is ENABLED') 'A task left enabled was not reported.'

    # Real export file: restricted, and in UTF-16 as its XML declares.
    ${function:Set-NSPScanBridgePrivateAcl}=$realAcl
    if($realElevated) {
        Reset-Flow; $state.Xml='<?xml version="1.0" encoding="UTF-16"?><Task/>'
        $path=Export-NSPScanBridgeTaskDefinition -TaskName $syntheticName -TaskPath $syntheticPath -ConfigurationPath $settings
        $acl=Get-Acl -LiteralPath $path
        $sids=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        Check ($acl.AreAccessRulesProtected -and (($sids -join ',') -eq 'S-1-5-18,S-1-5-32-544')) 'The export is not Administrators and SYSTEM only.'
        Check (([xml][IO.File]::ReadAllText($path)).DocumentElement.Name -eq 'Task') 'The export does not read back as XML.'
    } else { Write-Host 'Task replace: real ACL checks skipped (not elevated).' -ForegroundColor Yellow }
    Write-Host ("Task replace contract passed: {0} checks." -f $state.Checks) -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
