[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','',Justification='State is read by the shadowed commands.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess','',Justification='Shadowed commands mirror the real signatures and record calls instead of changing anything.')]
[CmdletBinding()]
param([string]$SourceRoot)
$ErrorActionPreference='Stop'
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
foreach($file in 'ScanBridgeAlertSetup.ps1','ScanBridgeSetupPrompts.ps1','ScanBridgeRouteSetup.ps1') { . (Join-Path $SourceRoot "Private/$file") }
$state=@{Checks=0}
function Check($condition,$message) {if(-not $condition){throw $message};$state.Checks++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('nsp-toolkit-route-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$tenant='aaaaaaaa-0000-0000-0000-000000000001'
function New-Settings {
    param([string]$AuthTenant='<tenant-guid>',[string]$RouteA="Source='$root\scanA'; Spool='$root\spoolA'; Archive='$root\archiveA'",[string]$RouteB="Source='$root\scanB'; Spool='$root\spoolB'; Archive='$root\archiveB'",[string]$Dest="DriveId='<drive-id>'; FolderItemId='<folder-id>'")
    $path=Join-Path $root ('settings-'+[guid]::NewGuid().ToString('N')+'.psd1')
    $text=@"
@{
  # private settings
  LockPath = '$root\lock\worker.lock'
  Auth = @{
    TenantId = '$AuthTenant'
    ClientId = '<app-guid>'
    CertificateThumbprint = '<thumbprint>'
  }
  Alerts = @{
    Enabled = `$false
    StateDirectory = '$root\alertstate'
  }
  Routes = @(
    @{ Name = 'RouteA'; $RouteA; $Dest; MinimumAgeSeconds = 20 }
    @{ Name = 'RouteB'; $RouteB; $Dest; Custom = 'kept' }
  )
}
"@
    [IO.File]::WriteAllText($path,$text.Replace("`r`n","`n").Replace("`n","`r`n"))
    $path
}
try {
    function Import-NSPToolkitModule { param($Name,$MinimumVersion) }
    function Get-NSPDryRun { $state.DryRun }
    function Test-NSPScanBridgeElevated { $true }
    function Get-NSPToolAnswers { param($Tool) $state.Answers }
    function Save-NSPToolAnswers { [CmdletBinding(SupportsShouldProcess)] param($Tool,$Answers) $state.Saved+=,([pscustomobject]$Answers); $state.Answers=[pscustomobject]$Answers }
    function Write-NSPConsoleLine { param($Text,$Role) if($Role -eq 'Error'){$state.Errors+=,$Text} }
    function Write-Host { param($Object) }
    function Read-NSPConfirm { param($Prompt,[switch]$DefaultYes) $state.Confirms+=,$Prompt; $true }
    function Read-NSPOptional { param($Prompt,$Default) $Default }
    function Read-NSPNonEmpty { param($Prompt,$CurrentValue) if(@($state.Typed).Count){$n=$state.Typed[0];$state.Typed=@($state.Typed|Select-Object -Skip 1);return $n}; $CurrentValue }
    function Read-NSPMenu {
        param($Choices,$Prompt,$CancelLabel)
        $state.Menus+=,$Prompt
        $next=$state.Menu[0]; $state.Menu=@($state.Menu | Select-Object -Skip 1)
        if($next -is [int]) { return @($Choices)[$next].Value }
        if($next -is [scriptblock]) { return (& $next $Choices) }
        @($Choices | Where-Object { $_.Value -eq $next })[0].Value
    }
    function Connect-NSPGraph { param($Scopes,[switch]$Connect,[switch]$UseDeviceCode) $state.Scopes=$Scopes; [pscustomobject]@{TenantId=$state.Tenant;Account='admin@contoso.example'} }
    function Find-NSPGraphSite {
        param($Search,$Url,$DriveId)
        if($Search) { return @([pscustomobject]@{SiteId='host,sc1,web1';DisplayName='Scans Test';WebUrl='https://contoso.sharepoint.com/sites/scans'}) }
        if($Url) { return $state.LinkHit }
        [pscustomobject]@{SiteId=$(if($DriveId -eq 'drive-2'){'host,sc2,web2'}else{'host,sc1,web1'});DriveId=$DriveId}
    }
    function Get-NSPGraphDriveFolder {
        param($SiteId,$DriveId,$ItemId='root')
        if($SiteId) { return @([pscustomobject]@{Kind='Library';Name='Documents';DriveId='drive-1';ItemId='root'}) }
        if($ItemId -eq 'root') { return @([pscustomobject]@{Kind='Folder';Name='Inbox';DriveId=$DriveId;ItemId='inbox-1';ChildCount=0}) }
        @()
    }
    function New-NSPGraphDriveFolder { [CmdletBinding(SupportsShouldProcess)] param($DriveId,$ParentId,$Name) $state.Created+=,"$ParentId/$Name"; [pscustomobject]@{Name=$Name;DriveId=$DriveId;ItemId='new-folder-1'} }
    function Register-NSPGraphAppOnlyRegistration {
        [CmdletBinding(SupportsShouldProcess)] param($AppName,$ApplicationPermissions,$RecordDirectory,$CertificateStore,$TenantId,[switch]$Execute)
        $state.Register+=,[pscustomobject]@{Permissions=@($ApplicationPermissions);Execute=[bool]$Execute;Store=$CertificateStore;AppName=$AppName}
        $recordPath=Join-Path $RecordDirectory "$TenantId.json"
        if(-not $Execute) { return [pscustomobject]@{Status='PlanOnly';Actions=@('CreateApplication');RecordPath=$recordPath} }
        New-Item -ItemType Directory -Path $RecordDirectory -Force | Out-Null
        @{TenantId=$TenantId;ClientId='bbbbbbbb-0000-0000-0000-000000000002';ServicePrincipalId='sp';CertificateThumbprint='THUMB'} | ConvertTo-Json | Set-Content -LiteralPath $recordPath
        [pscustomobject]@{Status='Created';RecordPath=$recordPath}
    }
    function Get-NSPLocalServiceAccount { param($Name) if($Name -eq 'ScanBridge'){[pscustomobject]@{Name=$Name;Account="PC\$Name"}} }
    function Grant-NSPLocalAccountCertificateAccess { [CmdletBinding(SupportsShouldProcess)] param($Name,$Thumbprint,[switch]$Execute) $state.KeyGrants+=,[bool]$Execute; [pscustomobject]@{Status=$(if($Execute){'Granted'}else{'PlanOnly'});Account="PC\$Name";Rights='Read'} }
    function Grant-NSPGraphSitePermission { [CmdletBinding(SupportsShouldProcess)] param($SiteId,$ClientId,$DisplayName,[switch]$Execute) $state.SiteGrants+=,"$SiteId|$([bool]$Execute)"; [pscustomobject]@{Status=$(if($Execute){'Granted'}else{'PlanOnly'});Message='plan'} }
    function Grant-NSPLocalAccountPathAccess { [CmdletBinding(SupportsShouldProcess)] param($Name,$LiteralPath,$Rights,[switch]$Execute) $state.PathGrants+=,"$Rights|$LiteralPath"; [pscustomobject]@{Status='Granted'} }
    function Reset-Flow {
        param([switch]$DryRun)
        $state.DryRun=[bool]$DryRun; $state.Tenant=$tenant; $state.Answers=$null; $state.Saved=@(); $state.Errors=@(); $state.Confirms=@(); $state.Menus=@()
        $state.Menu=@(); $state.Typed=@(); $state.Created=@(); $state.Register=@(); $state.KeyGrants=@(); $state.SiteGrants=@(); $state.PathGrants=@(); $state.LinkHit=$null
    }

    # Routes writer: a list of tables round-trips with other settings intact.
    Reset-Flow
    $settings=New-Settings
    $config=Import-PowerShellDataFile -LiteralPath $settings
    $routes=@($config.Routes | ForEach-Object { $r=ConvertTo-NSPScanBridgeOrderedRoute -Route $_; $r.DriveId='d'; $r })
    Set-NSPPsd1TopLevelEntry -Path $settings -Key Routes -Value $routes -Confirm:$false | Out-Null
    $after=Import-PowerShellDataFile -LiteralPath $settings
    Check (@($after.Routes).Count -eq 2 -and $after.Routes[0].Name -eq 'RouteA' -and $after.Routes[1].Custom -eq 'kept' -and $after.Routes[0].DriveId -eq 'd' -and $after.Auth.ClientId -eq '<app-guid>' -and [IO.File]::ReadAllText($settings).Contains('# private settings')) 'Routes list did not round-trip with the rest intact.'
    Check ([IO.File]::ReadAllText($settings) -match "Routes = @\(\r\n    @\{\r\n      Name = 'RouteA'\r\n      Source") 'Routes were not laid out one table per block in route key order.'

    # Destination by search: site, library, open Inbox, create a subfolder, use it; only RouteB changes.
    Reset-Flow
    $settings=New-Settings
    $state.Menu=@(1,'Broker','Search',0,0,0,'New','Use'); $state.Typed=@('ScanBridge Test')
    Invoke-NSPScanBridgeDestinationSetup -ConfigurationPath $settings
    $after=Import-PowerShellDataFile -LiteralPath $settings
    Check ($state.Errors.Count -eq 0 -and $state.Created -contains 'inbox-1/ScanBridge Test') "Folder browse/create failed: $($state.Errors -join '; ')"
    Check ($after.Routes[1].DriveId -eq 'drive-1' -and $after.Routes[1].FolderItemId -eq 'new-folder-1' -and $after.Routes[0].DriveId -eq '<drive-id>') 'Only the chosen route should get the new destination.'
    Check ('Sites.ReadWrite.All' -in $state.Scopes) 'Destination sign-in scopes were wrong.'

    # Destination by link: a file is refused, a folder is used. DRY RUN writes nothing and creates nothing.
    Reset-Flow
    $settings=New-Settings
    $state.Menu=@(0,'Broker','Link'); $state.Typed=@('https://contoso.sharepoint.com/sites/s/doc.pdf')
    $state.LinkHit=[pscustomobject]@{SiteId='s';DriveId='drive-9';ItemId='file-9';IsFolder=$false;WebUrl='u'}
    $before=[IO.File]::ReadAllText($settings)
    Invoke-NSPScanBridgeDestinationSetup -ConfigurationPath $settings
    Check ($state.Errors.Count -eq 1 -and [IO.File]::ReadAllText($settings) -eq $before) 'A file link was not refused.'
    Reset-Flow
    $state.Menu=@(0,'Broker','Link'); $state.Typed=@('https://contoso.sharepoint.com/sites/s/folder')
    $state.LinkHit=[pscustomobject]@{SiteId='s';DriveId='drive-9';ItemId='folder-9';IsFolder=$true;WebUrl='u'}
    Invoke-NSPScanBridgeDestinationSetup -ConfigurationPath $settings
    Check ((Import-PowerShellDataFile -LiteralPath $settings).Routes[0].FolderItemId -eq 'folder-9') 'A folder link was not used for the chosen route.'
    Reset-Flow -DryRun
    $settings=New-Settings
    $before=[IO.File]::ReadAllText($settings)
    $state.Menu=@(0,'Broker','Search',0,0,'New','Use'); $state.Typed=@('X')
    Invoke-NSPScanBridgeDestinationSetup -ConfigurationPath $settings
    Check ([IO.File]::ReadAllText($settings) -eq $before -and $state.Created.Count -eq 0) 'DRY RUN changed settings or created a folder.'

    # Ingestion app: refused without destinations; then Sites.Selected app, key grant, one grant per site, Auth written.
    Reset-Flow
    Invoke-NSPScanBridgeIngestionSetup -ConfigurationPath (New-Settings)
    Check ($state.Errors.Count -eq 1 -and $state.Register.Count -eq 0) 'Ingestion setup ran without route destinations.'
    Reset-Flow
    $settings=New-Settings -Dest "DriveId='drive-1'; FolderItemId='f1'" -RouteB "Source='$root\scanB'; Spool='$root\spoolB'; Archive='$root\archiveB'; DriveId='drive-2'; FolderItemId='f2'"
    [IO.File]::WriteAllText($settings,[IO.File]::ReadAllText($settings).Replace("DriveId='drive-1'; FolderItemId='f1'; Custom","Custom"))
    $state.Menu=@('Broker','ServiceAccount'); $state.Typed=@('.\ScanBridge')
    Invoke-NSPScanBridgeIngestionSetup -ConfigurationPath $settings
    $after=Import-PowerShellDataFile -LiteralPath $settings
    Check ($state.Errors.Count -eq 0) "Ingestion setup reported errors: $($state.Errors -join '; ')"
    Check ($state.Register.Count -eq 2 -and ($state.Register[0].Permissions -join ',') -eq 'Sites.Selected' -and $state.Register[1].Execute -and $state.Register[1].Store -eq 'Cert:\LocalMachine\My' -and $state.Register[0].AppName -eq 'NSP-ScanBridge-Ingest') 'Ingestion app was not planned then created with Sites.Selected only, in the computer store.'
    Check ('Sites.FullControl.All' -in $state.Scopes -and ($state.KeyGrants -join ',') -eq 'False,True') 'Admin scopes or the key grant plan/execute were wrong.'
    Check (($state.SiteGrants | Sort-Object) -join ';' -eq 'host,sc1,web1|False;host,sc1,web1|True;host,sc2,web2|False;host,sc2,web2|True') "Each route's site should be planned then granted once: $($state.SiteGrants -join ';')"
    Check ($after.Auth.ClientId -eq 'bbbbbbbb-0000-0000-0000-000000000002' -and $after.Auth.TenantId -eq $tenant -and $after.Auth.CertificateThumbprint -eq 'THUMB' -and $after.Alerts.StateDirectory -eq "$root\alertstate") 'Auth was not written from the app record, or other settings changed.'
    Check (@($state.Saved | Where-Object { $_.IngestAppName -eq 'NSP-ScanBridge-Ingest' }).Count -ge 1) 'Ingestion app name was not remembered.'
    Reset-Flow; $state.Tenant='dddddddd-0000-0000-0000-000000000009'; $state.Menu=@('Broker')
    $threw=$false; try { Invoke-NSPScanBridgeIngestionSetup -ConfigurationPath (New-Settings -AuthTenant $tenant -Dest "DriveId='drive-1'; FolderItemId='f1'") } catch { $threw=$_.Exception.Message -match "settings' tenant" }
    Check ($threw -and $state.Register.Count -eq 0) 'A sign-in to another tenant was not refused.'
    Reset-Flow -DryRun
    $settings=New-Settings -Dest "DriveId='drive-1'; FolderItemId='f1'"; $before=[IO.File]::ReadAllText($settings)
    $state.Menu=@('Broker','ServiceAccount'); $state.Typed=@('.\ScanBridge')
    Invoke-NSPScanBridgeIngestionSetup -ConfigurationPath $settings
    Check ([IO.File]::ReadAllText($settings) -eq $before -and @($state.Register | Where-Object Execute).Count -eq 0 -and $state.SiteGrants.Count -eq 0) 'DRY RUN created the app, granted a site or wrote Auth.'

    # Folders: create missing folders, Modify for the account, Read on the settings; refuse overlap and split drives.
    Reset-Flow; $state.Typed=@('.\ScanBridge')
    $settings=New-Settings
    Invoke-NSPScanBridgeFolderSetup -ConfigurationPath $settings
    $expected=@('scanA','spoolA','archiveA','scanB','spoolB','archiveB','lock','alertstate') | ForEach-Object { "Modify|$root\$_" }
    Check ($state.Errors.Count -eq 0 -and @($expected | Where-Object { $_ -notin $state.PathGrants }).Count -eq 0 -and "Read|$settings" -in $state.PathGrants) "Folder grants were incomplete: $($state.PathGrants -join '; ')"
    Check (@(@('scanA','spoolB','lock','alertstate') | Where-Object { -not (Test-Path -LiteralPath "$root\$_" -PathType Container) }).Count -eq 0) 'Missing folders were not created.'
    Reset-Flow; $state.Typed=@('.\ScanBridge')
    Invoke-NSPScanBridgeFolderSetup -ConfigurationPath (New-Settings -RouteB "Source='$root\scanA\inner'; Spool='$root\spoolB'; Archive='$root\archiveB'")
    Check ($state.Errors.Count -eq 1 -and $state.PathGrants.Count -eq 0) 'Overlapping route folders were not refused.'
    Reset-Flow; $state.Typed=@('.\ScanBridge')
    Invoke-NSPScanBridgeFolderSetup -ConfigurationPath (New-Settings -RouteA "Source='$root\scanA'; Spool='Z:\spoolA'; Archive='$root\archiveA'")
    Check ($state.Errors.Count -eq 1 -and $state.PathGrants.Count -eq 0) 'Source and Spool on different drives were not refused.'
    Reset-Flow -DryRun; $state.Typed=@('.\ScanBridge')
    $dry=Join-Path $root 'dryrun'
    Invoke-NSPScanBridgeFolderSetup -ConfigurationPath (New-Settings -RouteA "Source='$dry\scan'; Spool='$dry\spool'; Archive='$dry\archive'")
    Check ($state.PathGrants.Count -eq 0 -and -not (Test-Path -LiteralPath $dry)) 'DRY RUN created folders or granted access.'
    Reset-Flow; $state.Typed=@('.\Nobody')
    Invoke-NSPScanBridgeFolderSetup -ConfigurationPath (New-Settings)
    Check ($state.Errors.Count -eq 1 -and $state.PathGrants.Count -eq 0) 'A missing task account was not refused.'

    # Site access for routes added later: needs a configured app; grants each route's site.
    Reset-Flow
    Invoke-NSPScanBridgeSiteGrantSetup -ConfigurationPath (New-Settings -Dest "DriveId='drive-1'; FolderItemId='f1'")
    Check ($state.Errors.Count -eq 1 -and $state.SiteGrants.Count -eq 0) 'Site grants ran without an ingestion app in Auth.'
    Reset-Flow; $state.Menu=@('Broker')
    $settings=New-Settings -Dest "DriveId='drive-1'; FolderItemId='f1'"
    [IO.File]::WriteAllText($settings,[IO.File]::ReadAllText($settings).Replace("ClientId = '<app-guid>'","ClientId = 'bbbbbbbb-0000-0000-0000-000000000002'"))
    Invoke-NSPScanBridgeSiteGrantSetup -ConfigurationPath $settings
    Check ($state.Errors.Count -eq 0 -and ($state.SiteGrants -join ';') -eq 'host,sc1,web1|False;host,sc1,web1|True' -and 'Sites.FullControl.All' -in $state.Scopes) "Site grant step did not plan then grant the route site once: $($state.SiteGrants -join ';')"

    # Route manager. The chained steps are shadowed here so each can be checked as offered and run.
    function Invoke-NSPScanBridgeFolderSetup { param($ConfigurationPath) $state.Chain+=,'Folders' }
    function Invoke-NSPScanBridgeDestinationSetup { param($ConfigurationPath,$RouteName) $state.Chain+=,"Destination:$RouteName" }
    function Invoke-NSPScanBridgeSiteGrantSetup { param($ConfigurationPath) $state.Chain+=,'SiteGrant' }
    function Invoke-NSPScanBridgeSysmonSetup { param($ConfigurationPath) $state.Chain+=,'Sysmon' }
    function Read-NSPFolderPath { param($Prompt,[switch]$Create) $state.FolderCreate=[bool]$Create; $state.FolderPick }
    function Reset-Manager { param([switch]$DryRun) Reset-Flow -DryRun:$DryRun; $state.Chain=@(); $state.FolderPick="$root\frontdesk"; $state.FolderCreate=$null }

    Reset-Manager; $state.Menu=@('Add'); $state.Typed=@('System','Route A','RouteA','FrontDesk')
    $settings=New-Settings
    Invoke-NSPScanBridgeRouteManager -ConfigurationPath $settings
    $after=Import-PowerShellDataFile -LiteralPath $settings
    $drive=[IO.Path]::GetPathRoot($root)
    $added=@($after.Routes | Where-Object Name -eq 'FrontDesk')[0]
    Check (@($after.Routes).Count -eq 3 -and $added.Source -eq "$root\frontdesk" -and $added.Spool -eq (Join-Path $drive 'ScanBridge\FrontDesk\Spool') -and $added.Archive -eq (Join-Path $drive 'ScanBridge\FrontDesk\Archive') -and $added.MinimumAgeSeconds -eq 20) 'Added route did not get derived Spool/Archive on the Source drive.'
    Check ($added.DriveId -eq '<drive-id>' -and $after.Routes[1].Custom -eq 'kept' -and $state.FolderCreate) 'Existing routes changed, or the Source prompt could not create the folder.'
    Check (($state.Chain -join ',') -eq 'Folders,Destination:FrontDesk,SiteGrant,Sysmon') "Dependent steps were not offered in order: $($state.Chain -join ',')"
    Check (@($state.Confirms | Where-Object { $_ -like 'Next:*' }).Count -eq 4) 'Each next step was not offered separately.'

    Reset-Manager; $state.Menu=@('Add'); $state.Typed=@('Dup'); $state.FolderPick="$root\scanA\inner"
    $settings=New-Settings; $before=[IO.File]::ReadAllText($settings)
    Invoke-NSPScanBridgeRouteManager -ConfigurationPath $settings
    Check ($state.Errors.Count -eq 1 -and [IO.File]::ReadAllText($settings) -eq $before -and $state.Chain.Count -eq 0) 'A route overlapping another route was saved.'
    Reset-Manager -DryRun; $state.Menu=@('Add'); $state.Typed=@('Lobby')
    $settings=New-Settings; $before=[IO.File]::ReadAllText($settings)
    Invoke-NSPScanBridgeRouteManager -ConfigurationPath $settings
    Check ([IO.File]::ReadAllText($settings) -eq $before -and -not $state.FolderCreate -and $state.Chain.Count -eq 0) 'DRY RUN wrote a route, offered to create its Source, or ran next steps.'

    Reset-Manager; $state.Menu=@(0,'Rename'); $state.Typed=@('RouteB','Reception')
    $settings=New-Settings
    Invoke-NSPScanBridgeRouteManager -ConfigurationPath $settings
    $after=Import-PowerShellDataFile -LiteralPath $settings
    Check ($after.Routes[0].Name -eq 'Reception' -and $after.Routes[1].Name -eq 'RouteB') 'Rename did not refuse a duplicate and then rename only that route.'
    New-Item -ItemType Directory -Path "$root\spoolA" -Force | Out-Null; [IO.File]::WriteAllText("$root\spoolA\job.json",'{}')
    Reset-Manager; $state.Menu=@(0,'Remove')
    $settings=New-Settings; $before=[IO.File]::ReadAllText($settings)
    Invoke-NSPScanBridgeRouteManager -ConfigurationPath $settings
    Check ($state.Errors.Count -eq 1 -and $state.Errors[0] -match '1 file\(s\) in Spool' -and [IO.File]::ReadAllText($settings) -eq $before) 'Removing a route with jobs was not refused.'
    Remove-Item -LiteralPath "$root\spoolA\job.json"
    Reset-Manager; $state.Menu=@(1,'Remove')
    $settings=New-Settings
    Invoke-NSPScanBridgeRouteManager -ConfigurationPath $settings
    $after=Import-PowerShellDataFile -LiteralPath $settings
    Check (@($after.Routes).Count -eq 1 -and $after.Routes[0].Name -eq 'RouteA' -and ($state.Chain -join ',') -eq 'Sysmon') 'Remove did not drop only that route and offer the Sysmon update.'
    Reset-Manager; $state.Menu=@(0,'Age'); $state.Typed=@('0','45')
    $settings=New-Settings
    Invoke-NSPScanBridgeRouteManager -ConfigurationPath $settings
    Check ((Import-PowerShellDataFile -LiteralPath $settings).Routes[0].MinimumAgeSeconds -eq 45) 'Age change did not reject 0 and save 45.'
    $single=New-Settings
    $text=[IO.File]::ReadAllText($single); $text=$text.Substring(0,$text.IndexOf("    @{ Name = 'RouteB'")) + "  )`r`n}`r`n"
    [IO.File]::WriteAllText($single,$text)
    Reset-Manager; $state.Menu=@(0,'Remove')
    Invoke-NSPScanBridgeRouteManager -ConfigurationPath $single
    Check ($state.Errors.Count -eq 1 -and @((Import-PowerShellDataFile -LiteralPath $single).Routes).Count -eq 1) 'The last route was removed.'

    Microsoft.PowerShell.Utility\Write-Host ('Passed: {0} route setup checks in {1}; Graph, accounts and console mocked.' -f $state.Checks,$PSVersionTable.PSVersion)
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
