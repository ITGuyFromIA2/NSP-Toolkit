# ScanBridge route setup: the SharePoint destination of a route (found by search or link, never
# typed IDs), the dedicated ingestion app with Sites.Selected and a write grant on each route's
# site, and the local route folders with access for the task account. Each change is planned and
# confirmed; DRY RUN stops after the plans.

$script:NSPScanBridgeRouteKeyOrder=@('Name','Source','Spool','Archive','DriveId','FolderItemId','MinimumAgeSeconds','VerifyRemoteAfterUpload')

function ConvertTo-NSPScanBridgeOrderedRoute {
    param([Parameter(Mandatory)][Collections.IDictionary]$Route)
    $ordered=[ordered]@{}
    foreach($key in $script:NSPScanBridgeRouteKeyOrder) { if($Route.Contains($key)) { $ordered[$key]=$Route[$key] } }
    foreach($key in @($Route.Keys | Where-Object { $_ -notin $script:NSPScanBridgeRouteKeyOrder } | Sort-Object)) { $ordered[$key]=$Route[$key] }
    $ordered
}

function Test-NSPScanBridgeRouteFolderRule {
    # The worker's folder rules for a route set: every Source/Spool/Archive given, all separate
    # and non-overlapping, Source and Spool on one drive. Returns a message, or $null when fine.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Routes)
    $full={ param($p) [IO.Path]::GetFullPath([string]$p).TrimEnd('\') }
    $folders=[System.Collections.Generic.List[object]]::new()
    foreach($route in $Routes) {
        foreach($kind in 'Source','Spool','Archive') {
            if(Test-NSPPlaceholderValue $route[$kind]) { return "Route '$($route.Name)' has no $kind folder." }
            $folders.Add([pscustomobject]@{Path=(& $full $route[$kind]);Why="$($route.Name) $kind"})
        }
        if([IO.Path]::GetPathRoot((& $full $route.Source)) -ine [IO.Path]::GetPathRoot((& $full $route.Spool))) { return "Route '$($route.Name)': Source and Spool must be on the same drive." }
    }
    for($i=0;$i -lt $folders.Count;$i++) { for($j=$i+1;$j -lt $folders.Count;$j++) {
        $a=$folders[$i].Path+'\'; $b=$folders[$j].Path+'\'
        if($a.StartsWith($b,[StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a,[StringComparison]::OrdinalIgnoreCase)) { return "$($folders[$i].Why) and $($folders[$j].Why) overlap; every route folder must be separate." }
    } }
    $null
}

function Grant-NSPScanBridgeRouteSite {
    # Plan, then on confirm grant, write for the ingestion app on the site behind every route.
    param([Parameter(Mandatory)][object[]]$Routes,[Parameter(Mandatory)][string]$ClientId,[Parameter(Mandatory)][string]$DisplayName,[bool]$DryRun)
    $sites=@($Routes | ForEach-Object { (Find-NSPGraphSite -DriveId $_.DriveId).SiteId } | Select-Object -Unique)
    foreach($siteId in $sites) {
        $grant=Grant-NSPGraphSitePermission -SiteId $siteId -ClientId $ClientId -DisplayName $DisplayName
        Write-NSPConsoleLine ("Site {0}: {1}" -f $siteId,$grant.Message)
        if($grant.Status -eq 'PlanOnly' -and -not $DryRun -and (Read-NSPConfirm -Prompt "Give '$DisplayName' write access to this site only?" -DefaultYes)) {
            $grant=Grant-NSPGraphSitePermission -SiteId $siteId -ClientId $ClientId -DisplayName $DisplayName -Execute -Confirm:$false
            Write-NSPConsoleLine $grant.Message -Role Success
        }
    }
}

function Write-NSPScanBridgeSettingsEntry {
    # Preview, confirm, write with backup; DRY RUN previews only. Returns $true when written.
    param([Parameter(Mandatory)][string]$ConfigurationPath,[Parameter(Mandatory)][string]$Key,[Parameter(Mandatory)][object]$Value,[bool]$DryRun)
    $preview=Set-NSPPsd1TopLevelEntry -Path $ConfigurationPath -Key $Key -Value $Value -WhatIf
    Write-NSPConsoleLine "Current ${Key}:" -Role Muted
    Write-Host $(if($preview.OldText){$preview.OldText}else{'(none)'})
    Write-NSPConsoleLine "New ${Key}:" -Role Muted
    Write-Host $preview.NewText
    if($DryRun) { Write-NSPConsoleLine 'DRY RUN: settings file not changed.' -Role Warning; return $false }
    if(-not (Read-NSPConfirm -Prompt "Write this $Key to $ConfigurationPath (a backup is kept)?")) { return $false }
    $written=Set-NSPPsd1TopLevelEntry -Path $ConfigurationPath -Key $Key -Value $Value -Confirm:$false
    Write-NSPConsoleLine "Settings updated; backup at $($written.BackupPath)." -Role Success
    $true
}

function Connect-NSPScanBridgeAdmin {
    # Delegated admin sign-in with the step's scopes; refuses a tenant other than the settings' ingestion tenant.
    param([Parameter(Mandatory)][string[]]$Scopes,[Parameter(Mandatory)][Collections.IDictionary]$Config)
    $method=Read-NSPMenu -Prompt 'Sign in to the tenant as an administrator' -CancelLabel 'Back' -Choices @(
        [pscustomobject]@{Label='Windows sign-in';Value='Broker';Help='Account picker / browser prompt. It can open behind other windows.'}
        [pscustomobject]@{Label='Device code';Value='DeviceCode';Help='Enter a code at microsoft.com/devicelogin from any browser; best over remote sessions.'}
    )
    if($null -eq $method) { return $null }
    $connect=@{Scopes=$Scopes;Connect=$true}
    if($method -eq 'DeviceCode') { $connect.UseDeviceCode=$true }
    $context=Connect-NSPGraph @connect
    $tenant=if($Config.Auth -is [Collections.IDictionary]){[string]$Config.Auth.TenantId}else{''}
    if(-not (Test-NSPPlaceholderValue $tenant) -and $tenant -ne $context.TenantId) {
        throw "Signed in to tenant $($context.TenantId), but these settings use tenant $tenant. Sign in to the settings' tenant."
    }
    Write-NSPConsoleLine ('Signed in as {0} to tenant {1}.' -f $context.Account,$context.TenantId) -Role Muted
    $context
}

function Select-NSPScanBridgeRoute {
    param([Parameter(Mandatory)][object[]]$Routes,[Parameter(Mandatory)][string]$Prompt)
    if($Routes.Count -eq 1) { return 0 }
    $choices=@(for($i=0;$i -lt $Routes.Count;$i++) {
        $route=$Routes[$i]
        $dest=if(Test-NSPPlaceholderValue $route.DriveId){'no destination yet'}else{'destination set'}
        [pscustomobject]@{Label=('{0} ({1})' -f $route.Name,$route.Source);Value=$i;Help=$dest}
    })
    Read-NSPMenu -Choices $choices -Prompt $Prompt -CancelLabel 'Back'
}

function Read-NSPScanBridgeDestinationFolder {
    # Browse a library: pick a subfolder to open, use the current folder, go up, or create a folder.
    param([Parameter(Mandatory)][string]$DriveId,[Parameter(Mandatory)][string]$LibraryName,[bool]$DryRun)
    $trail=[System.Collections.Generic.List[object]]::new()
    $trail.Add([pscustomobject]@{Name=$LibraryName;ItemId='root'})
    while($true) {
        $here=$trail[$trail.Count-1]
        $path=($trail | ForEach-Object Name) -join ' / '
        $folders=@(Get-NSPGraphDriveFolder -DriveId $DriveId -ItemId $here.ItemId)
        $choices=@(foreach($folder in $folders) { [pscustomobject]@{Label="$($folder.Name) /";Value=$folder;Help="Open this folder ($($folder.ChildCount) items)."} })
        $choices+=[pscustomobject]@{Key='U';Label="Use this folder: $path";Value='Use';Help='Scans from this route upload here.'}
        if($trail.Count -gt 1) { $choices+=[pscustomobject]@{Key='P';Label='Up one level';Value='Up';Help='Back to the parent folder.'} }
        $choices+=[pscustomobject]@{Key='N';Label='New folder here';Value='New';Help="Create a folder inside $path (fails rather than renaming if the name exists)."}
        $pick=Read-NSPMenu -Choices $choices -Prompt "Destination folder ($path)" -CancelLabel 'Back'
        if($null -eq $pick) { return $null }
        if($pick -eq 'Use') { return [pscustomobject]@{DriveId=$DriveId;ItemId=$here.ItemId;Path=$path} }
        if($pick -eq 'Up') { $trail.RemoveAt($trail.Count-1); continue }
        if($pick -eq 'New') {
            $name=(Read-NSPNonEmpty -Prompt 'New folder name').Trim()
            if($DryRun) { Write-NSPConsoleLine "DRY RUN: would create '$name' in $path." -Role Warning; continue }
            if(-not (Read-NSPConfirm -Prompt "Create '$name' in $path?" -DefaultYes)) { continue }
            $created=New-NSPGraphDriveFolder -DriveId $DriveId -ParentId $here.ItemId -Name $name -Confirm:$false
            $trail.Add([pscustomobject]@{Name=$created.Name;ItemId=$created.ItemId})
            continue
        }
        $trail.Add([pscustomobject]@{Name=$pick.Name;ItemId=$pick.ItemId})
    }
}

function Invoke-NSPScanBridgeDestinationSetup {
    <#
        Sets one route's SharePoint destination (DriveId and FolderItemId) from a site search and
        folder browser, or a pasted link. Read-only Graph calls except an optional new folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigurationPath,[string]$RouteName)
    Import-NSPToolkitModule -Name NSP.M365.Graph -MinimumVersion 0.1.3
    $dryRun=[bool](Get-NSPDryRun)
    $config=Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    $routes=@($config.Routes | Where-Object { $_ })
    if(-not $routes.Count) { throw 'The settings file has no Routes.' }
    $index=if($RouteName) { @(for($i=0;$i -lt $routes.Count;$i++) { if($routes[$i].Name -eq $RouteName) { $i } })[0] } else { Select-NSPScanBridgeRoute -Routes $routes -Prompt 'Which route gets a destination?' }
    if($null -eq $index) { return }
    $answers=Get-NSPScanBridgeAnswerTable
    $context=Connect-NSPScanBridgeAdmin -Scopes @('Sites.ReadWrite.All') -Config $config
    if(-not $context) { return }
    $how=Read-NSPMenu -Prompt 'How should the destination be found?' -CancelLabel 'Back' -Choices @(
        [pscustomobject]@{Label='Search sites by name';Value='Search';Help='Pick the site, then its document library, then browse to the folder (or create one).'}
        [pscustomobject]@{Label='Paste a SharePoint folder link';Value='Link';Help='The folder URL from the browser address bar or Copy link.'}
    )
    if($null -eq $how) { return }
    $destination=$null
    if($how -eq 'Link') {
        $hit=Find-NSPGraphSite -Url (Read-NSPNonEmpty -Prompt 'SharePoint folder link').Trim()
        if(-not $hit.IsFolder) { Write-NSPConsoleLine 'That link is a file, not a folder. Paste the folder link.' -Role Error; return }
        $destination=[pscustomobject]@{DriveId=$hit.DriveId;ItemId=$hit.ItemId;Path=$hit.WebUrl}
    } else {
        $term=Read-NSPOptional -Prompt 'Site name to search for' -Default $(if($answers.SiteSearch){[string]$answers.SiteSearch}else{'Scan'})
        $sites=@(Find-NSPGraphSite -Search $term)
        if(-not $sites.Count) { Write-NSPConsoleLine "No sites match '$term'." -Role Warning; return }
        $site=Read-NSPMenu -Prompt 'Which site?' -CancelLabel 'Back' -Choices @($sites | ForEach-Object { [pscustomobject]@{Label=$_.DisplayName;Value=$_;Help=$_.WebUrl} })
        if($null -eq $site) { return }
        $libraries=@(Get-NSPGraphDriveFolder -SiteId $site.SiteId)
        if(-not $libraries.Count) { Write-NSPConsoleLine 'That site has no document libraries.' -Role Warning; return }
        $library=Read-NSPMenu -Prompt 'Which document library?' -CancelLabel 'Back' -Choices @($libraries | ForEach-Object { [pscustomobject]@{Label=$_.Name;Value=$_;Help=$_.WebUrl} })
        if($null -eq $library) { return }
        $destination=Read-NSPScanBridgeDestinationFolder -DriveId $library.DriveId -LibraryName "$($site.DisplayName) / $($library.Name)" -DryRun $dryRun
        if($null -eq $destination) { return }
        Save-NSPScanBridgeAnswer @{SiteSearch=$term}
    }
    Write-NSPConsoleLine ("Route '{0}' uploads to {1}." -f $routes[$index].Name,$destination.Path)
    $updated=@(for($i=0;$i -lt $routes.Count;$i++) {
        $route=ConvertTo-NSPScanBridgeOrderedRoute -Route $routes[$i]
        if($i -eq $index) { $route['DriveId']=$destination.DriveId; $route['FolderItemId']=$destination.ItemId }
        $route
    })
    Write-NSPScanBridgeSettingsEntry -ConfigurationPath $ConfigurationPath -Key Routes -Value $updated -DryRun $dryRun | Out-Null
}

function Invoke-NSPScanBridgeIngestionSetup {
    <#
        Creates or repairs the dedicated ingestion app (Sites.Selected only), places its
        certificate for the task account, grants it write on the site behind every route, and
        writes the settings' Auth block.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    Import-NSPToolkitModule -Name NSP.M365.Graph -MinimumVersion 0.1.3
    $dryRun=[bool](Get-NSPDryRun)
    $config=Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    $routes=@($config.Routes | Where-Object { $_ })
    $missing=@($routes | Where-Object { (Test-NSPPlaceholderValue $_.DriveId) -or (Test-NSPPlaceholderValue $_.FolderItemId) })
    if(-not $routes.Count -or $missing.Count) { Write-NSPConsoleLine "Set each route's SharePoint destination first ('Pick the SharePoint destination')." -Role Error; return }
    $answers=Get-NSPScanBridgeAnswerTable
    $context=Connect-NSPScanBridgeAdmin -Scopes @('Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Organization.Read.All','Sites.FullControl.All') -Config $config
    if(-not $context) { return }

    $appName=Read-NSPOptional -Prompt 'Ingestion app name' -Default $(if($answers.IngestAppName){[string]$answers.IngestAppName}else{'NSP-ScanBridge-Ingest'})
    $recordDirectory=Read-NSPOptional -Prompt 'Folder for the ingestion app record (client ID and thumbprint, never a key)' -Default (Join-Path (Split-Path -Parent $ConfigurationPath) 'IngestApp')
    $target=Read-NSPScanBridgeCertificateTarget -Purpose 'ingestion' -Answers $answers -DryRun $dryRun
    if($null -eq $target) { return }
    $register=@{AppName=$appName;ApplicationPermissions=@('Sites.Selected');RecordDirectory=$recordDirectory;CertificateStore=$target.Store;TenantId=$context.TenantId}
    $app=Register-NSPGraphAppOnlyRegistration @register
    if($app.Status -eq 'ExistingUnrecorded') { Write-NSPConsoleLine $app.Message -Role Error; return }
    if($app.Status -eq 'PlanOnly') {
        Write-NSPConsoleLine ("Ingestion app plan: {0}. Permission: Sites.Selected only (no site until granted below)." -f ($app.Actions -join ', '))
        if($target.ServiceAccount) { Write-NSPConsoleLine "Then: read access to the new certificate's private key for $($target.ServiceAccount) only." }
        if($dryRun) { Write-NSPConsoleLine 'DRY RUN: no app, certificate, key access or site grant created; Auth is unchanged.' -Role Warning; return }
        if(-not (Read-NSPConfirm -Prompt "Create or repair '$appName' in tenant $($context.TenantId) now?")) { return }
        $app=Register-NSPGraphAppOnlyRegistration @register -Execute -Confirm:$false
    }
    $record=Get-Content -LiteralPath $app.RecordPath -Raw | ConvertFrom-Json
    Save-NSPScanBridgeAnswer @{IngestAppName=$appName}
    if($target.ServiceAccount) { Grant-NSPScanBridgeCertificateKey -ServiceAccount $target.ServiceAccount -Thumbprint $record.CertificateThumbprint -Purpose 'ingestion' -Answers $answers -DryRun $dryRun }

    # Sites.Selected reaches nothing until each route's site names the app.
    Grant-NSPScanBridgeRouteSite -Routes $routes -ClientId $record.ClientId -DisplayName $appName -DryRun $dryRun

    $current=if($config.Auth -is [Collections.IDictionary]){$config.Auth}else{@{}}
    if(-not (Test-NSPPlaceholderValue $current.ClientId) -and [string]$current.ClientId -ne [string]$record.ClientId) {
        Write-NSPConsoleLine 'The settings name a different ingestion app. Existing receipts bound to it will be held for review after the change.' -Role Warning
    }
    $auth=[ordered]@{TenantId=[string]$record.TenantId;ClientId=[string]$record.ClientId;CertificateThumbprint=[string]$record.CertificateThumbprint}
    foreach($key in @($current.Keys | Where-Object { $_ -notin $auth.Keys } | Sort-Object)) { $auth[$key]=$current[$key] }
    Write-NSPScanBridgeSettingsEntry -ConfigurationPath $ConfigurationPath -Key Auth -Value $auth -DryRun $dryRun | Out-Null
}

function Invoke-NSPScanBridgeFolderSetup {
    <#
        Creates the route Source/Spool/Archive folders, the lock folder and the alert state folder
        when missing, and grants the task account Modify on each (Read on the settings file).
        Applies ScanBridge's own folder rules first: distinct, non-overlapping, Source and Spool
        on one drive.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    Import-NSPToolkitModule -Name NSP.Win.LocalAccount -MinimumVersion 0.1.0
    $dryRun=[bool](Get-NSPDryRun)
    if(-not $dryRun -and -not (Test-NSPScanBridgeElevated)) { Write-NSPConsoleLine 'Creating folders and granting access needs an elevated session. Restart PowerShell as administrator.' -Role Error; return }
    $config=Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    $routes=@($config.Routes | Where-Object { $_ })
    $full={ param($p) [IO.Path]::GetFullPath([string]$p).TrimEnd('\') }
    $problem=Test-NSPScanBridgeRouteFolderRule -Routes $routes
    if($problem) { Write-NSPConsoleLine $problem -Role Error; return }
    $folders=[System.Collections.Generic.List[object]]::new()
    foreach($route in $routes) { foreach($kind in 'Source','Spool','Archive') { $folders.Add([pscustomobject]@{Path=(& $full $route[$kind]);Why="$($route.Name) $kind";Route=$route.Name}) } }
    if(-not (Test-NSPPlaceholderValue $config.LockPath)) { $folders.Add([pscustomobject]@{Path=(Split-Path -Parent (& $full $config.LockPath));Why='worker lock folder';Route=$null}) }
    if($config.Alerts -is [Collections.IDictionary] -and -not (Test-NSPPlaceholderValue $config.Alerts.StateDirectory)) { $folders.Add([pscustomobject]@{Path=(& $full $config.Alerts.StateDirectory);Why='alert state folder';Route=$null}) }

    $answers=Get-NSPScanBridgeAnswerTable
    $typed=Read-NSPNonEmpty -Prompt 'Local account the ScanBridge task runs as (.\name)' -CurrentValue $(if($answers.ServiceAccount){'.\'+[string]$answers.ServiceAccount}else{''})
    $account=ConvertTo-NSPLocalAccountName -Account $typed
    if(-not $account) { Write-NSPConsoleLine "'$typed' is not a local account name on this computer (use .\name)." -Role Error; return }
    if(-not (Get-NSPLocalServiceAccount -Name $account)) { Write-NSPConsoleLine "Local account '$account' does not exist. Create it with 'Prepare a local service account' first." -Role Error; return }

    Write-NSPConsoleLine "Folder plan for ${account}:"
    foreach($folder in $folders) { Write-NSPConsoleLine ("  - {0}{1}: Modify ({2})" -f $folder.Path,$(if(Test-Path -LiteralPath $folder.Path -PathType Container){''}else{' [create]'}),$folder.Why) }
    Write-NSPConsoleLine "  - $ConfigurationPath : Read (settings)"
    if($dryRun) { Write-NSPConsoleLine 'DRY RUN: no folders created or access granted.' -Role Warning; return }
    if(-not (Read-NSPConfirm -Prompt "Create the missing folders and grant $account this access?")) { return }
    foreach($folder in $folders) {
        if(-not (Test-Path -LiteralPath $folder.Path -PathType Container)) { New-Item -ItemType Directory -Path $folder.Path -Force | Out-Null }
        $grant=Grant-NSPLocalAccountPathAccess -Name $account -LiteralPath $folder.Path -Rights Modify -Execute -Confirm:$false
        Write-NSPConsoleLine ("{0}: {1}" -f $folder.Path,$grant.Status) -Role $(if($grant.Status -eq 'Granted'){'Success'}else{'Warning'})
    }
    $grant=Grant-NSPLocalAccountPathAccess -Name $account -LiteralPath $ConfigurationPath -Rights Read -Execute -Confirm:$false
    Write-NSPConsoleLine ("{0}: {1}" -f $ConfigurationPath,$grant.Status) -Role $(if($grant.Status -eq 'Granted'){'Success'}else{'Warning'})
    Save-NSPScanBridgeAnswer @{ServiceAccount=$account}
    Write-NSPConsoleLine 'Direct grants do not prove effective access: the task account''s first run does.' -Role Muted
}

function Invoke-NSPScanBridgeSiteGrantSetup {
    <#
        Grants the configured ingestion app (Auth.ClientId) write on the site behind every route,
        for example after adding a route in another site. Already-granted sites are left alone.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    Import-NSPToolkitModule -Name NSP.M365.Graph -MinimumVersion 0.1.3
    $dryRun=[bool](Get-NSPDryRun)
    $config=Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    $routes=@($config.Routes | Where-Object { $_ -and -not (Test-NSPPlaceholderValue $_.DriveId) })
    if(-not $routes.Count) { Write-NSPConsoleLine "No route has a SharePoint destination yet ('Pick the SharePoint destination')." -Role Error; return }
    $clientId=if($config.Auth -is [Collections.IDictionary]){[string]$config.Auth.ClientId}else{''}
    if(Test-NSPPlaceholderValue $clientId) { Write-NSPConsoleLine "The settings have no ingestion app yet ('Create the ingestion app and site access')." -Role Error; return }
    $answers=Get-NSPScanBridgeAnswerTable
    $context=Connect-NSPScanBridgeAdmin -Scopes @('Sites.FullControl.All') -Config $config
    if(-not $context) { return }
    Grant-NSPScanBridgeRouteSite -Routes $routes -ClientId $clientId -DisplayName $(if($answers.IngestAppName){[string]$answers.IngestAppName}else{'NSP-ScanBridge-Ingest'}) -DryRun $dryRun
}

function Test-NSPScanBridgeRouteName {
    # Short generic names: they appear in dispatch tickets. Returns a message, or $null when fine.
    param([AllowEmptyString()][string]$Name,[object[]]$Routes,[string]$Except)
    if($Name -notmatch '^[A-Za-z][A-Za-z0-9-]{0,31}$') { return 'Use 1-32 letters, digits or dashes, starting with a letter (for example FrontDesk or Scanner2).' }
    if($Name -in @('System','Worker')) { return "'$Name' is reserved for ScanBridge's own alerts." }
    if(@($Routes | Where-Object { $_.Name -ieq $Name -and $_.Name -ne $Except }).Count) { return "A route named '$Name' already exists." }
    $null
}

function Get-NSPScanBridgeRouteBacklog {
    # Files still in a route's Spool (claimed jobs and receipts) or PDFs waiting in its Source.
    param([Parameter(Mandatory)][Collections.IDictionary]$Route)
    $spool=if(-not (Test-NSPPlaceholderValue $Route.Spool) -and (Test-Path -LiteralPath $Route.Spool -PathType Container)) { @(Get-ChildItem -LiteralPath $Route.Spool -File -Recurse -Force -ErrorAction SilentlyContinue).Count } else { 0 }
    $source=if(-not (Test-NSPPlaceholderValue $Route.Source) -and (Test-Path -LiteralPath $Route.Source -PathType Container)) { @(Get-ChildItem -LiteralPath $Route.Source -File -Filter '*.pdf' -Force -ErrorAction SilentlyContinue).Count } else { 0 }
    [pscustomobject]@{Spool=$spool;Source=$source;Busy=($spool+$source) -gt 0}
}

function Invoke-NSPScanBridgeRouteManager {
    <#
        Lists the routes; adds one (Source picked, Spool/Archive derived per route), renames one,
        changes its readiness age, or removes one. Rename and remove are refused while the route
        has jobs. After adding, offers each dependent step: folders and access, SharePoint
        destination, site access, Sysmon update.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    $dryRun=[bool](Get-NSPDryRun)
    $config=Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    $routes=@($config.Routes | Where-Object { $_ } | ForEach-Object { ConvertTo-NSPScanBridgeOrderedRoute -Route $_ })
    $choices=@(for($i=0;$i -lt $routes.Count;$i++) {
        $route=$routes[$i]
        $dest=if(Test-NSPPlaceholderValue $route.DriveId){'no SharePoint destination yet'}else{'destination set'}
        $age=if($route.MinimumAgeSeconds){$route.MinimumAgeSeconds}else{20}
        [pscustomobject]@{Label=('{0}: {1}' -f $route.Name,$route.Source);Value=$i;Help="$dest; age $age s. Open to rename, change age or remove."}
    })
    $choices+=[pscustomobject]@{Key='A';Label='Add a route';Value='Add';Help='Pick the Source folder; Spool and Archive are proposed per route on the same drive.'}
    $pick=Read-NSPMenu -Choices $choices -Prompt 'Routes' -CancelLabel 'Back'
    if($null -eq $pick) { return }

    if($pick -eq 'Add') {
        Write-NSPConsoleLine 'Route names appear in dispatch tickets: keep them generic (no patient, person or document names).' -Role Muted
        do {
            $name=(Read-NSPNonEmpty -Prompt 'Route name').Trim()
            $problem=Test-NSPScanBridgeRouteName -Name $name -Routes $routes
            if($problem) { Write-NSPConsoleLine $problem -Role Warning }
        } while($problem)
        $folderArgs=@{Prompt='Source folder (where the scanner saves)'}
        if(-not $dryRun) { $folderArgs.Create=$true }
        $source=Read-NSPFolderPath @folderArgs
        $drive=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($source))
        $spool=Read-NSPOptional -Prompt 'Spool folder' -Default (Join-Path $drive "ScanBridge\$name\Spool")
        $archive=Read-NSPOptional -Prompt 'Archive folder' -Default (Join-Path $drive "ScanBridge\$name\Archive")
        $new=[ordered]@{Name=$name;Source=$source;Spool=$spool;Archive=$archive;DriveId='<drive-id>';FolderItemId='<folder-id>';MinimumAgeSeconds=20;VerifyRemoteAfterUpload=$false}
        $problem=Test-NSPScanBridgeRouteFolderRule -Routes (@($routes)+@($new))
        if($problem) { Write-NSPConsoleLine $problem -Role Error; return }
        if(-not (Write-NSPScanBridgeSettingsEntry -ConfigurationPath $ConfigurationPath -Key Routes -Value (@($routes)+@($new)) -DryRun $dryRun)) { return }
        $steps=@(
            @{Prompt="Next: create '$name' folders and grant the task account access?";Run={ Invoke-NSPScanBridgeFolderSetup -ConfigurationPath $ConfigurationPath }}
            @{Prompt="Next: pick the SharePoint destination for '$name'?";Run={ Invoke-NSPScanBridgeDestinationSetup -ConfigurationPath $ConfigurationPath -RouteName $name }}
            @{Prompt='Next: grant the ingestion app access to that site (skipped if it already has it)?';Run={ Invoke-NSPScanBridgeSiteGrantSetup -ConfigurationPath $ConfigurationPath }}
            @{Prompt='Next: update the Sysmon scan trigger to watch the new Source?';Run={ Invoke-NSPScanBridgeSysmonSetup -ConfigurationPath $ConfigurationPath | Out-Null }}
        )
        foreach($step in $steps) {
            if(-not (Read-NSPConfirm -Prompt $step.Prompt -DefaultYes)) { continue }
            try { & $step.Run } catch { Write-NSPConsoleLine $_.Exception.Message -Role Error }
        }
        return
    }

    $route=$routes[$pick]
    $age=if($route.MinimumAgeSeconds){$route.MinimumAgeSeconds}else{20}
    $action=Read-NSPMenu -Prompt "Route '$($route.Name)'" -CancelLabel 'Back' -Choices @(
        [pscustomobject]@{Label='Rename';Value='Rename';Help='Refused while the route has jobs: receipts are bound to the route name.'}
        [pscustomobject]@{Label='Change readiness age';Value='Age';Help="Seconds a PDF must be unchanged before upload (now $age)."}
        [pscustomobject]@{Label='Remove';Value='Remove';Help='Refused while the route has jobs or waiting PDFs. Folders and SharePoint content are left as they are.'}
    )
    if($null -eq $action) { return }
    if($action -in 'Rename','Remove') {
        $backlog=Get-NSPScanBridgeRouteBacklog -Route $route
        if($backlog.Busy) { Write-NSPConsoleLine ("Route '{0}' still has {1} file(s) in Spool and {2} PDF(s) waiting in Source. Let them finish (see 'Inspect ScanBridge configuration health') first." -f $route.Name,$backlog.Spool,$backlog.Source) -Role Error; return }
    }
    if($action -eq 'Rename') {
        do {
            $name=(Read-NSPNonEmpty -Prompt 'New route name').Trim()
            $problem=Test-NSPScanBridgeRouteName -Name $name -Routes $routes -Except $route.Name
            if($problem) { Write-NSPConsoleLine $problem -Role Warning }
        } while($problem)
        $route['Name']=$name
    } elseif($action -eq 'Age') {
        do { $typed=(Read-NSPNonEmpty -Prompt 'Readiness age in seconds (1-3600)').Trim() } until($typed -match '^\d{1,4}$' -and [int]$typed -ge 1 -and [int]$typed -le 3600)
        $route['MinimumAgeSeconds']=[int]$typed
        Write-NSPConsoleLine 'A Sysmon-triggered task waits the largest route age + 30 s; re-plan the task if this route is now the slowest.' -Role Muted
    } else {
        if($routes.Count -eq 1) { Write-NSPConsoleLine 'ScanBridge needs at least one route; add another before removing this one.' -Role Error; return }
        $routes=@($routes | Where-Object { $_.Name -ne $route.Name })
    }
    if((Write-NSPScanBridgeSettingsEntry -ConfigurationPath $ConfigurationPath -Key Routes -Value $routes -DryRun $dryRun) -and $action -eq 'Remove' -and (Read-NSPConfirm -Prompt 'Update the Sysmon scan trigger to stop watching that Source?' -DefaultYes)) {
        try { Invoke-NSPScanBridgeSysmonSetup -ConfigurationPath $ConfigurationPath | Out-Null } catch { Write-NSPConsoleLine $_.Exception.Message -Role Error }
    }
}
