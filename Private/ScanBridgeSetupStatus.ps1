# ScanBridge setup status dashboard: one read-only status object (Get-NSPScanBridgeSetupStatus),
# drawn above the setup menu by Show-NSPScanBridgeSetupStatus. Names and states only: no tenant or
# app IDs, thumbprints, addresses, paths or file names, so a screenshot is safe to share. A read
# that fails is Unknown, never No, and the verdict is never Ready while any line is Unknown.

$script:NSPScanBridgeTaskName='ScanBridge'
$script:NSPScanBridgeTaskPath='\NSP\'
$script:NSPScanBridgeSourceWarningMinutes=30

function New-NSPSetupStatusLine {
    # Role: Success, Warning, Error or Muted (unknown / not applicable). Blocker: why unattended runs cannot work yet.
    param([Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][AllowEmptyString()][string]$Text,[string]$Role='Normal',[string]$Blocker,[switch]$Detail)
    [pscustomobject]@{Label=$Label;Text=$Text;Role=$Role;Blocker=$(if($Blocker){$Blocker}else{$null});Detail=[bool]$Detail}
}

function New-NSPSetupUnknownLine {
    # A failed read: shown Gray and blocking, with a generic reason rather than the exception text (which can carry paths).
    param([Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][string]$Reason,[switch]$Detail)
    New-NSPSetupStatusLine -Label $Label -Text "Unknown ($Reason)" -Role Muted -Blocker "$($Label.ToLowerInvariant()) unknown" -Detail:$Detail
}

function Get-NSPSetupStatusReason {
    param([Parameter(Mandatory)][object]$ErrorRecord)
    $exception=if($ErrorRecord -is [Management.Automation.ErrorRecord]){$ErrorRecord.Exception}else{$ErrorRecord}
    for($e=$exception; $e; $e=$e.InnerException) {
        if($e -is [UnauthorizedAccessException] -or $e.Message -match 'Access is denied|0x80070005') { return 'access denied' }
    }
    'read failed'
}

function Use-NSPSetupStatusModule {
    # Loads an installed or checked-out sibling for a status read. Never installs from the Gallery on a redraw.
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][version]$MinimumVersion)
    $previous=$env:NSP_NO_AUTOINSTALL
    $env:NSP_NO_AUTOINSTALL='1'
    try { Import-NSPToolkitModule -Name $Name -MinimumVersion $MinimumVersion; $true }
    catch { $false }
    finally { $env:NSP_NO_AUTOINSTALL=$previous }
}

function Test-NSPAclAllowsRead {
    # True when the ACL has an explicit Allow ACE granting Read to this SID. Group membership is not evaluated.
    param([Parameter(Mandatory)][Security.AccessControl.FileSystemSecurity]$Acl,[Parameter(Mandatory)][string]$Sid)
    $read=[Security.AccessControl.FileSystemRights]::Read
    foreach($rule in $Acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -eq $Sid -and ($rule.FileSystemRights -band $read) -eq $read) { return $true }
    }
    $false
}

function Get-NSPScanBridgeTaskState {
    # The ScanBridge task through the Task Scheduler COM API (milliseconds; Get-ScheduledTask's CIM
    # query takes seconds, too slow for every redraw). $null when the task or its folder is absent.
    $service=New-Object -ComObject Schedule.Service
    $service.Connect()
    try { $task=$service.GetFolder($script:NSPScanBridgeTaskPath.TrimEnd('\')).GetTask($script:NSPScanBridgeTaskName) }
    catch { if($_.Exception.HResult -in @(0x80070002,0x80070003)) { return $null }; throw }
    $definition=$task.Definition
    $states=@{0='Unknown';1='Disabled';2='Queued';3='Ready';4='Running'}
    [pscustomobject]@{
        State=$(if($states.ContainsKey([int]$task.State)){$states[[int]$task.State]}else{'Unknown'})
        UserId=[string]$definition.Principal.UserId
        Actions=@(foreach($action in @($definition.Actions)) { if($action.Type -eq 0) { [pscustomobject]@{Execute=[string]$action.Path;Arguments=[string]$action.Arguments} } })
        LastRunTime=[datetime]$task.LastRunTime
        LastTaskResult=[int64]$task.LastTaskResult
    }
}

function Get-NSPScanBridgeSetupCertificate {
    <#
        Store, days left and task-account key read for one app certificate. Same lookup order as
        ScanBridge's private Get-NSPScanBridgeCertificateStatus (LocalMachine\My, then this
        console user's CurrentUser\My); duplicated until that check moves to NSP.M365.Graph.
        KeyReadable is $null when it cannot be decided here (no task account, user store, unreadable key).
    #>
    param([Parameter(Mandatory)][string]$Thumbprint,[string]$Sid,[DateTime]$NowUtc=[DateTime]::UtcNow)
    $result=[ordered]@{Store=$null;DaysRemaining=$null;KeyReadable=$null;KeyReason=$null}
    foreach($store in 'LocalMachine','CurrentUser') {
        $certificate=Get-Item -LiteralPath ("Cert:\$store\My\$Thumbprint") -ErrorAction SilentlyContinue
        if($certificate) { $result.Store=$store; break }
    }
    if(-not $certificate) { return [pscustomobject]$result }
    $result.DaysRemaining=[int][math]::Floor(($certificate.NotAfter.ToUniversalTime()-$NowUtc).TotalDays)
    if($result.Store -eq 'CurrentUser') { $result.KeyReason='in your user store only'; return [pscustomobject]$result }
    if(-not $certificate.HasPrivateKey) { $result.KeyReadable=$false; $result.KeyReason='no private key'; return [pscustomobject]$result }
    if(-not $Sid) { $result.KeyReason='no task account'; return [pscustomobject]$result }
    try {
        $rsa=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
        try {
            $name=if($rsa -is [Security.Cryptography.RSACng]){[string]$rsa.Key.UniqueName}elseif($rsa -is [Security.Cryptography.RSACryptoServiceProvider]){[string]$rsa.CspKeyContainerInfo.UniqueKeyContainerName}else{$null}
        } finally { if($rsa) { $rsa.Dispose() } }
        if(-not $name -or [IO.Path]::GetFileName($name) -ne $name) { $result.KeyReason='key not a software machine key'; return [pscustomobject]$result }
        $base=[Environment]::GetFolderPath('CommonApplicationData')
        $file=@('Microsoft\Crypto\Keys','Microsoft\Crypto\RSA\MachineKeys') | ForEach-Object { Join-Path (Join-Path $base $_) $name } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if(-not $file) { $result.KeyReason='key file not found'; return [pscustomobject]$result }
        $result.KeyReadable=Test-NSPAclAllowsRead -Acl (Get-Acl -LiteralPath $file) -Sid $Sid
    } catch { $result.KeyReason=Get-NSPSetupStatusReason $_ }
    [pscustomobject]$result
}

function ConvertTo-NSPSetupCertificateLine {
    # NPS/PKI colors: under 30 days Red, under 90 Yellow. Missing or expired blocks; a key the task account cannot read blocks.
    param([Parameter(Mandatory)][string]$Label,[Parameter(Mandatory)][object]$Certificate,[string]$Prefix,[switch]$Detail)
    $parts=@(); if($Prefix) { $parts+=$Prefix }
    if(-not $Certificate.Store) { return New-NSPSetupStatusLine -Label $Label -Text (($parts+'certificate missing on this computer') -join ', ') -Role Error -Blocker "$($Label.ToLowerInvariant()) certificate missing" -Detail:$Detail }
    $days=$Certificate.DaysRemaining
    if($days -lt 0) { return New-NSPSetupStatusLine -Label $Label -Text (($parts+"certificate $($Certificate.Store), EXPIRED") -join ', ') -Role Error -Blocker "$($Label.ToLowerInvariant()) certificate expired" -Detail:$Detail }
    $role=if($days -lt 30){'Error'}elseif($days -lt 90){'Warning'}else{'Success'}
    $parts+="certificate $($Certificate.Store), $days days left"
    $blocker=$null
    if($Certificate.KeyReadable -eq $true) { $parts+='task account can read key' }
    elseif($Certificate.KeyReadable -eq $false) {
        $parts+="task account cannot read key$(if($Certificate.KeyReason){" ($($Certificate.KeyReason))"})"
        $role='Error'; $blocker="task account cannot read the $($Label.ToLowerInvariant()) key"
    } else {
        $parts+="key access unknown ($($Certificate.KeyReason))"
        if($role -eq 'Success') { $role='Muted' }
        $blocker="$($Label.ToLowerInvariant()) key access unknown"
    }
    New-NSPSetupStatusLine -Label $Label -Text ($parts -join ', ') -Role $role -Blocker $blocker -Detail:$Detail
}

function Get-NSPScanBridgeSysmonCoverage {
    # Source folders covered by a rule named RuleName in the loaded Sysmon configuration file: TargetFilename "begin with" values.
    param([Parameter(Mandatory)][xml]$Configuration,[Parameter(Mandatory)][string]$RuleName,[Parameter(Mandatory)][string[]]$Source)
    $prefixes=@(foreach($node in $Configuration.SelectNodes('//TargetFilename[@condition="begin with"]')) {
        $named=($node.GetAttribute('name') -eq $RuleName) -or ($node.ParentNode.LocalName -eq 'Rule' -and $node.ParentNode.GetAttribute('name') -eq $RuleName)
        if($named) { $node.InnerText.Trim().TrimEnd('\') }
    })
    @($Source | Where-Object { $s=$_.TrimEnd('\'); @($prefixes | Where-Object { $s -ieq $_ -or $s.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase) }).Count }).Count
}

function Get-NSPScanBridgeSetupStatus {
    <#
        Read-only status for the setup screen. Settings-dependent lines say "settings not selected"
        without a readable ConfigurationPath. Each read is bounded to local state: no sign-in, no
        receipt validation or PDF hashing (the Health menu item keeps that).
    #>
    param([string]$ConfigurationPath,[DateTime]$NowUtc=[DateTime]::UtcNow)
    $lines=[Collections.Generic.List[object]]::new()
    $add={ param($line) foreach($l in @($line)) { $lines.Add($l) } }
    $notSelected={ param($label) New-NSPSetupStatusLine -Label $label -Text 'settings not selected' -Role Muted -Blocker 'settings not selected' }

    $config=$null; $configReason=$null
    if($ConfigurationPath -and (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) {
        try { $config=Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop } catch { $configReason='settings unreadable' }
    }

    # Helpers: ScanBridge, Graph and SDK in both all-users folders.
    try {
        $editions=@('WinPS','PS7'); $roots=@(Get-NSPAllUsersModuleRoot)
        $rows=@(for($i=0; $i -lt $roots.Count; $i++) {
            $best=@{}
            foreach($name in 'NSP.ScanBridge','NSP.M365.Graph','Microsoft.Graph.Authentication') { $best[$name]=@(Get-NSPAllUsersModuleVersion -Root $roots[$i] -Name $name | Sort-Object Version -Descending)[0] }
            $text=(@(foreach($pair in @(@('NSP.ScanBridge','ScanBridge'),@('NSP.M365.Graph','Graph'),@('Microsoft.Graph.Authentication','SDK'))) {
                if($best[$pair[0]]) { "$($pair[1]) $($best[$pair[0]].Version)" } else { "$($pair[1]) missing" }
            })) -join ', '
            $complete=$best['NSP.ScanBridge'] -and $best['Microsoft.Graph.Authentication'] -and $best['NSP.M365.Graph'] -and $best['NSP.M365.Graph'].Version -ge [version]'0.1.2'
            [pscustomobject]@{Edition=$(if($i -lt $editions.Count){$editions[$i]}else{"folder $($i+1)"});Text=$text;Complete=[bool]$complete}
        })
        $anyComplete=@($rows | Where-Object Complete).Count -gt 0
        $role=if(@($rows | Where-Object { -not $_.Complete }).Count -eq 0){'Success'}elseif($anyComplete){'Warning'}else{'Error'}
        $blocker=if($anyComplete){$null}else{'ScanBridge modules not installed for all users'}
        if(@($rows | Select-Object -ExpandProperty Text -Unique).Count -eq 1) { & $add (New-NSPSetupStatusLine -Label 'Helpers' -Text "$($rows[0].Text) ($(@($rows.Edition) -join ' and '))" -Role $role -Blocker $blocker) }
        else {
            & $add (New-NSPSetupStatusLine -Label 'Helpers' -Text $(if($role -eq 'Error'){'incomplete in every all-users folder'}else{'differ between editions'}) -Role $role -Blocker $blocker)
            foreach($row in $rows) { & $add (New-NSPSetupStatusLine -Label $row.Edition -Text $row.Text -Role $(if($row.Complete){'Success'}else{'Warning'}) -Detail) }
        }
    } catch { & $add (New-NSPSetupUnknownLine -Label 'Helpers' -Reason (Get-NSPSetupStatusReason $_)) }

    try {
        $pwsh=Find-NSPPowerShell7
        & $add $(if($pwsh){New-NSPSetupStatusLine -Label 'PowerShell 7' -Text "found ($(([string]$pwsh.Version -split ' ')[0]))" -Role Success}else{New-NSPSetupStatusLine -Label 'PowerShell 7' -Text 'missing' -Role Warning})
    } catch { & $add (New-NSPSetupUnknownLine -Label 'PowerShell 7' -Reason (Get-NSPSetupStatusReason $_)) }

    # Task first (quietly): its principal is the account the other lines check.
    $task=$null; $taskReason=$null
    try { $task=Get-NSPScanBridgeTaskState } catch { $taskReason=Get-NSPSetupStatusReason $_ }
    $saved=[string](Get-NSPScanBridgeAnswerTable).ServiceAccount
    $accountName=$null; $accountKind=$null
    $principal=if($task){$task.UserId}else{$null}
    $candidate=if($principal){$principal}elseif($saved){$saved}else{$null}
    if($candidate -in @('SYSTEM','NT AUTHORITY\SYSTEM','S-1-5-18')) { $accountKind='System'; $accountName='SYSTEM' }
    elseif($candidate) {
        $local=ConvertTo-NSPLocalAccountName -Account $candidate
        if($local) { $accountKind='Local'; $accountName=$local } else { $accountKind='Other'; $accountName=$candidate }
    }

    # Service account.
    $sid=$null
    if($accountKind -eq 'System') { $sid='S-1-5-18'; & $add (New-NSPSetupStatusLine -Label 'Service account' -Text 'SYSTEM' -Role Success) }
    elseif($accountKind -eq 'Local') {
        try {
            if(-not (Use-NSPSetupStatusModule -Name NSP.Win.LocalAccount -MinimumVersion 0.1.0)) { & $add (New-NSPSetupUnknownLine -Label 'Service account' -Reason 'NSP.Win.LocalAccount not available') }
            else {
                $account=Get-NSPLocalServiceAccount -Name $accountName
                if(-not $account) { & $add (New-NSPSetupStatusLine -Label 'Service account' -Text "$accountName - does not exist" -Role Error -Blocker 'service account missing') }
                else {
                    $sid=$account.SID
                    $right=try { Get-NSPLocalAccountRight -Name $accountName } catch { $null }
                    $rightText=if(-not $right){'batch-logon right unknown'}elseif($right.DirectDenyBatchLogon){'batch logon DENIED'}elseif($right.DirectBatchLogon){'batch logon granted'}else{'no batch-logon right'}
                    $role='Success'; $blocker=$null
                    if(-not $account.Enabled) { $role='Error'; $blocker='service account disabled' }
                    elseif(-not $right) { $role='Muted'; $blocker='service account batch-logon right unknown' }
                    elseif($right.DirectDenyBatchLogon -or -not $right.DirectBatchLogon) { $role='Error'; $blocker='service account lacks batch logon' }
                    & $add (New-NSPSetupStatusLine -Label 'Service account' -Text ("{0} - {1}, {2}" -f $accountName,$(if($account.Enabled){'enabled'}else{'DISABLED'}),$rightText) -Role $role -Blocker $blocker)
                }
            }
        } catch { & $add (New-NSPSetupUnknownLine -Label 'Service account' -Reason (Get-NSPSetupStatusReason $_)) }
    }
    elseif($accountKind -eq 'Other') { & $add (New-NSPSetupUnknownLine -Label 'Service account' -Reason 'not a local account; not checked here') }
    elseif($taskReason) { & $add (New-NSPSetupUnknownLine -Label 'Service account' -Reason "task $taskReason") }
    else { & $add (New-NSPSetupStatusLine -Label 'Service account' -Text 'not chosen' -Role Warning -Blocker 'service account not chosen') }

    # Routes.
    $routes=@()
    if(-not $config) { & $add $(if($configReason){New-NSPSetupUnknownLine -Label 'Routes' -Reason $configReason}else{& $notSelected 'Routes'}) }
    else {
        $routes=@($config.Routes | Where-Object { $_ })
        if(-not $routes.Count) { & $add (New-NSPSetupStatusLine -Label 'Routes' -Text 'none configured' -Role Error -Blocker 'no routes') }
        else {
            & $add (New-NSPSetupStatusLine -Label 'Routes' -Text "$($routes.Count) configured" -Role Normal)
            foreach($route in $routes) {
                $name=[string]$route.Name
                try {
                    $missing=@('Source','Spool','Archive' | Where-Object { (Test-NSPPlaceholderValue $route[$_]) -or -not (Test-Path -LiteralPath ([string]$route[$_]) -PathType Container) })
                    $destination=-not (Test-NSPPlaceholderValue $route.DriveId) -and -not (Test-NSPPlaceholderValue $route.FolderItemId)
                    $count={ param($kind) if($kind -in $missing){'?'}else{@(Get-ChildItem -LiteralPath ([string]$route[$kind]) -File -ErrorAction Stop).Count} }
                    $text=('{0}, {1}, queue {2}/{3}' -f $(if($missing.Count){"$($missing -join '/') missing"}else{'folders OK'}),$(if($destination){'destination set'}else{'NO destination'}),(& $count 'Source'),(& $count 'Spool'))
                    $blocker=if($missing.Count){"route $name folders missing"}elseif(-not $destination){"route $name has no destination"}else{$null}
                    $role=if($blocker){'Error'}else{'Success'}
                    # Oldest unclaimed source PDF by last write, the worker's readiness clock (ScanBridge SourceAge, 30 min default).
                    if('Source' -notin $missing) {
                        $oldest=@(Get-ChildItem -LiteralPath ([string]$route.Source) -File -Filter '*.pdf' -ErrorAction Stop | Sort-Object LastWriteTimeUtc | Select-Object -First 1)
                        if($oldest.Count) {
                            $minutes=[int][math]::Max(0,[math]::Floor(($NowUtc-$oldest[0].LastWriteTimeUtc).TotalMinutes))
                            $text+=", oldest unclaimed source $minutes min"
                            if($minutes -ge $script:NSPScanBridgeSourceWarningMinutes -and $role -eq 'Success') { $role='Warning' }
                        }
                    }
                    & $add (New-NSPSetupStatusLine -Label $name -Text $text -Role $role -Blocker $blocker -Detail)
                } catch { & $add (New-NSPSetupUnknownLine -Label $name -Reason (Get-NSPSetupStatusReason $_) -Detail) }
            }
        }
    }

    # Ingestion and alert apps.
    if(-not $config) { & $add $(if($configReason){New-NSPSetupUnknownLine -Label 'Ingestion app' -Reason $configReason}else{& $notSelected 'Ingestion app'}) }
    elseif(Test-NSPPlaceholderValue $config.Auth.CertificateThumbprint) { & $add (New-NSPSetupStatusLine -Label 'Ingestion app' -Text 'not configured' -Role Error -Blocker 'ingestion app not configured') }
    else {
        try { & $add (ConvertTo-NSPSetupCertificateLine -Label 'Ingestion app' -Certificate (Get-NSPScanBridgeSetupCertificate -Thumbprint ([string]$config.Auth.CertificateThumbprint) -Sid $sid)) }
        catch { & $add (New-NSPSetupUnknownLine -Label 'Ingestion app' -Reason (Get-NSPSetupStatusReason $_)) }
    }
    if(-not $config) { & $add $(if($configReason){New-NSPSetupUnknownLine -Label 'Alerts' -Reason $configReason}else{& $notSelected 'Alerts'}) }
    else {
        $alerts=$config.Alerts
        if(-not $alerts -or -not $alerts.Enabled) { & $add (New-NSPSetupStatusLine -Label 'Alerts' -Text 'disabled' -Role Warning) }
        else {
            $parts=@('enabled'); $role='Success'; $blocker=$null
            $tenantMatches=-not (Test-NSPPlaceholderValue $alerts.Auth.TenantId) -and [string]$alerts.Auth.TenantId -eq [string]$config.Auth.TenantId
            $parts+=$(if($tenantMatches){'tenant matches'}else{'tenant DIFFERS from ingestion'})
            if(-not $tenantMatches) { $role='Error'; $blocker='alert tenant differs from ingestion' }
            $addresses=-not (Test-NSPPlaceholderValue $alerts.From) -and -not (Test-NSPPlaceholderValue $alerts.To)
            if(-not $addresses) { $parts+='sender/recipient NOT set'; $role='Error'; if(-not $blocker){$blocker='alert sender/recipient not set'} }
            if(-not (Test-NSPPlaceholderValue $alerts.StateDirectory) -and -not (Test-Path -LiteralPath ([string]$alerts.StateDirectory) -PathType Container)) { $parts+='state folder missing'; if($role -eq 'Success'){$role='Warning'} }
            if(Test-NSPPlaceholderValue $alerts.Auth.CertificateThumbprint) {
                & $add (New-NSPSetupStatusLine -Label 'Alerts' -Text (($parts+'alert app not configured') -join ', ') -Role Error -Blocker $(if($blocker){$blocker}else{'alert app not configured'}))
            } else {
                $line=try { ConvertTo-NSPSetupCertificateLine -Label 'Alerts' -Prefix ($parts -join ', ') -Certificate (Get-NSPScanBridgeSetupCertificate -Thumbprint ([string]$alerts.Auth.CertificateThumbprint) -Sid $sid) } catch { New-NSPSetupUnknownLine -Label 'Alerts' -Reason (Get-NSPSetupStatusReason $_) }
                if($blocker) { $line.Role='Error'; $line.Blocker=$blocker }
                & $add $line
            }
            & $add (New-NSPSetupStatusLine -Label 'Mail' -Text 'send not verified here (use the setup test message)' -Role Muted -Detail)
        }
    }

    # Sysmon: optional (the periodic sweep still runs), so never blocking.
    try {
        if(-not (Use-NSPSetupStatusModule -Name NSP.Win.Sysmon -MinimumVersion 0.1.1)) { & $add (New-NSPSetupStatusLine -Label 'Sysmon' -Text 'Unknown (NSP.Win.Sysmon not available)' -Role Muted) }
        else {
            $sysmon=Get-NSPSysmonStatus
            if(-not $sysmon.Installed) { & $add (New-NSPSetupStatusLine -Label 'Sysmon' -Text 'not installed (periodic runs only)' -Role Warning) }
            else {
                $parts=@($(if($sysmon.Running){'running'}else{'NOT running'})); $role=if($sysmon.Running){'Success'}else{'Warning'}
                if(-not $config) { $parts+=$(if($configReason){"rule coverage unknown ($configReason)"}else{'settings not selected'}); if($role -eq 'Success'){$role='Muted'} }
                elseif(-not $sysmon.ConfigFile -or -not (Test-Path -LiteralPath ([string]$sysmon.ConfigFile) -PathType Leaf)) { $parts+='rule coverage unknown (configuration file not readable)'; if($role -eq 'Success'){$role='Muted'} }
                else {
                    $sources=@($routes | Where-Object { -not (Test-NSPPlaceholderValue $_.Source) } | ForEach-Object { [IO.Path]::GetFullPath([string]$_.Source) } | Select-Object -Unique)
                    $covered=Get-NSPScanBridgeSysmonCoverage -Configuration ([xml][IO.File]::ReadAllText([string]$sysmon.ConfigFile)) -RuleName $script:NSPScanBridgeSysmonRuleName -Source $sources
                    $parts+=$(if($covered){"ScanBridge rule covers $covered of $($sources.Count) Sources"}else{'no ScanBridge rule'})
                    if($covered -lt $sources.Count) { $role='Warning' }
                    if(-not (Test-NSPSysmonConfig -ConfigPath ([string]$sysmon.ConfigFile)).InSync) { $parts+='loaded configuration differs from its file'; $role='Warning' }
                }
                & $add (New-NSPSetupStatusLine -Label 'Sysmon' -Text ($parts -join ', ') -Role $role)
            }
        }
    } catch { & $add (New-NSPSetupStatusLine -Label 'Sysmon' -Text "Unknown ($(Get-NSPSetupStatusReason $_))" -Role Muted) }

    # Scheduled task.
    if($taskReason) { & $add (New-NSPSetupUnknownLine -Label 'Scheduled task' -Reason $taskReason) }
    elseif(-not $task) { & $add (New-NSPSetupStatusLine -Label 'Scheduled task' -Text 'not registered' -Role Error -Blocker 'task not registered') }
    else {
        $taskState=[string]$task.State
        $parts=@('registered',$(if($taskState -eq 'Disabled'){'DISABLED'}else{$taskState}))
        $role='Success'; $blocker=$null
        if($taskState -eq 'Disabled') { $role='Error'; $blocker='task disabled' }
        $hosts=@(@($task.Actions) | ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_.Execute) } | Where-Object { $_ })
        if(@($hosts | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count) { $parts+='its PowerShell is MISSING'; $role='Error'; if(-not $blocker){$blocker='task PowerShell missing'} }
        $result=$task.LastTaskResult
        if($result -eq 267011 -or -not $task.LastRunTime -or $task.LastRunTime.Year -lt 2000) { $parts+='never run' }
        else { $parts+=('last result {0} ({1})' -f $result,$task.LastRunTime.ToString('yyyy-MM-dd HH:mm')); if($result -ne 0 -and $role -eq 'Success'){$role='Warning'} }
        if($saved -and $accountKind -ne 'System' -and $accountName -ine $saved) { $parts+='runs as a different account than the saved one'; if($role -eq 'Success'){$role='Warning'} }
        try {
            $installed=Resolve-NSPScanBridgeInstalledRunner
            $arguments=(@($task.Actions) | ForEach-Object { [string]$_.Arguments }) -join ' '
            if(-not $installed) { $parts+='ScanBridge not installed for all users'; $role='Error'; if(-not $blocker){$blocker='task runner not installed'} }
            elseif($arguments.IndexOf($installed.Runner,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $parts+="runs installed $($installed.Version)" }
            else { $parts+='runner is not the installed copy'; if($role -eq 'Success'){$role='Warning'} }
        } catch { $parts+='runner unknown' }
        & $add (New-NSPSetupStatusLine -Label 'Scheduled task' -Text ($parts -join ', ') -Role $role -Blocker $blocker)
    }

    $first=@($lines | Where-Object Blocker | Select-Object -First 1)
    [pscustomobject]@{
        ConfigurationSelected=[bool]$config
        Lines=@($lines)
        Ready=(-not $first.Count)
        Reason=$(if($first.Count){$first[0].Blocker}else{$null})
    }
}

function Show-NSPScanBridgeSetupStatus {
    # Renders Get-NSPScanBridgeSetupStatus through NSP.Console: label column, colored status, verdict.
    param([Parameter(Mandatory)][object]$Status)
    foreach($line in $Status.Lines) {
        $label=if($line.Detail){"  $($line.Label):"}else{"$($line.Label):"}
        Write-NSPConsoleSegment -Segment @(@($label,'Muted',27),@($line.Text,$line.Role))
    }
    Write-NSPConsoleLine ''
    $verdict=if($Status.Ready){@('Yes','Success')}else{@("No - $($Status.Reason)",'Error')}
    Write-NSPConsoleSegment -Segment @(@('Ready for unattended runs:','Strong',27),$verdict)
    Write-NSPConsoleLine ('  MODE: {0}' -f $(if(Get-NSPDryRun){'DRY RUN - setup actions plan only'}else{'APPLY - setup actions change this computer or tenant after confirmation'})) -Role $(if(Get-NSPDryRun){'Warning'}else{'Muted'})
    Write-NSPConsoleLine ''
}
