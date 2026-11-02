[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','',Justification='State is read by the shadowed commands.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess','',Justification='Shadowed commands mirror the real signatures and record calls instead of changing anything.')]
[CmdletBinding()]
param([string]$SourceRoot)
$ErrorActionPreference='Stop'
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
foreach($file in 'ScanBridgeAlertSetup.ps1','ScanBridgeSetupPrompts.ps1','ScanBridgeSysmonSetup.ps1') { . (Join-Path $SourceRoot "Private/$file") }
$state=@{Checks=0}
function Check($condition,$message) {if(-not $condition){throw $message};$state.Checks++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('nsp-toolkit-sysmon-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function New-Settings([string]$Routes) {
    $path=Join-Path $root ('settings-'+[guid]::NewGuid().ToString('N')+'.psd1')
    [IO.File]::WriteAllText($path,"@{ LockPath = 'C:\x\worker.lock'; Routes = @($Routes) }")
    $path
}
try {
    # Watch plan: sources, delay and self-trigger refusal.
    $settings=New-Settings "@{ Name='A'; Source='C:\Scans\A\'; Spool='C:\Spool\A'; Archive='C:\Archive\A'; MinimumAgeSeconds=20 }, @{ Name='B'; Source='C:\Scans\B'; Spool='C:\Spool\B'; Archive='C:\Archive\B'; MinimumAgeSeconds=45 }"
    $plan=Get-NSPScanBridgeWatchPlan -ConfigurationPath $settings
    Check ($plan.Sources -join '|' -eq 'C:\Scans\A|C:\Scans\B' -and $plan.MaximumAgeSeconds -eq 45 -and $plan.EventDelaySeconds -eq 75 -and $plan.RuleName -eq 'NSP ScanBridge') 'Watch plan sources or delay were wrong.'
    Check ((Get-NSPScanBridgeWatchPlan -ConfigurationPath (New-Settings "@{ Name='A'; Source='C:\Scans\A'; Spool='C:\Spool\A'; Archive='C:\Archive\A' }")).EventDelaySeconds -eq 50) 'Default route age was not 20 seconds.'
    foreach($bad in "@{ Name='A'; Source='C:\Scans\A'; Spool='C:\Scans\A\spool'; Archive='C:\Archive\A' }","@{ Name='A'; Source='C:\Scans\A'; Spool='C:\Spool\A'; Archive='C:\Scans\A' }","@{ Name='A'; Source='<drop-folder>'; Spool='C:\Spool\A'; Archive='C:\Archive\A' }") {
        $threw=$false; try { Get-NSPScanBridgeWatchPlan -ConfigurationPath (New-Settings $bad) | Out-Null } catch { $threw=$true }
        Check $threw "A self-triggering or missing Source was accepted: $bad"
    }
    Check ((Get-NSPScanBridgeWatchPlan -ConfigurationPath (New-Settings "@{ Name='A'; Source='C:\Scans\A'; Spool='C:\Scans\AB'; Archive='C:\Archive\A' }")).Sources -eq 'C:\Scans\A') 'A sibling folder with a shared prefix was treated as inside the Source.'

    # Setup flow with Sysmon, console and elevation shadowed.
    function Import-NSPToolkitModule { param($Name,$MinimumVersion) }
    function New-NSPSysmonFileWatchConfig { param([string[]]$Path,[string[]]$IncludeExtension,[string]$RuleName,[switch]$RuleGroupOnly) $state.Built+=,[pscustomobject]@{Path=$Path;Ext=$IncludeExtension;RuleName=$RuleName;Group=[bool]$RuleGroupOnly}; if($RuleGroupOnly){"<RuleGroup><Rule name=`"$RuleName`" /></RuleGroup>"}else{"<Sysmon rule=`"$RuleName`" />"} }
    function Save-NSPSysmon { [CmdletBinding(SupportsShouldProcess)] param($Destination) $state.Saves++; [pscustomobject]@{Path='C:\ProgramData\NSP\Sysmon\Sysmon64.exe';Version='15.0';Signer='O=Microsoft Corporation'} }
    function Find-NSPSysmon { param($Path) $state.Found }
    function Get-NSPSysmonStatus { $state.Status }
    function Test-NSPSysmonConfig { param($ConfigPath,$Configuration) [pscustomobject]@{InSync=$state.InSync;Problems=@('different')} }
    function Install-NSPSysmon { [CmdletBinding(SupportsShouldProcess)] param($SysmonPath,$ConfigPath,$Configuration,[switch]$Force) $state.Installs+=,[pscustomobject]@{SysmonPath=$SysmonPath;ConfigPath=$ConfigPath;Force=[bool]$Force}; $state.InSync=$true }
    function Get-NSPDryRun { $state.DryRun }
    function Test-NSPScanBridgeElevated { $state.Elevated }
    function Write-NSPConsoleLine { param($Text,$Role) if($Role -eq 'Error'){$state.Errors+=,$Text} }
    function Read-NSPConfirm { param($Prompt,[switch]$DefaultYes) $state.Confirms+=,$Prompt; $true }
    function Read-NSPNonEmpty { param($Prompt,$CurrentValue) 'D:\Tools' }
    function Read-NSPMenu {
        param($Choices,$Prompt,$CancelLabel)
        $state.Menus+=,[pscustomobject]@{Prompt=$Prompt;Values=@($Choices | ForEach-Object Value)}
        $next=$state.Menu[0]; $state.Menu=@($state.Menu | Select-Object -Skip 1); $next
    }
    function Reset-Flow {
        param([switch]$DryRun)
        $state.Settings=New-Settings "@{ Name='A'; Source='$root\scans'; Spool='$root\spool'; Archive='$root\archive'; MinimumAgeSeconds=20 }"
        $state.DryRun=[bool]$DryRun; $state.Elevated=$true; $state.Found=$null; $state.InSync=$false; $state.Saves=0
        $state.Status=[pscustomobject]@{Installed=$false;ConfigFile=$null;Version=$null}
        $state.Built=@(); $state.Installs=@(); $state.Errors=@(); $state.Confirms=@(); $state.Menus=@(); $state.Menu=@()
    }
    $ownConfig={ Join-Path (Split-Path -Parent $state.Settings) 'Sysmon.xml' }

    Reset-Flow; $state.Menu=@('Download')
    $mode=Invoke-NSPScanBridgeSysmonSetup -ConfigurationPath $state.Settings
    Check ($mode -eq 'Own' -and $state.Saves -eq 1 -and $state.Installs.Count -eq 1 -and $state.Installs[0].SysmonPath -eq 'C:\ProgramData\NSP\Sysmon\Sysmon64.exe' -and -not $state.Installs[0].Force) 'Missing Sysmon was not downloaded, then installed.'
    Check ($state.Installs[0].ConfigPath -eq (& $ownConfig) -and $state.Built[0].RuleName -eq 'NSP ScanBridge' -and $state.Built[0].Ext -eq '.pdf' -and $state.Built[0].Path -eq "$root\scans") 'Configuration was not the named PDF watch beside the settings.'

    Reset-Flow -DryRun; $state.Menu=@('Download')
    $mode=Invoke-NSPScanBridgeSysmonSetup -ConfigurationPath $state.Settings
    Check ($null -eq $mode -and $state.Saves -eq 0 -and $state.Installs.Count -eq 0) 'DRY RUN downloaded or installed Sysmon.'

    Reset-Flow; $state.Menu=@('Folder'); $state.Found=$null
    Invoke-NSPScanBridgeSysmonSetup -ConfigurationPath $state.Settings | Out-Null
    Check ($state.Errors.Count -eq 1 -and $state.Installs.Count -eq 0) 'A folder without Sysmon was not refused.'

    Reset-Flow; $state.Status=[pscustomobject]@{Installed=$true;ConfigFile='C:\Monitoring\corp.xml';Version='15.0'}; $state.Menu=@('Keep')
    $mode=Invoke-NSPScanBridgeSysmonSetup -ConfigurationPath $state.Settings
    $fragment=Join-Path (Split-Path -Parent $state.Settings) 'ScanBridge-Sysmon-RuleGroup.xml'
    Check ($mode -eq 'Merge' -and $state.Installs.Count -eq 0 -and (Test-Path -LiteralPath $fragment) -and [IO.File]::ReadAllText($fragment) -match 'name="NSP ScanBridge"') 'Keep did not leave Sysmon alone and save the named rule group.'
    Check ($state.Menus[0].Values[0] -eq 'Keep') 'Keep was not the first (default) choice for another configuration.'

    Reset-Flow; $state.Status=[pscustomobject]@{Installed=$true;ConfigFile='C:\Old\Sysmon.xml';Version='15.0'}; $state.Menu=@('Replace')
    $mode=Invoke-NSPScanBridgeSysmonSetup -ConfigurationPath $state.Settings
    Check ($mode -eq 'Own' -and $state.Installs.Count -eq 1 -and $state.Installs[0].Force -and $state.Confirms[-1] -match 'Replace C:\\Old\\Sysmon.xml') 'Replace did not confirm and force the new configuration.'

    Reset-Flow; $state.Status=[pscustomobject]@{Installed=$true;ConfigFile=(& $ownConfig);Version='15.0'}; $state.InSync=$true
    $mode=Invoke-NSPScanBridgeSysmonSetup -ConfigurationPath $state.Settings
    Check ($mode -eq 'Own' -and $state.Installs.Count -eq 0 -and $state.Confirms.Count -eq 0) 'An in-sync ScanBridge configuration was re-applied.'

    Reset-Flow; $state.Elevated=$false
    Invoke-NSPScanBridgeSysmonSetup -ConfigurationPath $state.Settings | Out-Null
    Check ($state.Errors.Count -eq 1 -and $state.Installs.Count -eq 0 -and $state.Menus.Count -eq 0) 'A non-elevated session was not stopped before changing Sysmon.'

    # Trigger choice for the task.
    function Get-Service { param($Name,$ErrorAction) if($state.ServicePresent){[pscustomobject]@{Name='Sysmon64';Status='Running'}} }
    function Get-NSPToolAnswers { param($Tool) $null }
    function Save-NSPToolAnswers { [CmdletBinding(SupportsShouldProcess)] param($Tool,$Answers) }
    Reset-Flow; $state.ServicePresent=$true; $state.Menu=@('Sysmon')
    $when=Read-NSPScanBridgeTriggerMode -ConfigurationPath $state.Settings
    Check ($when.Sysmon -and $when.Minutes -eq 15 -and $when.DelaySeconds -eq 50) 'Sysmon trigger mode did not give a 15-minute sweep and route age + 30 s.'
    Reset-Flow; $state.ServicePresent=$false; $state.Menu=@('Periodic',10)
    $when=Read-NSPScanBridgeTriggerMode -ConfigurationPath $state.Settings
    Check (-not $when.Sysmon -and $when.Minutes -eq 10 -and $state.Menus[0].Values -notcontains 'Sysmon') 'Without Sysmon only the periodic choice should be offered.'

    # Installer: plan and registration with the Sysmon trigger, scheduling shadowed.
    $runner=Join-Path $root 'Run-ScanBridge.ps1'; [IO.File]::WriteAllText($runner,'# runner')
    $hostExe=(Get-Command powershell.exe).Source
    $installer=Join-Path $SourceRoot 'scripts/Install-ScanBridgeScheduledTask.ps1'
    $base=@{RunnerPath=$runner;ConfigurationPath=$state.Settings;PowerShellPath=$hostExe;RunAs='SYSTEM';EveryMinutes=15}
    $periodic=& $installer @base
    Check ($periodic.MultipleInstances -eq 'IgnoreNew' -and @($periodic.Triggers).Count -eq 1 -and $null -eq $periodic.EventSubscription) 'Periodic-only plan changed.'
    $eventPlan=& $installer @base -SysmonTrigger -EventDelaySeconds 50
    Check ($eventPlan.MultipleInstances -eq 'Queue' -and @($eventPlan.Triggers).Count -eq 2 -and $eventPlan.EventDelaySeconds -eq 50) 'Sysmon plan did not queue runs with two triggers.'
    $query=([xml]$eventPlan.EventSubscription).QueryList.Query.Select
    Check ($query.Path -eq 'Microsoft-Windows-Sysmon/Operational' -and $query.'#text' -eq "*[System[(EventID=11)]] and *[EventData[Data[@Name='RuleName']='NSP ScanBridge']]") 'Event subscription does not select only named Sysmon file creates.'
    function Import-Module { param($Name,$ErrorAction) }
    function Get-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) }
    function New-ScheduledTaskTrigger { param([switch]$Once,$At,$RepetitionInterval) [pscustomobject]@{Kind='Time';Every=$RepetitionInterval} }
    function New-NSPEventTaskTrigger { param($Subscription,$Delay) [pscustomobject]@{Kind='Event';Subscription=$Subscription;Delay=$Delay} }
    function New-NSPScheduledTaskDefinition { param($TaskName,$TaskPath,$Description,$Execute,$Argument,$WorkingDirectory,$RunAs,$Trigger,[switch]$LimitedRunLevel,$ExecutionTimeLimit,$MultipleInstances,[switch]$StartWhenAvailable,[pscredential]$Credential) $state.Definition=@{Trigger=@($Trigger);MultipleInstances=$MultipleInstances;Arguments=$Argument}; 'definition' }
    function Register-NSPScheduledTask { [CmdletBinding(SupportsShouldProcess)] param($Definition) $state.Registered++ }
    $state.Registered=0
    $registered=& $installer @base -SysmonTrigger -EventDelaySeconds 50 -Execute -Confirm:$false
    $kinds=@($state.Definition.Trigger | ForEach-Object Kind)
    Check ($registered.Status -eq 'Registered' -and $state.Registered -eq 1 -and ($kinds -join ',') -eq 'Time,Event' -and $state.Definition.MultipleInstances -eq 'Queue') 'Registration did not add the event trigger beside the sweep with queued runs.'
    Check ($state.Definition.Trigger[1].Delay -eq (New-TimeSpan -Seconds 50) -and $state.Definition.Trigger[1].Subscription -eq $eventPlan.EventSubscription -and $state.Definition.Arguments -notmatch 'TargetFilename') 'Event trigger delay or subscription was wrong, or the filename reached the command line.'

    Microsoft.PowerShell.Utility\Write-Host ('Passed: {0} Sysmon setup and task trigger checks in {1}; Sysmon, scheduler and console mocked.' -f $state.Checks,$PSVersionTable.PSVersion)
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
