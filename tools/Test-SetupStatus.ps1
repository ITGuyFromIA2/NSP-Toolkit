[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','',Justification='State is read by the shadowed commands.')]
[CmdletBinding()]
param([string]$SourceRoot)
$ErrorActionPreference='Stop'
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
foreach($file in 'ScanBridgeAlertSetup.ps1','ScanBridgeSetupPrompts.ps1','ScanBridgeSysmonSetup.ps1','ScanBridgeSetupStatus.ps1') { . (Join-Path $SourceRoot "Private/$file") }
$state=@{Checks=0}
function Check($condition,$message) {if(-not $condition){throw $message};$state.Checks++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('nsp-toolkit-status-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$thumb='AB'*20; $alertThumb='CD'*20; $tenant='11111111-2222-3333-4444-555555555555'
try {
    # Key ACL: an explicit Allow Read for the SID only.
    $probe=Join-Path $root 'probe.bin'; [IO.File]::WriteAllBytes($probe,[byte[]](1))
    $acl=Get-Acl -LiteralPath $probe
    $acl.SetAccessRuleProtection($true,$false)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('S-1-5-18' -as [Security.Principal.SecurityIdentifier]),'Read','Allow'))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('S-1-5-19' -as [Security.Principal.SecurityIdentifier]),'Read','Deny'))
    Check (Test-NSPAclAllowsRead -Acl $acl -Sid 'S-1-5-18') 'An explicit Allow Read was not recognized.'
    Check (-not (Test-NSPAclAllowsRead -Acl $acl -Sid 'S-1-5-19')) 'A Deny ACE was counted as read access.'
    Check (-not (Test-NSPAclAllowsRead -Acl $acl -Sid 'S-1-5-20')) 'An absent SID was counted as read access.'

    # Sysmon coverage: own named rules, merged rule groups, unrelated rules and prefix siblings.
    $own=[xml]'<Sysmon><EventFiltering><RuleGroup><FileCreate onmatch="include"><TargetFilename name="NSP ScanBridge" condition="begin with">C:\Scans\A\</TargetFilename><Rule name="NSP ScanBridge" groupRelation="and"><TargetFilename condition="begin with">C:\Scans\B</TargetFilename><TargetFilename condition="end with">.pdf</TargetFilename></Rule><TargetFilename name="Other" condition="begin with">C:\Scans\C</TargetFilename></FileCreate></RuleGroup></EventFiltering></Sysmon>'
    Check ((Get-NSPScanBridgeSysmonCoverage -Configuration $own -RuleName 'NSP ScanBridge' -Source 'C:\Scans\A','C:\Scans\B\Sub','C:\Scans\C','C:\Scans\AB') -eq 2) 'Sysmon coverage counted the wrong Sources.'

    # Full status with every local read shadowed.
    function Get-NSPAllUsersModuleRoot { 'W','P' }
    function Get-NSPAllUsersModuleVersion { param($Root,$Name) $v=$state.Modules["$Root|$Name"]; if($v){[pscustomobject]@{Name=$Name;Version=[version]$v}} }
    function Find-NSPPowerShell7 { if($state.Pwsh){[pscustomobject]@{Path='C:\pwsh.exe';Version='7.6.9'}} }
    function Get-NSPToolAnswers { param($Tool) [pscustomobject]@{ServiceAccount='ScanBridge'} }
    function Use-NSPSetupStatusModule { param($Name,$MinimumVersion) $true }
    function Get-NSPLocalServiceAccount { param($Name) if($state.AccountExists){[pscustomobject]@{Name=$Name;Account="PC\$Name";SID='S-1-5-21-1-2-3-1001';Enabled=$state.AccountEnabled}} }
    function Get-NSPLocalAccountRight { param($Name) if($state.RightsDenied){throw (New-Object UnauthorizedAccessException 'Access is denied C:\secret')}; [pscustomobject]@{DirectBatchLogon=$true;DirectDenyBatchLogon=$false} }
    function Get-NSPScanBridgeSetupCertificate { param($Thumbprint,$Sid) $state.CertSids+=,$Sid; $state.Certs[$Thumbprint] }
    function Get-NSPSysmonStatus { [pscustomobject]@{Installed=$true;Running=$true;ConfigFile=$state.SysmonFile} }
    function Test-NSPSysmonConfig { param($ConfigPath) [pscustomobject]@{InSync=$true} }
    function Resolve-NSPScanBridgeInstalledRunner { [pscustomobject]@{Runner='C:\Program Files\PowerShell\Modules\NSP.ScanBridge\0.1.0\scripts\Run-ScanBridge.ps1';Version=[version]'0.1.0'} }
    function Get-NSPScanBridgeTaskState {
        if($state.TaskError -eq 'Denied') { throw (New-Object UnauthorizedAccessException 'Access is denied') }
        if($state.TaskError -eq 'Missing') { return $null }
        [pscustomobject]@{State=$state.TaskState;UserId="$([Environment]::MachineName)\ScanBridge";LastTaskResult=[int64]2;LastRunTime=[datetime]'2026-11-02 14:03';Actions=@([pscustomobject]@{Execute=$probe;Arguments='-File "C:\Program Files\PowerShell\Modules\NSP.ScanBridge\0.1.0\scripts\Run-ScanBridge.ps1" -ConfigurationPath x'})}
    }
    $dirs=foreach($n in 'src','spool','archive','state') { $d=Join-Path $root $n; New-Item -ItemType Directory -Path $d | Out-Null; $d }
    [IO.File]::WriteAllText((Join-Path $dirs[0] 'scan.pdf'),'x')
    $sysmonFile=Join-Path $root 'Sysmon.xml'
    [IO.File]::WriteAllText($sysmonFile,"<Sysmon><EventFiltering><RuleGroup><FileCreate onmatch=`"include`"><TargetFilename name=`"NSP ScanBridge`" condition=`"begin with`">$($dirs[0])</TargetFilename></FileCreate></RuleGroup></EventFiltering></Sysmon>")
    $settings=Join-Path $root 'ScanBridge.psd1'
    [IO.File]::WriteAllText($settings,@"
@{ Auth=@{TenantId='$tenant';ClientId='app';CertificateThumbprint='$thumb'}
   Alerts=@{Enabled=`$true;From='scan@example.com';To='dispatch@example.com';StateDirectory='$($dirs[3])';Auth=@{TenantId='$tenant';ClientId='alert';CertificateThumbprint='$alertThumb'}}
   Routes=@(@{Name='ToFax';Source='$($dirs[0])';Spool='$($dirs[1])';Archive='$($dirs[2])';DriveId='d';FolderItemId='f'}) }
"@)
    function Reset-Status {
        $state.Modules=@{}; foreach($r in 'W','P') { $state.Modules["$r|NSP.ScanBridge"]='0.1.0'; $state.Modules["$r|NSP.M365.Graph"]='0.1.3'; $state.Modules["$r|Microsoft.Graph.Authentication"]='2.40.0' }
        $state.Pwsh=$true; $state.AccountExists=$true; $state.AccountEnabled=$true; $state.RightsDenied=$false
        $state.TaskError=$null; $state.TaskState='Ready'; $state.SysmonFile=$sysmonFile; $state.CertSids=@()
        $state.Certs=@{$thumb=[pscustomobject]@{Store='LocalMachine';DaysRemaining=341;KeyReadable=$true;KeyReason=$null};$alertThumb=[pscustomobject]@{Store='LocalMachine';DaysRemaining=364;KeyReadable=$true;KeyReason=$null}}
    }
    $line={ param($s,$label) @($s.Lines | Where-Object Label -eq $label)[0] }

    Reset-Status
    $s=Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings
    Check ($s.Ready -and -not $s.Reason) "A healthy setup was not Ready: $($s.Reason)"
    Check ((& $line $s 'Helpers').Text -eq 'ScanBridge 0.1.0, Graph 0.1.3, SDK 2.40.0 (WinPS and PS7)') 'Matching editions were not combined.'
    Check ((& $line $s 'ToFax').Text -eq 'folders OK, destination set, queue 1/0') "Route line was wrong: $((& $line $s 'ToFax').Text)"
    Check ((& $line $s 'Sysmon').Text -eq 'running, ScanBridge rule covers 1 of 1 Sources') "Sysmon line was wrong: $((& $line $s 'Sysmon').Text)"
    Check ((& $line $s 'Scheduled task').Text -match '^registered, Ready, last result 2 \(2026-11-02 14:03\), runs installed 0\.1\.0$') "Task line was wrong: $((& $line $s 'Scheduled task').Text)"
    Check (@($state.CertSids | Where-Object { $_ -ne 'S-1-5-21-1-2-3-1001' }).Count -eq 0) 'Key access was not checked for the task account SID.'
    Check ((& $line $s 'Mail').Role -eq 'Muted' -and (& $line $s 'Mail').Text -match 'not verified') 'Alert mail was implied to work.'
    $text=($s.Lines | ForEach-Object { "$($_.Label) $($_.Text) $($_.Blocker)" }) -join "`n"
    foreach($secret in $thumb,$alertThumb,$tenant,'example.com',$root,'Run-ScanBridge','scan.pdf') { Check ($text.IndexOf($secret,[StringComparison]::OrdinalIgnoreCase) -lt 0) "Status exposed an identifier or path: $secret" }

    Reset-Status; $state.TaskState='Disabled'
    $s=Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings
    Check (-not $s.Ready -and $s.Reason -eq 'task disabled' -and (& $line $s 'Scheduled task').Text -match 'DISABLED') 'A disabled task did not block.'

    # Unknown is not No: a denied task read is Unknown, blocks Ready, and is not reported as disabled or missing.
    Reset-Status; $state.TaskError='Denied'
    $s=Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings
    $task=& $line $s 'Scheduled task'
    Check ($task.Text -eq 'Unknown (access denied)' -and $task.Role -eq 'Muted' -and -not $s.Ready) "A denied task read was not Unknown: $($task.Text)"
    Reset-Status; $state.TaskError='Missing'
    Check ((& $line (Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings) 'Scheduled task').Text -eq 'not registered') 'A missing task was not reported as not registered.'
    Reset-Status; $state.RightsDenied=$true
    $s=Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings
    Check ((& $line $s 'Service account').Text -match 'batch-logon right unknown' -and -not $s.Ready -and ($s.Lines.Text -join ' ') -notmatch 'secret') 'An unreadable right was not Unknown, or leaked the exception.'
    Reset-Status; $state.Certs[$thumb].KeyReadable=$null; $state.Certs[$thumb].KeyReason='access denied'
    $s=Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings
    Check ((& $line $s 'Ingestion app').Text -match 'key access unknown \(access denied\)' -and $s.Reason -eq 'ingestion app key access unknown') 'Unknown key access did not block Ready.'

    # Certificates, alerts and routes.
    Reset-Status; $state.Certs[$alertThumb]=[pscustomobject]@{Store=$null;DaysRemaining=$null;KeyReadable=$null;KeyReason=$null}
    Check ((Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings).Reason -eq 'alerts certificate missing') 'A missing alert certificate did not block.'
    Reset-Status; $state.Certs[$thumb].DaysRemaining=20
    $s=Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings
    Check ((& $line $s 'Ingestion app').Role -eq 'Error' -and $s.Ready) 'Under 30 days was not Red, or blocked while still valid.'
    Reset-Status; $state.Certs[$thumb].DaysRemaining=60
    Check ((& $line (Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings) 'Ingestion app').Role -eq 'Warning') 'Under 90 days was not Yellow.'
    Reset-Status; $state.Certs[$thumb].KeyReadable=$false
    Check ((Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings).Reason -eq 'task account cannot read the ingestion app key') 'An unreadable key did not block.'
    $mismatch=Join-Path $root 'mismatch.psd1'
    [IO.File]::WriteAllText($mismatch,([IO.File]::ReadAllText($settings) -replace "Auth=@\{TenantId='$tenant';ClientId='alert'","Auth=@{TenantId='99999999-2222-3333-4444-555555555555';ClientId='alert'" -replace "Name='ToFax';Source='[^']+'","Name='ToFax';Source='$root\gone'"))
    Reset-Status
    $s=Get-NSPScanBridgeSetupStatus -ConfigurationPath $mismatch
    Check ((& $line $s 'Alerts').Text -match 'tenant DIFFERS' -and (& $line $s 'Alerts').Role -eq 'Error') 'An alert tenant mismatch was not flagged.'
    Check ((& $line $s 'ToFax').Text -match '^Source missing, destination set, queue \?/0$' -and $s.Reason -eq 'route ToFax folders missing') "A missing route folder was not flagged: $((& $line $s 'ToFax').Text)"

    # Helpers and settings selection.
    Reset-Status; $state.Modules.Remove('P|NSP.ScanBridge'); $state.Modules['W|NSP.M365.Graph']='0.1.1'
    $s=Get-NSPScanBridgeSetupStatus -ConfigurationPath $settings
    Check ((& $line $s 'Helpers').Text -eq 'incomplete in every all-users folder' -and $s.Reason -eq 'ScanBridge modules not installed for all users') 'Incomplete helpers did not block.'
    Check ((& $line $s 'PS7').Text -match 'ScanBridge missing' -and (& $line $s 'WinPS').Role -eq 'Warning') 'Per-edition helper lines were wrong.'
    Reset-Status
    $s=Get-NSPScanBridgeSetupStatus -ConfigurationPath (Join-Path $root 'absent.psd1')
    foreach($label in 'Routes','Ingestion app','Alerts') { Check ((& $line $s $label).Text -eq 'settings not selected') "$label did not say settings not selected." }
    Check ((& $line $s 'Helpers') -and (& $line $s 'Scheduled task') -and (& $line $s 'Service account').Text -match 'enabled') 'Settings-independent lines were not shown without settings.'
    Check ((& $line $s 'Sysmon').Text -eq 'running, settings not selected' -and $s.Reason -eq 'settings not selected') 'Missing settings did not block Ready.'

    # Renderer: one segment line per status line, then the verdict.
    function Write-NSPConsoleSegment { param($Segment) $state.Drawn+=,(@($Segment | ForEach-Object { $t=[string]$_[0]; if($_.Count -gt 2){$t.PadRight($_[2])}else{$t} }) -join '') }
    function Write-NSPConsoleLine { param($Message,$Role) $state.Drawn+=,[string]$Message }
    function Get-NSPDryRun { $true }
    $state.Drawn=@()
    Show-NSPScanBridgeSetupStatus -Status ([pscustomobject]@{Lines=@((New-NSPSetupStatusLine -Label 'Routes' -Text '1 configured'),(New-NSPSetupStatusLine -Label 'ToFax' -Text 'ok' -Detail));Ready=$false;Reason='task disabled'})
    Check ($state.Drawn[0] -match '^Routes: +1 configured$' -and $state.Drawn[1] -match '^  ToFax: +ok$' -and ($state.Drawn -match 'Ready for unattended runs: +No - task disabled').Count -eq 1 -and ($state.Drawn -match 'MODE: DRY RUN').Count -eq 1) "Rendering was wrong: $($state.Drawn -join ' | ')"

    Write-Host ('Passed: {0} setup status checks in {1}; task, account, certificate and Sysmon reads shadowed.' -f $state.Checks,$PSVersionTable.PSVersion)
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
