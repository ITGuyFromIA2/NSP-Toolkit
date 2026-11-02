# ScanBridge Sysmon scan trigger: a Sysmon file watch on the route Source folders whose rules carry
# one name, so the ScanBridge task's event trigger reacts to those events only. The task never
# receives a filename from the event; each run is an ordinary pass over every route.

$script:NSPScanBridgeSysmonRuleName='NSP ScanBridge'

function Get-NSPScanBridgeWatchPlan {
    # Source folders to watch, and the event delay: the slowest route's MinimumAgeSeconds + 30 s.
    # Refuses a Spool or Archive at or under a Source, which would make ScanBridge trigger itself.
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    $config=Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    $routes=@($config.Routes | Where-Object { $_ })
    if(-not $routes.Count) { throw 'The settings file has no Routes to watch.' }
    $full={ param($p) [IO.Path]::GetFullPath([string]$p).TrimEnd('\') }
    $sources=@($routes | ForEach-Object { if(Test-NSPPlaceholderValue $_.Source){ throw "Route '$($_.Name)' has no Source folder." }; & $full $_.Source } | Select-Object -Unique)
    foreach($route in $routes) {
        foreach($kind in 'Spool','Archive') {
            if(Test-NSPPlaceholderValue $route[$kind]) { continue }
            $path=& $full $route[$kind]
            foreach($source in $sources) {
                if($path -ieq $source -or $path.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)) {
                    throw "Route '$($route.Name)': $kind '$path' is inside the watched Source '$source', so ScanBridge's own files would trigger it. Move the $kind outside every Source."
                }
            }
        }
    }
    $age=[int](@($routes | ForEach-Object { if($_.MinimumAgeSeconds){[int]$_.MinimumAgeSeconds}else{20} }) | Measure-Object -Maximum).Maximum
    [pscustomobject]@{Sources=$sources;MaximumAgeSeconds=$age;EventDelaySeconds=$age+30;RuleName=$script:NSPScanBridgeSysmonRuleName}
}

function Invoke-NSPScanBridgeSysmonSetup {
    <#
        Plans, then on confirm applies, the Sysmon file watch for this ScanBridge settings file.
        Sysmon missing: offers a Microsoft-signed download or a folder. Running another
        configuration: asks to Keep it (default; the rule group is saved for a manual merge) or
        Replace it. DRY RUN stops after the plan. Returns the mode: Own, Merge, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    Import-NSPToolkitModule -Name NSP.Win.Sysmon -MinimumVersion 0.1.1
    $builder=Get-Command New-NSPSysmonFileWatchConfig -ErrorAction SilentlyContinue
    if(-not $builder -or -not $builder.Parameters.ContainsKey('RuleName') -or -not (Get-Command Save-NSPSysmon -ErrorAction SilentlyContinue)) {
        throw 'NSP.Win.Sysmon does not support named rules and signed downloads. Provision the build with ScanBridge trigger support first.'
    }
    $dryRun=[bool](Get-NSPDryRun)
    $plan=Get-NSPScanBridgeWatchPlan -ConfigurationPath $ConfigurationPath
    Write-NSPConsoleLine ("Watch for new PDFs in: {0}" -f ($plan.Sources -join '; '))
    foreach($source in $plan.Sources) { if(-not (Test-Path -LiteralPath $source -PathType Container)) { Write-NSPConsoleLine "Source folder $source does not exist yet; Sysmon still watches the path." -Role Warning } }
    if(-not $dryRun -and -not (Test-NSPScanBridgeElevated)) { Write-NSPConsoleLine 'Installing or applying Sysmon needs an elevated session. Restart PowerShell as administrator.' -Role Error; return }

    $configDirectory=Split-Path -Parent $ConfigurationPath
    $sysmonConfig=Join-Path $configDirectory 'Sysmon.xml'
    $xml=New-NSPSysmonFileWatchConfig -Path $plan.Sources -IncludeExtension '.pdf' -RuleName $plan.RuleName
    $status=Get-NSPSysmonStatus
    $installArgs=@{ConfigPath=$sysmonConfig;Configuration=$xml}
    if(-not $status.Installed) {
        $found=Find-NSPSysmon
        if(-not $found) {
            $source=Read-NSPMenu -Prompt 'Sysmon is not installed. Where should it come from?' -CancelLabel 'Back' -Choices @(
                [pscustomobject]@{Label='Download from Microsoft';Value='Download';Help='From download.sysinternals.com; kept only when signed by Microsoft Corporation. Saved under C:\ProgramData\NSP\Sysmon.'}
                [pscustomobject]@{Label='Use a folder I have';Value='Folder';Help='A folder or USB drive containing Sysmon64.exe (or Sysmon.exe).'}
            )
            if($null -eq $source) { return }
            if($source -eq 'Folder') {
                $found=Find-NSPSysmon -Path (Read-NSPNonEmpty -Prompt 'Folder containing Sysmon64.exe').Trim().Trim('"')
                if(-not $found) { Write-NSPConsoleLine 'No Sysmon64.exe or Sysmon.exe there.' -Role Error; return }
            } elseif($dryRun) {
                Write-NSPConsoleLine 'DRY RUN: would download Sysmon from Microsoft and check its signature.' -Role Warning
            } elseif(Read-NSPConfirm -Prompt 'Download Sysmon from Microsoft now?' -DefaultYes) {
                $saved=Save-NSPSysmon -Destination (Join-Path $env:ProgramData 'NSP\Sysmon') -Confirm:$false
                Write-NSPConsoleLine ("Downloaded Sysmon {0}, signed by {1}." -f $saved.Version,$saved.Signer) -Role Success
                $found=$saved.Path
            } else { return }
        }
        if($found) { $installArgs.SysmonPath=$found }
        $action="Install Sysmon$(if($found){" from $found"})"
    } elseif($status.ConfigFile -and [IO.Path]::GetFullPath([string]$status.ConfigFile) -ieq [IO.Path]::GetFullPath($sysmonConfig)) {
        $check=Test-NSPSysmonConfig -ConfigPath $sysmonConfig -Configuration $xml
        if($check.InSync) { Write-NSPConsoleLine 'Sysmon is already watching these folders with the ScanBridge rules.' -Role Success; return 'Own' }
        $action='Update the ScanBridge Sysmon configuration'
    } else {
        $other=if($status.ConfigFile){[string]$status.ConfigFile}else{'(an unrecorded file)'}
        Write-NSPConsoleLine ("Sysmon {0} is running another configuration: {1}" -f $status.Version,$other) -Role Warning
        $choice=Read-NSPMenu -Prompt 'What should happen to that configuration?' -CancelLabel 'Back' -Choices @(
            [pscustomobject]@{Label='Keep it and merge the ScanBridge rules by hand';Value='Keep';Help="Nothing changes in Sysmon. The ScanBridge rule group is saved next to the settings; once merged, the task reacts only to rules named '$($plan.RuleName)'."}
            [pscustomobject]@{Label='Replace it with the ScanBridge-only configuration';Value='Replace';Help='Whatever that configuration logs today (often security monitoring) stops being logged. Only for test or leftover configurations.'}
        )
        if($null -eq $choice) { return }
        if($choice -eq 'Keep') {
            $fragmentPath=Join-Path $configDirectory 'ScanBridge-Sysmon-RuleGroup.xml'
            $fragment=New-NSPSysmonFileWatchConfig -Path $plan.Sources -IncludeExtension '.pdf' -RuleName $plan.RuleName -RuleGroupOnly
            if($dryRun) { Write-NSPConsoleLine "DRY RUN: would save the rule group to $fragmentPath." -Role Warning; return 'Merge' }
            [IO.File]::WriteAllText($fragmentPath,$fragment+"`r`n",(New-Object Text.UTF8Encoding($false)))
            Write-NSPConsoleLine "Saved the rule group to $fragmentPath. Add it inside <EventFiltering> of $other and re-apply that configuration with its owner's process." -Role Success
            return 'Merge'
        }
        $installArgs.Force=$true
        $action="Replace $other with the ScanBridge configuration"
    }

    Write-NSPConsoleLine ("Sysmon plan: {0}; configuration {1}; rule name '{2}'." -f $action,$sysmonConfig,$plan.RuleName)
    if($dryRun) { Write-NSPConsoleLine 'DRY RUN: Sysmon not installed or changed.' -Role Warning; return }
    if(-not (Read-NSPConfirm -Prompt "$action now?")) { return }
    Install-NSPSysmon @installArgs -Confirm:$false | Out-Null
    $check=Test-NSPSysmonConfig -ConfigPath $sysmonConfig -Configuration $xml
    if($check.InSync) { Write-NSPConsoleLine 'Sysmon is now watching the Source folders for new PDFs.' -Role Success; return 'Own' }
    Write-NSPConsoleLine ("Sysmon did not confirm the configuration: {0}" -f (@($check.Problems) -join '; ')) -Role Error
}

function Read-NSPScanBridgeTriggerMode {
    # Sysmon events plus a 15-minute sweep, or periodic only. Returns @{Sysmon;Minutes;DelaySeconds} or $null.
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    $plan=try { Get-NSPScanBridgeWatchPlan -ConfigurationPath $ConfigurationPath } catch { Write-NSPConsoleLine $_.Exception.Message -Role Warning; $null }
    $installed=[bool](Get-Service -Name 'Sysmon64','Sysmon' -ErrorAction SilentlyContinue)
    $choices=@()
    if($plan -and $installed) {
        $choices+=[pscustomobject]@{Label='Sysmon events plus a sweep every 15 minutes';Value='Sysmon';Help=("Starts a pass {0} s after a PDF is created (route age {1} s + 30 s). Needs 'Set up the Sysmon scan trigger' done first." -f $plan.EventDelaySeconds,$plan.MaximumAgeSeconds)}
    }
    $choices+=[pscustomobject]@{Label='Periodic only';Value='Periodic';Help=$(if($installed){'No event trigger; runs on a fixed interval.'}else{'Sysmon is not installed here; runs on a fixed interval.'})}
    $mode=Read-NSPMenu -Choices $choices -Prompt 'When should the task run?' -CancelLabel 'Back'
    if($null -eq $mode) { return $null }
    if($mode -eq 'Sysmon') { return @{Sysmon=$true;Minutes=15;DelaySeconds=$plan.EventDelaySeconds} }
    $minutes=Read-NSPScanBridgeTaskInterval
    if($null -eq $minutes) { return $null }
    @{Sysmon=$false;Minutes=$minutes;DelaySeconds=$null}
}
