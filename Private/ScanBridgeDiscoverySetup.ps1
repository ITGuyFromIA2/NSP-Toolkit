# ScanBridge "Observe a scanner" step: a guided run of ScanBridge's read-only
# Invoke-NSPScanBridgeDeliveryDiscovery against a dedicated test folder, then an optional
# plan-first MinimumAgeSeconds change on one route and an optional manual override copy of the
# saved profile. Discovery is owned by ScanBridge; this step only gathers its inputs.

$script:NSPScanBridgeDiscoveryClasses=@('DirectExclusive','DirectReadable','TempRename','Hybrid','Unknown')

function Test-NSPScanBridgeDiscoveryFolder {
    # Where the test folder sits against the route folders. Overlapping a Spool or Archive is refused;
    # overlapping a Source is returned so the caller can check the task. Pure.
    param([Parameter(Mandatory)][string]$Folder,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Routes)
    $full={ param($p) [IO.Path]::GetFullPath([string]$p).TrimEnd('\') }
    $a=(& $full $Folder)+'\'
    $result=[pscustomobject]@{Problem=$null;SourceRoute=$null}
    foreach($route in $Routes) {
        foreach($kind in 'Source','Spool','Archive') {
            if(Test-NSPPlaceholderValue $route[$kind]) { continue }
            $b=(& $full $route[$kind])+'\'
            if(-not ($a.StartsWith($b,[StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a,[StringComparison]::OrdinalIgnoreCase))) { continue }
            if($kind -ne 'Source') { $result.Problem="The test folder overlaps route '$($route.Name)' $kind; pick a dedicated folder."; return $result }
            if(-not $result.SourceRoute) { $result.SourceRoute=[string]$route.Name }
        }
    }
    $result
}

function Get-NSPScanBridgeDiscoveryAgePlan {
    # What applying a suggested MinimumAgeSeconds would do. Lowering needs explicit confirmation and
    # is never offered for an ambiguous (Unknown or Hybrid) classification. Pure.
    param([Parameter(Mandatory)][int]$Current,[Parameter(Mandatory)][int]$Suggested,[Parameter(Mandatory)][string]$Classification)
    if($Suggested -eq $Current) { return 'Same' }
    if($Suggested -gt $Current) { return 'Raise' }
    if($Classification -in @('Unknown','Hybrid')) { return 'KeepAmbiguous' }
    'Lower'
}

function Save-NSPScanBridgeDiscoveryOverride {
    # Writes a copy of the profile with Override set; the original profile is kept unchanged.
    param([Parameter(Mandatory)][string]$ProfilePath,[Parameter(Mandatory)][string]$Classification,[Parameter(Mandatory)][string]$Reason,[DateTime]$NowUtc=[DateTime]::UtcNow)
    $deliveryProfile=[IO.File]::ReadAllText($ProfilePath) | ConvertFrom-Json
    $override=[pscustomobject][ordered]@{Classification=$Classification;Reason=$Reason;Utc=$NowUtc.ToString('o')}
    if($deliveryProfile.PSObject.Properties['Override']) { $deliveryProfile.Override=$override } else { $deliveryProfile | Add-Member -NotePropertyName Override -NotePropertyValue $override }
    $folder=Split-Path -Parent $ProfilePath
    $path=Join-Path $folder ('{0}_override_{1}.json' -f [IO.Path]::GetFileNameWithoutExtension($ProfilePath),$NowUtc.ToString('yyyyMMddTHHmmssZ'))
    [IO.File]::WriteAllText($path,($deliveryProfile | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding $false))
    $path
}

function Invoke-NSPScanBridgeDiscoverySetup {
    <#
        Observe a scanner: test folder and device label (remembered), refusal while the folder is
        a live route Source with the task not disabled, capture window and file-name choice, then
        ScanBridge's discovery. Afterwards offers the suggested readiness age for one route (plan
        first, backup kept) and a manual override copy of the profile. DRY RUN still observes,
        since discovery is read-only, but creates no folder and writes no settings or override.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    $dryRun=[bool](Get-NSPDryRun)
    $scanModule=Get-Module NSP.ScanBridge | Sort-Object Version -Descending | Select-Object -First 1
    $discover=if($scanModule){$scanModule.ExportedCommands['Invoke-NSPScanBridgeDeliveryDiscovery']}else{$null}
    if(-not $discover -or -not $discover.Parameters.ContainsKey('Path')) { throw 'This ScanBridge version does not export Invoke-NSPScanBridgeDeliveryDiscovery. Provision the build with delivery discovery first.' }
    $config=Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    $routes=@($config.Routes | Where-Object { $_ } | ForEach-Object { ConvertTo-NSPScanBridgeOrderedRoute -Route $_ })
    $answers=Get-NSPScanBridgeAnswerTable

    # 1. Dedicated test folder and device label.
    $folderArgs=@{Prompt='Dedicated test folder the scanner saves to (preferably empty)'}
    if($answers.DiscoveryFolder) { $folderArgs.Default=[string]$answers.DiscoveryFolder }
    if(-not $dryRun) { $folderArgs.Create=$true }
    $folder=Read-NSPFolderPath @folderArgs

    # 2. Spool/Archive refused; a live Source refused unless the task is disabled (the worker would claim test scans mid-capture).
    $place=Test-NSPScanBridgeDiscoveryFolder -Folder $folder -Routes $routes
    if($place.Problem) { Write-NSPConsoleLine $place.Problem -Role Error; return }
    $existing=@(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction Stop).Count
    if($existing) { Write-NSPConsoleLine "$existing file(s) already in the folder are ignored; an empty folder keeps the capture clear." -Role Muted }
    if($place.SourceRoute) {
        $task=$null; $known=$true
        try { $task=Get-NSPScanBridgeTaskState } catch { $known=$false }
        if(-not $known) { Write-NSPConsoleLine "The test folder is route '$($place.SourceRoute)' Source and the task state cannot be read. Pick a dedicated folder." -Role Error; return }
        if($task -and $task.State -ne 'Disabled') { Write-NSPConsoleLine "The test folder is route '$($place.SourceRoute)' Source and the ScanBridge task is not disabled. Disable the task first, or pick a dedicated folder." -Role Error; return }
        Write-NSPConsoleLine "The test folder is route '$($place.SourceRoute)' Source. Test scans left there are uploaded when the task runs again; remove them after the capture." -Role Warning
        if(-not (Read-NSPConfirm -Prompt 'Observe this route Source anyway?')) { return }
    }
    Write-NSPConsoleLine 'The device label is saved in the profile: keep it generic (for example Front copier), no client or person names.' -Role Muted
    do {
        $device=(Read-NSPNonEmpty -Prompt 'Device label' -CurrentValue $(if($answers.DiscoveryDevice){[string]$answers.DiscoveryDevice}else{'Scanner'})).Trim()
        $valid=$device -match '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'
        if(-not $valid) { Write-NSPConsoleLine 'Use letters, digits, spaces, dot, underscore or hyphen (up to 64).' -Role Warning }
    } until($valid)
    Save-NSPScanBridgeAnswer @{DiscoveryFolder=$folder;DiscoveryDevice=$device}

    # 3. Capture window and file names.
    $seconds=Read-NSPMenu -Prompt 'How long to watch' -CancelLabel 'Back' -Choices @(
        [pscustomobject]@{Label='3 minutes (recommended)';Value=180;Help='Time to send two or three test scans, including a multi-page one.'}
        [pscustomobject]@{Label='2 minutes';Value=120;Help='One or two short scans.'}
        [pscustomobject]@{Label='5 minutes';Value=300;Help='Several scans, or a slow device.'}
        [pscustomobject]@{Label='10 minutes';Value=600;Help='Large batches; Ctrl+C still stops early and saves results.'}
    )
    if($null -eq $seconds) { return }
    $names=Read-NSPConfirm -Prompt 'Record file names (only needed to compare with simulator logs)?'

    # 4. Discovery itself: ScanBridge prints the classification, evidence and suggested age.
    $result=& $discover -Path $folder -DeviceName $device -DurationSeconds ([double]$seconds) -IncludeFileNames:$names
    if(-not $result) { return }
    foreach($note in @($result.Recommendation.Notes)) { Write-NSPConsoleLine "  $note" -Role Muted }
    if($result.Confidence -ne 'High') { Write-NSPConsoleLine 'Repeat the capture with more test scans to raise confidence before changing settings.' -Role Muted }

    # 5. Suggested readiness age for one route, plan first; never lowered without explicit confirmation.
    $suggested=[int]$result.Recommendation.MinimumAgeSeconds
    if($routes.Count -and $suggested -gt 0 -and (Read-NSPConfirm -Prompt "Review the suggested readiness age ($suggested s) for a route?")) {
        $pick=Read-NSPMenu -Prompt 'Route this scanner saves to' -CancelLabel 'Skip' -Choices @(for($i=0;$i -lt $routes.Count;$i++) {
            $age=if($routes[$i].MinimumAgeSeconds){[int]$routes[$i].MinimumAgeSeconds}else{20}
            [pscustomobject]@{Label=('{0} (now {1} s)' -f $routes[$i].Name,$age);Value=$i;Help='Seconds a PDF must be unchanged before upload.'}
        })
        if($null -ne $pick) {
            $route=$routes[$pick]
            $current=if($route.MinimumAgeSeconds){[int]$route.MinimumAgeSeconds}else{20}
            $plan=Get-NSPScanBridgeDiscoveryAgePlan -Current $current -Suggested $suggested -Classification ([string]$result.Classification)
            $write=$false
            switch($plan) {
                'Same' { Write-NSPConsoleLine "Route '$($route.Name)' already uses $current s." -Role Success }
                'KeepAmbiguous' { Write-NSPConsoleLine "The classification is $($result.Classification), so the current $current s is kept; ambiguous behavior never lowers the age." -Role Warning }
                'Raise' { $write=$true }
                'Lower' {
                    Write-NSPConsoleLine "Lowering from $current s to $suggested s uploads sooner but leaves less margin for a paused writer." -Role Warning
                    $write=Read-NSPConfirm -Prompt "Lower route '$($route.Name)' to $suggested s?"
                }
            }
            if($write) {
                $route['MinimumAgeSeconds']=$suggested
                if(Write-NSPScanBridgeSettingsEntry -ConfigurationPath $ConfigurationPath -Key Routes -Value $routes -DryRun $dryRun) {
                    Write-NSPConsoleLine 'A Sysmon-triggered task waits the largest route age + 30 s; re-plan the task if this route is now the slowest.' -Role Muted
                }
            }
        }
    }

    # 6. Manual override: a separate copy; the measured profile stays as captured.
    if(-not $result.ProfilePath -or -not (Read-NSPConfirm -Prompt 'Record a manual classification override for this profile?')) { return }
    $class=Read-NSPMenu -Prompt 'Classification to record' -CancelLabel 'Back' -Choices @(foreach($c in $script:NSPScanBridgeDiscoveryClasses) {
        [pscustomobject]@{Label=$(if($c -eq $result.Classification){"$c (measured)"}else{$c});Value=$c;Help=$(switch($c){
            'DirectExclusive' {'Writes the final .pdf name and holds it exclusively.'}
            'DirectReadable' {'Writes the final .pdf name and lets others read while writing.'}
            'TempRename' {'Writes a temporary name, then renames it to .pdf.'}
            'Hybrid' {'Mixed or alternating behavior.'}
            'Unknown' {'Not enough evidence.'}
        })}
    })
    if($null -eq $class) { return }
    $reason=(Read-NSPNonEmpty -Prompt 'Reason (generic; no client or person names)').Trim()
    if($dryRun) { Write-NSPConsoleLine 'DRY RUN: override not saved.' -Role Warning; return }
    $path=Save-NSPScanBridgeDiscoveryOverride -ProfilePath $result.ProfilePath -Classification $class -Reason $reason
    Write-NSPConsoleLine "Override saved as a copy: $path (the measured profile is unchanged)." -Role Success
}
