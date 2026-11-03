[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','',Justification='State is read by the shadowed commands.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess','',Justification='Shadowed commands mirror the real signatures and record calls instead of changing anything.')]
[CmdletBinding()]
param([string]$SourceRoot)
$ErrorActionPreference='Stop'
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
foreach($file in 'ScanBridgeAlertSetup.ps1','ScanBridgeSetupPrompts.ps1','ScanBridgeRouteSetup.ps1','ScanBridgeDiscoverySetup.ps1') { . (Join-Path $SourceRoot "Private/$file") }
$state=@{Checks=0}
function Check($condition,$message) {if(-not $condition){throw $message};$state.Checks++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('nsp-toolkit-discovery-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function New-Settings {
    param([int]$AgeA=20)
    $path=Join-Path $root ('settings-'+[guid]::NewGuid().ToString('N')+'.psd1')
    $text=@"
@{
  Auth = @{ TenantId = '<tenant-guid>'; ClientId = '<app-guid>'; CertificateThumbprint = '<thumbprint>' }
  Routes = @(
    @{ Name = 'RouteA'; Source = '$root\scanA'; Spool = '$root\spoolA'; Archive = '$root\archiveA'; DriveId = 'd'; FolderItemId = 'f'; MinimumAgeSeconds = $AgeA }
    @{ Name = 'RouteB'; Source = '$root\scanB'; Spool = '$root\spoolB'; Archive = '$root\archiveB'; DriveId = 'd'; FolderItemId = 'f'; Custom = 'kept' }
  )
}
"@
    [IO.File]::WriteAllText($path,$text.Replace("`r`n","`n").Replace("`n","`r`n"))
    $path
}
try {
    $test=Join-Path $root 'test'; $out=Join-Path $root 'out'
    foreach($d in $test,$out,(Join-Path $root 'scanA')) { New-Item -ItemType Directory -Path $d | Out-Null }

    # Pure rules.
    $routes=@(@{Name='RouteA';Source="$root\scanA";Spool="$root\spoolA";Archive="$root\archiveA"})
    Check ((Test-NSPScanBridgeDiscoveryFolder -Folder "$root\scanA\" -Routes $routes).SourceRoute -eq 'RouteA') 'The route Source itself was not recognized.'
    Check ((Test-NSPScanBridgeDiscoveryFolder -Folder $root -Routes $routes).SourceRoute -eq 'RouteA') 'A parent of a Source was not treated as overlapping it.'
    Check ((Test-NSPScanBridgeDiscoveryFolder -Folder "$root\spoolA\x" -Routes $routes).Problem -match 'Spool') 'A folder inside a Spool was not refused.'
    $sibling=Test-NSPScanBridgeDiscoveryFolder -Folder "$root\scanAB" -Routes $routes
    Check (-not $sibling.Problem -and -not $sibling.SourceRoute) 'A sibling sharing a name prefix was treated as overlapping.'
    Check ((Get-NSPScanBridgeDiscoveryAgePlan -Current 20 -Suggested 40 -Classification TempRename) -eq 'Raise') 'A higher age was not a raise.'
    Check ((Get-NSPScanBridgeDiscoveryAgePlan -Current 20 -Suggested 20 -Classification Unknown) -eq 'Same') 'An equal age was not left alone.'
    Check ((Get-NSPScanBridgeDiscoveryAgePlan -Current 60 -Suggested 40 -Classification DirectExclusive) -eq 'Lower') 'A lower age for a clear class was not a lower.'
    foreach($c in 'Unknown','Hybrid') { Check ((Get-NSPScanBridgeDiscoveryAgePlan -Current 60 -Suggested 40 -Classification $c) -eq 'KeepAmbiguous') "A $c classification could lower the age." }

    function Get-NSPDryRun { $state.DryRun }
    function Get-NSPToolAnswers { param($Tool) $state.Answers }
    function Save-NSPToolAnswers { [CmdletBinding(SupportsShouldProcess)] param($Tool,$Answers) $state.Saved+=,([pscustomobject]$Answers); $state.Answers=[pscustomobject]$Answers }
    function Write-NSPConsoleLine { param($Text,$Role) if($Role -eq 'Error'){$state.Errors+=,$Text}; if($Role -eq 'Warning'){$state.Warnings+=,$Text} }
    function Write-Host { param($Object) }
    function Read-NSPFolderPath { param($Prompt,$Default,[switch]$Create) $state.FolderCreate=[bool]$Create; $state.FolderDefault=$Default; $state.Folder }
    function Read-NSPNonEmpty { param($Prompt,$CurrentValue) if(@($state.Typed).Count){$n=$state.Typed[0];$state.Typed=@($state.Typed|Select-Object -Skip 1);return $n}; $CurrentValue }
    function Read-NSPConfirm { param($Prompt,[switch]$DefaultYes) $state.Confirms+=,$Prompt; $next=$state.Confirm[0]; $state.Confirm=@($state.Confirm | Select-Object -Skip 1); [bool]$next }
    function Read-NSPMenu {
        param($Choices,$Prompt,$CancelLabel)
        $state.Menus+=,$Prompt
        $next=$state.Menu[0]; $state.Menu=@($state.Menu | Select-Object -Skip 1)
        if($null -eq $next) { return $null }
        @($Choices | Where-Object { $_.Value -eq $next })[0].Value
    }
    function Get-NSPScanBridgeTaskState { if($state.TaskError){throw (New-Object UnauthorizedAccessException 'Access is denied')}; if($state.TaskState){[pscustomobject]@{State=$state.TaskState}} }
    function Invoke-SyntheticDiscovery {
        param([string]$Path,[double]$DurationSeconds,[string]$DeviceName,[switch]$IncludeFileNames)
        $state.Calls+=,[pscustomobject]@{Path=$Path;DurationSeconds=$DurationSeconds;DeviceName=$DeviceName;IncludeFileNames=[bool]$IncludeFileNames}
        $profilePath=Join-Path $out ('profile_{0}.json' -f [guid]::NewGuid().ToString('N'))
        $deliveryProfile=[pscustomobject][ordered]@{SchemaVersion=1;Classification=$state.Class;Confidence='Medium';Override=$null;Recommendation=[pscustomobject]@{MinimumAgeSeconds=$state.Suggested;Notes=@('note')}}
        [IO.File]::WriteAllText($profilePath,($deliveryProfile | ConvertTo-Json -Depth 8))
        $deliveryProfile | Add-Member -NotePropertyMembers @{ProfilePath=$profilePath} -PassThru
    }
    function Get-Module { param($Name) $commands=@{}; if($state.Exported){$commands['Invoke-NSPScanBridgeDeliveryDiscovery']=Get-Command Invoke-SyntheticDiscovery}; [pscustomobject]@{Version=[version]'0.1.1';ExportedCommands=$commands} }
    function Reset-Flow {
        param([switch]$DryRun,[int]$AgeA=20)
        $state.Config=New-Settings -AgeA $AgeA; $state.Original=[IO.File]::ReadAllText($state.Config)
        $state.DryRun=[bool]$DryRun; $state.Exported=$true; $state.Folder=$test; $state.TaskState='Ready'; $state.TaskError=$false
        $state.Answers=[pscustomobject]@{ServiceAccount='ScanBridge'}; $state.Saved=@(); $state.Errors=@(); $state.Warnings=@()
        $state.Confirms=@(); $state.Menus=@(); $state.Calls=@(); $state.Typed=@(); $state.Class='TempRename'; $state.Suggested=40
        Get-ChildItem -LiteralPath $out -File | Remove-Item -Force
    }
    $routeA={ (Import-PowerShellDataFile -LiteralPath $state.Config).Routes[0] }
    $backups={ @(Get-ChildItem -LiteralPath $root -Filter ((Split-Path -Leaf $state.Config)+'.*.bak')).Count }

    # Happy path: dedicated folder, raise the age, save an override copy.
    Reset-Flow
    $state.Typed=@('Bad/Label','Front copier','Tested twice by hand')
    $state.Menu=@(180,0,'DirectExclusive')
    $state.Confirm=@($false,$true,$true,$true)   # names, review age, write settings, override
    Invoke-NSPScanBridgeDiscoverySetup -ConfigurationPath $state.Config
    Check ($state.Errors.Count -eq 0) "Happy path reported errors: $($state.Errors -join '; ')"
    Check ($state.Calls.Count -eq 1 -and $state.Calls[0].Path -eq $test -and $state.Calls[0].DurationSeconds -eq 180 -and $state.Calls[0].DeviceName -eq 'Front copier' -and -not $state.Calls[0].IncludeFileNames) 'Discovery was not called with the chosen inputs.'
    Check (@($state.Warnings -match 'Use letters').Count -eq 1) 'An invalid device label was not asked again.'
    Check ($state.FolderCreate -and $state.Answers.DiscoveryFolder -eq $test -and $state.Answers.DiscoveryDevice -eq 'Front copier' -and $state.Answers.ServiceAccount -eq 'ScanBridge') 'Folder and device were not remembered alongside existing answers.'
    $a=& $routeA
    Check ($a.MinimumAgeSeconds -eq 40 -and (& $backups) -eq 1 -and (Import-PowerShellDataFile -LiteralPath $state.Config).Routes[1].Custom -eq 'kept') 'The suggested age was not written with a backup, preserving other settings.'
    $profiles=@(Get-ChildItem -LiteralPath $out -Filter '*.json' | Sort-Object Name)
    $copy=@($profiles | Where-Object Name -match '_override_')
    $measured=@($profiles | Where-Object Name -notmatch '_override_')
    Check ($copy.Count -eq 1 -and $measured.Count -eq 1) 'The override was not saved as a separate copy.'
    $saved=[IO.File]::ReadAllText($copy[0].FullName) | ConvertFrom-Json
    Check ($saved.Override.Classification -eq 'DirectExclusive' -and $saved.Override.Reason -eq 'Tested twice by hand' -and $saved.Override.Utc -and $saved.Classification -eq 'TempRename') 'The override copy was wrong.'
    Check ($null -eq ([IO.File]::ReadAllText($measured[0].FullName) | ConvertFrom-Json).Override) 'The measured profile was changed.'

    # Lowering asks; declining leaves the settings alone. Ambiguous classes never lower or ask.
    Reset-Flow -AgeA 60
    $state.Menu=@(120,0); $state.Confirm=@($true,$true,$false,$false)   # names, review age, lower?, override
    Invoke-NSPScanBridgeDiscoverySetup -ConfigurationPath $state.Config
    Check ($state.Calls[0].IncludeFileNames -and @($state.Confirms -match '^Lower').Count -eq 1 -and [IO.File]::ReadAllText($state.Config) -eq $state.Original) 'A lower age was not confirmed explicitly before writing.'
    Reset-Flow -AgeA 60; $state.Class='Hybrid'
    $state.Menu=@(120,0); $state.Confirm=@($false,$true,$false)
    Invoke-NSPScanBridgeDiscoverySetup -ConfigurationPath $state.Config
    Check (@($state.Confirms -match '^Lower').Count -eq 0 -and @($state.Warnings -match 'never lowers').Count -eq 1 -and [IO.File]::ReadAllText($state.Config) -eq $state.Original) 'An ambiguous classification offered to lower the age.'

    # Route folders: Spool refused; live Source refused unless the task is disabled.
    Reset-Flow; $state.Folder="$root\spoolA"
    Invoke-NSPScanBridgeDiscoverySetup -ConfigurationPath $state.Config
    Check ($state.Calls.Count -eq 0 -and @($state.Errors -match 'Spool').Count -eq 1) 'A Spool test folder was not refused.'
    Reset-Flow; $state.Folder="$root\scanA"
    Invoke-NSPScanBridgeDiscoverySetup -ConfigurationPath $state.Config
    Check ($state.Calls.Count -eq 0 -and @($state.Errors -match 'not disabled').Count -eq 1) 'A live Source with the task enabled was not refused.'
    Reset-Flow; $state.Folder="$root\scanA"; $state.TaskError=$true
    Invoke-NSPScanBridgeDiscoverySetup -ConfigurationPath $state.Config
    Check ($state.Calls.Count -eq 0 -and @($state.Errors -match 'cannot be read').Count -eq 1) 'A live Source with an unreadable task was not refused.'
    Reset-Flow; $state.Folder="$root\scanA"; $state.TaskState='Disabled'
    $state.Menu=@(180); $state.Confirm=@($true,$false,$false,$false)   # observe anyway, names, review age, override
    Invoke-NSPScanBridgeDiscoverySetup -ConfigurationPath $state.Config
    Check ($state.Calls.Count -eq 1 -and @($state.Warnings -match 'uploaded when the task runs').Count -eq 1) 'A disabled-task Source was not warned about, then observed.'

    # DRY RUN observes (read-only) but creates no folder and writes no settings or override.
    Reset-Flow -DryRun
    $state.Typed=@('Front copier','reason')
    $state.Menu=@(180,0,'Unknown'); $state.Confirm=@($false,$true,$true)
    Invoke-NSPScanBridgeDiscoverySetup -ConfigurationPath $state.Config
    Check ($state.Calls.Count -eq 1 -and -not $state.FolderCreate -and $state.Saved.Count -eq 0) 'DRY RUN did not observe without creating or saving.'
    Check ([IO.File]::ReadAllText($state.Config) -eq $state.Original -and @(Get-ChildItem -LiteralPath $out -Filter '*_override_*').Count -eq 0) 'DRY RUN wrote settings or an override.'

    # A ScanBridge build without discovery is refused before any prompt.
    Reset-Flow; $state.Exported=$false
    $threw=$false; try { Invoke-NSPScanBridgeDiscoverySetup -ConfigurationPath $state.Config } catch { $threw=$_.Exception.Message -match 'does not export Invoke-NSPScanBridgeDeliveryDiscovery' }
    Check ($threw -and $state.Menus.Count -eq 0) 'A build without discovery was not refused up front.'

    Microsoft.PowerShell.Utility\Write-Host ('Passed: {0} discovery setup checks in {1}; discovery, task and console calls mocked.' -f $state.Checks,$PSVersionTable.PSVersion)
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
