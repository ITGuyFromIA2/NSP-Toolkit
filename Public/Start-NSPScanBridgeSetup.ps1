function Start-NSPScanBridgeSetup {
    <#
    .SYNOPSIS
        ScanBridge setup/health menu, also launched by Start-NSPToolkit -Tool ScanBridge.
    .DESCRIPTION
        Reuses the existing ScanBridge settings PSD1. No tenant operation runs on entry.
        Local-account provisioning, dispatch alerting, diagnostics and scheduled registration are
        separate actions.
        The readiness watcher remains owned by ScanBridge and is offered when its API is present.
    #>
    [CmdletBinding()]
    param([string]$ConfigurationPath)
    Import-NSPToolkitModule -Name NSP.Console -MinimumVersion 0.1.2
    while($true) {
        Write-NSPConsoleHeader -Title 'ScanBridge setup and diagnostics' -Subtitle ([Environment]::MachineName)
        $choices=@(
            [pscustomobject]@{Label='Inspect helper availability';Value='Dependencies'}
            [pscustomobject]@{Label='Prepare a local service account';Value='Account'}
            [pscustomobject]@{Label='Inspect ScanBridge configuration health';Value='Health'}
            [pscustomobject]@{Label='Configure dispatch alerting';Value='Alerts';Help='Pick the sender mailbox in the client tenant, create a scoped alert app and write the Alerts settings. Plans first.'}
            [pscustomobject]@{Label='Watch readiness decisions (diagnostic only)';Value='Watch'}
            [pscustomobject]@{Label='Set up the Sysmon scan trigger';Value='Sysmon';Help='Sysmon watches the route Source folders for new PDFs so the task can start right after a scan. Plans first.'}
            [pscustomobject]@{Label='Plan the ScanBridge task';Value='TaskPlan';Help='Shows what would be registered: account, PowerShell, Sysmon and/or periodic triggers. Changes nothing.'}
            [pscustomobject]@{Label='Register the ScanBridge task';Value='TaskApply';Help='Registers the planned task; asks for the account password for Task Scheduler.'}
        )
        $choice=Read-NSPMenu -Choices $choices -Prompt 'Choose setup action' -CancelLabel 'Back'
        if($null -eq $choice) { return }
        try {
            if($choice -eq 'Dependencies') {
                foreach($name in 'NSP.ScanBridge','NSP.M365.Graph','Microsoft.Graph.Authentication','NSP.Win.LocalAccount','NSP.Win.ScheduledTask','NSP.Win.Sysmon','NSP.Win.RunAs') {
                    $module=Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending | Select-Object -First 1
                    [pscustomobject]@{Module=$name;InstalledVersion=if($module){[string]$module.Version}else{$null};InstalledPath=if($module){$module.Path}else{$null}}
                }
                Write-NSPConsoleLine 'Installed availability does not prove task-account discovery, supported ContextScope or certificate access.' -Role Warning
                continue
            }
            if($choice -eq 'Account') {
                Import-NSPToolkitModule -Name NSP.Win.LocalAccount -MinimumVersion 0.1.0
                Start-NSPLocalAccountManager
                continue
            }
            if(-not $ConfigurationPath) { $ConfigurationPath=Read-NSPScanBridgeConfigurationPath }
            if(-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) { throw 'Select an existing ScanBridge configuration file.' }
            $ConfigurationPath=(Get-Item -LiteralPath $ConfigurationPath).FullName
            if($choice -eq 'Alerts') { Invoke-NSPScanBridgeAlertSetup -ConfigurationPath $ConfigurationPath; continue }
            if($choice -eq 'Sysmon') { Invoke-NSPScanBridgeSysmonSetup -ConfigurationPath $ConfigurationPath | Out-Null; continue }
            Import-NSPToolkitModule -Name NSP.ScanBridge -MinimumVersion 0.1.0
            if($choice -eq 'Health') { Get-NSPScanBridgeHealth -ConfigurationPath $ConfigurationPath | Format-List; continue }
            if($choice -eq 'Watch') {
                $scanModule=Get-Module NSP.ScanBridge | Sort-Object Version -Descending | Select-Object -First 1
                $watch=$scanModule.ExportedCommands['Watch-NSPScanBridgeReadiness']
                if(-not $watch -or -not $watch.Parameters.ContainsKey('ConfigurationPath')) { throw 'This ScanBridge version does not export Watch-NSPScanBridgeReadiness -ConfigurationPath. Provision the reviewed diagnostic build first.' }
                & $watch -ConfigurationPath $ConfigurationPath
                continue
            }
            if($choice -in @('TaskPlan','TaskApply')) {
                Import-NSPToolkitModule -Name NSP.Win.ScheduledTask -MinimumVersion 0.1.0
                $scanModule=Get-Module NSP.ScanBridge | Sort-Object Version -Descending | Select-Object -First 1
                $runner=Join-Path $scanModule.ModuleBase 'scripts/Run-ScanBridge.ps1'
                $scheduling=Get-Module NSP.Win.ScheduledTask | Sort-Object Version -Descending | Select-Object -First 1
                $hostPath=Read-NSPScanBridgeTaskHost
                if($null -eq $hostPath) { continue }
                $runAs=Read-NSPScanBridgeRunAccount
                if($null -eq $runAs) { continue }
                $when=Read-NSPScanBridgeTriggerMode -ConfigurationPath $ConfigurationPath
                if($null -eq $when) { continue }
                $options=@{RunnerPath=$runner;ConfigurationPath=$ConfigurationPath;PowerShellPath=$hostPath;RunAs=$runAs;EveryMinutes=$when.Minutes;SchedulingModulePath=$scheduling.Path}
                if($when.Sysmon) { $options.SysmonTrigger=$true; $options.EventDelaySeconds=$when.DelaySeconds }
                $installer=Join-Path $script:ModuleRoot 'scripts/Install-ScanBridgeScheduledTask.ps1'
                if($choice -eq 'TaskApply' -and -not (Get-NSPDryRun)) {
                    Write-NSPConsoleLine 'Registration enables future runs. Validate dependencies, certificate/private-key and folder access under this account first. A Sysmon trigger needs ''Set up the Sysmon scan trigger'' first; this action does not configure Sysmon or parallel workers.' -Role Warning
                    if($runAs -notin @('SYSTEM','NT AUTHORITY\SYSTEM') -and -not $runAs.EndsWith('$')) { $options.Credential=Get-Credential -UserName $runAs -Message 'Task Scheduler stores this credential; toolkit answers do not.' }
                    try { & $installer @options -Execute -Confirm | Format-List }
                    finally { $options.Remove('Credential') }
                } else { & $installer @options | Format-List }
            }
        } catch { Write-NSPConsoleLine $_.Exception.Message -Role Error }
    }
}
