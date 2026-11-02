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
    # 0.1.5: Read-NSPFolderPath (route Source picker).
    Import-NSPToolkitModule -Name NSP.Console -MinimumVersion 0.1.5
    while($true) {
        Write-NSPConsoleHeader -Title 'ScanBridge setup and diagnostics' -Subtitle ([Environment]::MachineName)
        $choices=@(
            [pscustomobject]@{Label='Inspect helper availability';Value='Dependencies';Help='Lists installed versions of the modules setup and the task use.'}
            [pscustomobject]@{Label='Install PowerShell 7 and ScanBridge modules for all users';Value='Install';Help='What the task account needs: PowerShell 7, NSP.ScanBridge, NSP.M365.Graph 0.1.2+ and the Graph SDK in both all-users module folders. Older Graph copies are replaced. Plans first.'}
            [pscustomobject]@{Label='Prepare a local service account';Value='Account';Help='Create the non-admin account the task runs as, with the batch-logon right.'}
            [pscustomobject]@{Label='Manage routes (add, rename, change age, remove)';Value='Routes';Help='Add a route (Source picked, Spool/Archive per route) and walk through its folders, destination, site access and Sysmon. Rename/remove refused while jobs exist.'}
            [pscustomobject]@{Label='Create route folders and grant the task account access';Value='Folders';Help='Source, Spool, Archive, lock and alert folders: created when missing, Modify for the task account, Read on the settings. Plans first.'}
            [pscustomobject]@{Label='Pick the SharePoint destination for a route';Value='Destination';Help='Search sites (or paste a folder link), pick the library and folder; writes DriveId and FolderItemId. No IDs typed.'}
            [pscustomobject]@{Label='Grant the ingestion app access to route sites';Value='SiteGrant';Help='Write for the configured ingestion app on every route''s site; already-granted sites are left alone. For routes added later.'}
            [pscustomobject]@{Label='Create the ingestion app and site access';Value='Ingest';Help='Dedicated app with Sites.Selected only, write on each route''s site, certificate for the task account; writes Auth. Plans first.'}
            [pscustomobject]@{Label='Configure dispatch alerting';Value='Alerts';Help='Pick the sender mailbox in the client tenant, create a scoped alert app and write the Alerts settings. Plans first.'}
            [pscustomobject]@{Label='Inspect ScanBridge configuration health';Value='Health';Help='Route, receipt and queue health from the settings file. Read-only.'}
            [pscustomobject]@{Label='Watch readiness decisions (diagnostic only)';Value='Watch';Help='Shows when files in the Source folders would be considered ready. Moves nothing.'}
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
            if($choice -eq 'Install') { Invoke-NSPScanBridgeModuleInstall | Format-Table -AutoSize; continue }
            if($choice -eq 'Account') {
                Import-NSPToolkitModule -Name NSP.Win.LocalAccount -MinimumVersion 0.1.0
                Start-NSPLocalAccountManager
                continue
            }
            if(-not $ConfigurationPath) { $ConfigurationPath=Read-NSPScanBridgeConfigurationPath }
            if(-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) { throw 'Select an existing ScanBridge configuration file.' }
            $ConfigurationPath=(Get-Item -LiteralPath $ConfigurationPath).FullName
            if($choice -eq 'Routes') { Invoke-NSPScanBridgeRouteManager -ConfigurationPath $ConfigurationPath; continue }
            if($choice -eq 'SiteGrant') { Invoke-NSPScanBridgeSiteGrantSetup -ConfigurationPath $ConfigurationPath; continue }
            if($choice -eq 'Folders') { Invoke-NSPScanBridgeFolderSetup -ConfigurationPath $ConfigurationPath; continue }
            if($choice -eq 'Destination') { Invoke-NSPScanBridgeDestinationSetup -ConfigurationPath $ConfigurationPath; continue }
            if($choice -eq 'Ingest') { Invoke-NSPScanBridgeIngestionSetup -ConfigurationPath $ConfigurationPath; continue }
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
                $installed=Resolve-NSPScanBridgeInstalledRunner
                if($installed) { $runner=$installed.Runner; Write-NSPConsoleLine ("Task runs the all-users NSP.ScanBridge {0}: {1}" -f $installed.Version,$runner) -Role Muted }
                elseif($choice -eq 'TaskApply' -and -not (Get-NSPDryRun)) { throw 'NSP.ScanBridge is not installed for all users, so the task account could not load it. Run ''Install PowerShell 7 and ScanBridge modules for all users'' first.' }
                else {
                    $scanModule=Get-Module NSP.ScanBridge | Sort-Object Version -Descending | Select-Object -First 1
                    $runner=Join-Path $scanModule.ModuleBase 'scripts/Run-ScanBridge.ps1'
                    Write-NSPConsoleLine 'NSP.ScanBridge is not installed for all users; this plan uses the loaded copy, which the task account cannot load. Install it before registering.' -Role Warning
                }
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
