[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','',Justification='State is read by the shadowed commands.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess','',Justification='Shadowed commands mirror the real signatures and record calls instead of changing anything.')]
[CmdletBinding()]
param([string]$SourceRoot)
$ErrorActionPreference='Stop'
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
foreach($file in 'ScanBridgeAlertSetup.ps1','ScanBridgeSetupPrompts.ps1','ScanBridgeModuleInstall.ps1','ScanBridgeSettingsSetup.ps1') { . (Join-Path $SourceRoot "Private/$file") }
$state=@{Checks=0}
function Check($condition,$message) {if(-not $condition){throw $message};$state.Checks++}
$realElevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$realAcl=${function:Set-NSPScanBridgePrivateAcl}
function Test-NSPScanBridgeElevated { $state.Elevated }
function Get-NSPDryRun { $state.DryRun }
function Get-NSPToolAnswers { param($Tool) $state.Answers }
function Save-NSPToolAnswers { [CmdletBinding(SupportsShouldProcess)] param($Tool,$Answers) $state.Saved+=,([pscustomobject]$Answers); $state.Answers=[pscustomobject]$Answers }
function Write-NSPConsoleLine { param($Text,$Role) $state.Lines+=,$Text; if($Role -eq 'Error'){$state.Errors+=,$Text}; if($Role -eq 'Warning'){$state.Warnings+=,$Text} }
function Read-NSPNonEmpty { param($Prompt,$CurrentValue) $state.Offered=$CurrentValue; if($state.Typed){$state.Typed}else{$CurrentValue} }
function Read-NSPConfirm { param($Prompt,[switch]$DefaultYes) $state.Confirms++; $state.Confirm }
$root=Join-Path ([IO.Path]::GetTempPath()) ('nsp-toolkit-settings-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function Add-SyntheticModule {
    param([string]$Version,[string]$Text)
    $base=Join-Path $root "modules\NSP.ScanBridge\$Version"
    New-Item -ItemType Directory -Path (Join-Path $base 'config') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $base 'NSP.ScanBridge.psd1'),"@{ ModuleVersion = '$Version' }")
    if($Text) { [IO.File]::WriteAllText((Join-Path $base 'config\ScanBridge.example.psd1'),$Text) }
}
function Reset-Flow {
    param([switch]$DryRun)
    $state.DryRun=[bool]$DryRun; $state.Elevated=$true; $state.Confirm=$true; $state.Confirms=0
    $state.Answers=[pscustomobject]@{}; $state.Saved=@(); $state.Lines=@(); $state.Errors=@(); $state.Warnings=@()
    $state.Case=Join-Path $root ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $state.Case | Out-Null
    $state.Target=Join-Path $state.Case 'private\ScanBridge.psd1'; $state.Typed=$state.Target
}
function Get-AclSummary {
    param([string]$Path)
    $acl=Get-Acl -LiteralPath $Path
    [pscustomobject]@{Protected=$acl.AreAccessRulesProtected;Sids=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)}
}
$private=@('S-1-5-18','S-1-5-32-544')
try {
    $example="@{`r`n  # Example comment kept.`r`n  LockPath = 'C:\ProgramData\NSP\ScanBridge\worker.lock'`r`n  Auth = @{ TenantId = '<tenant-guid>' }`r`n  Routes = @()`r`n}`r`n"
    $script:NSPAllUsersModuleRootOverride=Join-Path $root 'modules'
    New-Item -ItemType Directory -Path $script:NSPAllUsersModuleRootOverride | Out-Null

    # Nothing to copy.
    Reset-Flow
    Check ($null -eq (Invoke-NSPScanBridgeSettingsCreate)) 'A missing module returned a path.'
    Check (@($state.Errors) -match 'for all users') 'A missing module did not point at the install step.'
    Check (-not (Test-Path -LiteralPath $state.Target)) 'A missing module still created a file.'

    Add-SyntheticModule -Version '0.1.0' -Text '@{ Old = $true }'
    Add-SyntheticModule -Version '0.1.2'
    Add-SyntheticModule -Version '0.1.1' -Text $example
    Check ((Get-NSPScanBridgeSettingsExample).Version -eq [version]'0.1.1') 'The highest version with an example was not chosen.'

    # Offered path: argument, then saved answer, then the ProgramData default.
    Reset-Flow; $state.Typed=$null; $state.Confirm=$false
    Invoke-NSPScanBridgeSettingsCreate | Out-Null
    Check ($state.Offered -eq (Join-Path $env:ProgramData 'NSP\ScanBridge\ScanBridge.psd1')) 'The default path was not offered.'
    Reset-Flow; $state.Typed=$null; $state.Confirm=$false; $state.Answers=[pscustomobject]@{ConfigurationPath=$state.Target}
    Invoke-NSPScanBridgeSettingsCreate | Out-Null
    Check ($state.Offered -eq $state.Target) 'The saved path was not offered.'
    Reset-Flow; $state.Typed=$null; $state.Confirm=$false
    Invoke-NSPScanBridgeSettingsCreate -ConfigurationPath $state.Target | Out-Null
    Check ($state.Offered -eq $state.Target) 'The given path was not offered.'

    # Bad paths.
    foreach($bad in 'ScanBridge.psd1','\\server\share\ScanBridge.psd1','C:\Temp\ScanBridge.txt') {
        Reset-Flow; $state.Typed=$bad
        Check ($null -eq (Invoke-NSPScanBridgeSettingsCreate)) "'$bad' was accepted."
        Check ($state.Confirms -eq 0 -and @($state.Errors).Count -eq 1) "'$bad' was not refused before confirming."
    }
    Reset-Flow; $state.Typed=$state.Case+'\folder.psd1'; New-Item -ItemType Directory -Path $state.Typed | Out-Null
    Check ($null -eq (Invoke-NSPScanBridgeSettingsCreate) -and @($state.Errors) -match 'folder') 'A folder at the path was not refused.'
    Reset-Flow
    $link=Join-Path $state.Case 'link'; $real=Join-Path $state.Case 'real'
    New-Item -ItemType Directory -Path $real | Out-Null
    New-Item -ItemType Junction -Path $link -Target $real | Out-Null
    $state.Typed=Join-Path $link 'ScanBridge.psd1'
    Check ($null -eq (Invoke-NSPScanBridgeSettingsCreate) -and @($state.Errors) -match 'link') 'A path through a link was not refused.'
    Check (-not (Test-Path -LiteralPath (Join-Path $real 'ScanBridge.psd1'))) 'A file was created through a link.'
    [IO.Directory]::Delete($link)

    # An existing file is selected, never replaced.
    Reset-Flow
    New-Item -ItemType Directory -Path (Split-Path -Parent $state.Target) | Out-Null
    [IO.File]::WriteAllText($state.Target,'@{ Mine = $true }')
    Check ((Invoke-NSPScanBridgeSettingsCreate) -eq $state.Target) 'An existing file was not selected.'
    Check ([IO.File]::ReadAllText($state.Target) -eq '@{ Mine = $true }') 'An existing file was changed.'
    Check ($state.Confirms -eq 0 -and $state.Answers.ConfigurationPath -eq $state.Target) 'An existing file was not saved as the selection.'

    # DRY RUN, not elevated and declining each create nothing.
    Reset-Flow -DryRun
    Check ($null -eq (Invoke-NSPScanBridgeSettingsCreate)) 'DRY RUN returned a path.'
    Check (-not (Test-Path -LiteralPath (Split-Path -Parent $state.Target))) 'DRY RUN created the folder.'
    Check (@($state.Saved).Count -eq 0 -and $state.Confirms -eq 0) 'DRY RUN saved or asked.'
    Check (@($state.Lines) -match 'Administrators and SYSTEM only') 'DRY RUN did not show the plan.'
    Reset-Flow; $state.Elevated=$false
    Check ($null -eq (Invoke-NSPScanBridgeSettingsCreate) -and @($state.Errors) -match 'elevated') 'An unelevated session was not refused.'
    Check (-not (Test-Path -LiteralPath (Split-Path -Parent $state.Target))) 'An unelevated session created the folder.'
    Reset-Flow; $state.Confirm=$false
    Check ($null -eq (Invoke-NSPScanBridgeSettingsCreate)) 'Declining returned a path.'
    Check (-not (Test-Path -LiteralPath (Split-Path -Parent $state.Target)) -and @($state.Saved).Count -eq 0) 'Declining changed something.'

    # A failed restriction leaves no file behind and reports no success.
    Reset-Flow
    New-Item -ItemType Directory -Path (Split-Path -Parent $state.Target) | Out-Null
    ${function:Set-NSPScanBridgePrivateAcl}={ param($Path) throw 'Access is denied' }
    $threw=$false; try { Invoke-NSPScanBridgeSettingsCreate | Out-Null } catch { $threw=$true }
    Check $threw 'A failed restriction was hidden.'
    Check (-not (Test-Path -LiteralPath $state.Target) -and @($state.Saved).Count -eq 0) 'A failed restriction left a file or a saved path.'

    # A file that appears after the check is not overwritten.
    Reset-Flow
    New-Item -ItemType Directory -Path (Split-Path -Parent $state.Target) | Out-Null
    function Read-NSPConfirm { param($Prompt,[switch]$DefaultYes) [IO.File]::WriteAllText($state.Target,'@{ Raced = $true }'); $true }
    $threw=$false; try { Invoke-NSPScanBridgeSettingsCreate | Out-Null } catch { $threw=$true }
    Check ($threw -and [IO.File]::ReadAllText($state.Target) -eq '@{ Raced = $true }') 'A file created during the prompt was overwritten.'
    function Read-NSPConfirm { param($Prompt,[switch]$DefaultYes) $state.Confirms++; $state.Confirm }

    # The copy itself, with the ACL step recorded.
    ${function:Set-NSPScanBridgePrivateAcl}={ param($Path) $state.Restricted+=,$Path }
    Reset-Flow; $state.Restricted=@()
    Check ((Invoke-NSPScanBridgeSettingsCreate) -eq $state.Target) 'The new path was not returned.'
    Check ([IO.File]::ReadAllText($state.Target) -ceq $example) 'The copy differs from the example.'
    Check ($state.Answers.ConfigurationPath -eq $state.Target) 'The new path was not saved.'
    Check ((@($state.Restricted) -join '|') -eq ((Split-Path -Parent $state.Target)+'|'+$state.Target)) 'The new folder and file were not both restricted.'
    Reset-Flow; $state.Restricted=@()
    New-Item -ItemType Directory -Path (Split-Path -Parent $state.Target) | Out-Null
    Invoke-NSPScanBridgeSettingsCreate | Out-Null
    Check ((@($state.Restricted) -join '|') -eq $state.Target) 'An existing folder''s access was changed.'
    Check (@($state.Lines) -match 'access is left alone') 'The plan did not say an existing folder is left alone.'

    # Real ACLs: these need an elevated session, as the step itself does.
    ${function:Set-NSPScanBridgePrivateAcl}=$realAcl
    if($realElevated) {
        Reset-Flow
        Invoke-NSPScanBridgeSettingsCreate | Out-Null
        $folderAcl=Get-AclSummary -Path (Split-Path -Parent $state.Target)
        Check ($folderAcl.Protected -and (($folderAcl.Sids -join ',') -eq ($private -join ','))) 'The new folder is not Administrators and SYSTEM only.'
        $fileAcl=Get-AclSummary -Path $state.Target
        Check ($fileAcl.Protected -and (($fileAcl.Sids -join ',') -eq ($private -join ','))) 'The new file is not Administrators and SYSTEM only.'

        # The file keeps that ACL through the setup step that rewrites it.
        Set-NSPPsd1TopLevelEntry -Path $state.Target -Key Auth -Value ([ordered]@{TenantId='synthetic'}) -Confirm:$false | Out-Null
        $afterWrite=Get-AclSummary -Path $state.Target
        Check ($afterWrite.Protected -and (($afterWrite.Sids -join ',') -eq ($private -join ','))) 'A settings write widened the file''s access.'
        Check ([IO.File]::ReadAllText($state.Target) -match '# Example comment kept\.') 'A settings write lost the example comment.'

        # A backup keeps the file's access, even once the folder grants more, and its content.
        $before=[IO.File]::ReadAllBytes($state.Target)
        $openFolder=Get-Acl -LiteralPath (Split-Path -Parent $state.Target)
        $openFolder.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),'Modify','ContainerInherit, ObjectInherit','None','Allow')))
        Set-Acl -LiteralPath (Split-Path -Parent $state.Target) -AclObject $openFolder
        $backup=(Set-NSPPsd1TopLevelEntry -Path $state.Target -Key Auth -Value ([ordered]@{TenantId='synthetic-2'}) -Confirm:$false).BackupPath
        $backupAcl=Get-AclSummary -Path $backup
        Check ($backupAcl.Protected -and (($backupAcl.Sids -join ',') -eq ($private -join ','))) 'A backup took the folder''s access.'
        Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) -ceq [Convert]::ToBase64String($before)) 'A backup differs from the file it keeps.'

        # An unrestricted file's backup stays inherited, so old installs behave as before.
        $plain=Join-Path (Split-Path -Parent $state.Target) 'Plain.psd1'
        [IO.File]::WriteAllText($plain,"@{`r`n  Auth = @{}`r`n}`r`n")
        $plainBackup=(Set-NSPPsd1TopLevelEntry -Path $plain -Key Auth -Value ([ordered]@{TenantId='synthetic'}) -Confirm:$false).BackupPath
        Check (-not (Get-AclSummary -Path $plainBackup).Protected) 'An ordinary file''s backup became protected.'
        [IO.File]::Delete($plain); [IO.File]::Delete($plainBackup)

        # A task-account style grant on the folder does not reach the file.
        $folder=Split-Path -Parent $state.Target
        $acl=Get-Acl -LiteralPath $folder
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),'Modify','ContainerInherit, ObjectInherit','None','Allow')))
        Set-Acl -LiteralPath $folder -AclObject $acl
        Check (-not ((Get-AclSummary -Path $state.Target).Sids -contains 'S-1-5-32-545')) 'A folder grant reached the protected file.'
        Check (Test-NSPScanBridgeFolderOpenToUsers -Path $folder) 'A folder open to Users was not detected.'
        Reset-Flow
        New-Item -ItemType Directory -Path (Split-Path -Parent $state.Target) | Out-Null
        $open=Get-Acl -LiteralPath (Split-Path -Parent $state.Target)
        $open.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-1-0')),'Write','ContainerInherit, ObjectInherit','None','Allow')))
        Set-Acl -LiteralPath (Split-Path -Parent $state.Target) -AclObject $open
        Invoke-NSPScanBridgeSettingsCreate | Out-Null
        Check (@($state.Warnings) -match 'Ordinary users') 'An open folder was not warned about.'
        Check (-not ((Get-AclSummary -Path $state.Target).Sids -contains 'S-1-1-0')) 'An open folder''s access reached the file.'
    } else { Write-Host 'Settings setup: real ACL checks skipped (not elevated).' -ForegroundColor Yellow }
    Write-Host ("Settings setup contract passed: {0} checks." -f $state.Checks) -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
