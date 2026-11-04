# Replacing an existing ScanBridge task after an upgrade: the old task is shown against the plan,
# confirmed, exported, then replaced. Replacing never changes whether the task runs: a Disabled
# task stays Disabled. A task in the middle of a pass is left alone.

function Get-NSPScanBridgeExistingTask {
    param([Parameter(Mandatory)][string]$TaskName,[Parameter(Mandatory)][string]$TaskPath)
    Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
}

function ConvertTo-NSPScanBridgeEventTriggerText {
    param([string]$Subscription,[int]$DelaySeconds)
    $name=if($Subscription -match "@Name='RuleName'\]='(?<rule>[^']+)'"){"Sysmon file create '$($Matches.rule)'"}else{'Event'}
    '{0}, {1} s later' -f $name,$DelaySeconds
}

function Get-NSPScanBridgeTaskTriggerText {
    # One comparable line per trigger on a registered task, in the plan's order.
    param([object[]]$Trigger)
    $lines=foreach($item in @($Trigger)) {
        if(-not $item) { continue }
        if($item.Subscription) {
            $delay=if($item.Delay){[int][Xml.XmlConvert]::ToTimeSpan([string]$item.Delay).TotalSeconds}else{0}
            '2|'+(ConvertTo-NSPScanBridgeEventTriggerText -Subscription $item.Subscription -DelaySeconds $delay)
        } elseif($item.Repetition -and $item.Repetition.Interval) {
            '1|Every {0} minutes' -f [int][Xml.XmlConvert]::ToTimeSpan([string]$item.Repetition.Interval).TotalMinutes
        } else { '3|Other trigger' }
    }
    @($lines | Sort-Object | ForEach-Object { $_.Substring(2) })
}

function Get-NSPScanBridgeRunnerVersion {
    param([string]$RunnerPath)
    if($RunnerPath -match '\\NSP\.ScanBridge\\(?<version>\d+(\.\d+)+)\\') { $Matches.version } else { 'unversioned path' }
}

function Get-NSPScanBridgeTaskComparison {
    <#
        The registered task against a plan from Install-ScanBridgeScheduledTask.ps1. Rows carry
        Field, Current, Planned and Changed. Paths compare without case; accounts by name, so
        COMPUTER\name and .\name are the same account.
    #>
    param([Parameter(Mandatory)]$Task,[Parameter(Mandatory)]$Plan)
    $action=@($Task.Actions)[0]
    $arguments=[string]$action.Arguments
    $runnerPath=if($arguments -match '-File "(?<path>[^"]+)"'){$Matches.path}else{$null}
    $plannedRunner=if($Plan.Arguments -match '-File "(?<path>[^"]+)"'){$Matches.path}else{$null}
    $planTriggers=@("Every $($Plan.EveryMinutes) minutes")
    if($Plan.EventSubscription) { $planTriggers+=ConvertTo-NSPScanBridgeEventTriggerText -Subscription $Plan.EventSubscription -DelaySeconds $Plan.EventDelaySeconds }
    $leaf={ param($Name) ([string]$Name -split '\\')[-1] }
    $row={ param($Field,$Current,$Planned) [pscustomobject]@{Field=$Field;Current=[string]$Current;Planned=[string]$Planned;Changed=([string]$Current -ine [string]$Planned)} }
    $state=[string]$Task.State
    [pscustomobject]@{
        TaskPath=[string]$Task.TaskPath
        TaskName=[string]$Task.TaskName
        State=$state
        Busy=$state -in @('Running','Queued')
        Disabled=$state -eq 'Disabled'
        RunnerPath=$runnerPath
        RunnerMissing=[bool]$runnerPath -and -not (Test-Path -LiteralPath $runnerPath -PathType Leaf)
        Rows=@(
            & $row 'PowerShell' $action.Execute $Plan.PowerShellPath
            & $row 'ScanBridge version' $(if($runnerPath){Get-NSPScanBridgeRunnerVersion $runnerPath}else{'not found in the arguments'}) (Get-NSPScanBridgeRunnerVersion $plannedRunner)
            & $row 'Arguments' $arguments $Plan.Arguments
            & $row 'Account' (& $leaf $Task.Principal.UserId) (& $leaf $Plan.RunAs)
            & $row 'Triggers' ((Get-NSPScanBridgeTaskTriggerText -Trigger $Task.Triggers) -join '; ') ($planTriggers -join '; ')
            & $row 'Overlapping runs' $Task.Settings.MultipleInstances $Plan.MultipleInstances
        )
    }
}

function Show-NSPScanBridgeTaskComparison {
    param([Parameter(Mandatory)]$Comparison)
    Write-NSPConsoleLine ('Existing task {0}{1} ({2}), against this plan:' -f $Comparison.TaskPath,$Comparison.TaskName,$Comparison.State)
    foreach($item in $Comparison.Rows) {
        if($item.Changed) { Write-NSPConsoleLine ('  - {0} [change]: {1} -> {2}' -f $item.Field,$item.Current,$item.Planned) }
        else { Write-NSPConsoleLine ('  - {0}: same ({1})' -f $item.Field,$item.Current) }
    }
    if($Comparison.RunnerMissing) { Write-NSPConsoleLine "The existing task's runner no longer exists, so it cannot start until it is replaced: $($Comparison.RunnerPath)" -Role Warning }
    if($Comparison.Disabled) { Write-NSPConsoleLine 'The task is Disabled and stays Disabled after a replace.' -Role Muted }
}

function Export-NSPScanBridgeTaskDefinition {
    <#
        Saves the old definition beside the settings file, Administrators and SYSTEM only, and
        returns its path. The XML holds no password; restoring it asks for the account's password.
        A failure leaves no file and stops the replace.
    #>
    param([Parameter(Mandatory)][string]$TaskName,[Parameter(Mandatory)][string]$TaskPath,[Parameter(Mandatory)][string]$ConfigurationPath)
    $xml=Export-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
    if(-not $xml) { throw 'The existing task could not be exported, so it was not replaced.' }
    $stamp=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $path=Join-Path (Split-Path -Parent $ConfigurationPath) ("$TaskName.$stamp.task.xml")
    [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None).Dispose()
    try {
        Set-NSPScanBridgePrivateAcl -Path $path
        [IO.File]::WriteAllText($path,[string]$xml,[Text.Encoding]::Unicode)
    } catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw
    }
    $path
}

function Invoke-NSPScanBridgeTaskRegistration {
    <#
        Registers the planned task. With an existing task ($Comparison): refuses one in the middle
        of a pass, confirms, exports the old definition, replaces, then restores Disabled. Nothing
        is replaced unless the export succeeded.
    #>
    param(
        [Parameter(Mandatory)]$Installer,
        [Parameter(Mandatory)][hashtable]$Options,
        [Parameter(Mandatory)]$Plan,
        $Comparison,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )
    if($Comparison) {
        if($Comparison.Busy) { Write-NSPConsoleLine "The task is $($Comparison.State). It was not replaced; try again when the pass has finished." -Role Error; return }
        if(-not (Test-NSPScanBridgeElevated)) { Write-NSPConsoleLine 'Replacing the task needs an elevated session. Restart PowerShell as administrator.' -Role Error; return }
        if(-not (Read-NSPConfirm -Prompt 'Replace this task? The old definition is exported first.')) { return }
    }
    Write-NSPConsoleLine 'Registration enables future runs. Validate dependencies, certificate/private-key and folder access under this account first. A Sysmon trigger needs ''Set up the Sysmon scan trigger'' first; this action does not configure Sysmon or parallel workers.' -Role Warning
    $runAs=[string]$Options.RunAs
    if($runAs -notin @('SYSTEM','NT AUTHORITY\SYSTEM') -and -not $runAs.EndsWith('$')) { $Options.Credential=Get-Credential -UserName $runAs -Message 'Task Scheduler stores this credential; toolkit answers do not.' }
    try {
        if(-not $Comparison) { & $Installer @Options -Execute -Confirm | Format-List; return }
        $export=Export-NSPScanBridgeTaskDefinition -TaskName $Plan.TaskName -TaskPath $Plan.TaskPath -ConfigurationPath $ConfigurationPath
        Write-NSPConsoleLine "Old task definition saved: $export" -Role Muted
        & $Installer @Options -Execute -ReplaceExisting -Confirm:$false | Format-List
    } finally { $Options.Remove('Credential') }
    if($Comparison.Disabled) {
        try { $null=Disable-ScheduledTask -TaskName $Plan.TaskName -TaskPath $Plan.TaskPath -ErrorAction Stop }
        catch { throw "The task was replaced and is ENABLED, because it could not be disabled again: $($_.Exception.Message)" }
        Write-NSPConsoleLine 'The task was replaced and stays Disabled, as it was.' -Role Success
    }
}
