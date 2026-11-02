[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','',Justification='State is read by the shadowed commands.')]
[CmdletBinding()]
param([string]$SourceRoot)
$ErrorActionPreference='Stop'
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
foreach($file in 'ScanBridgeAlertSetup.ps1','ScanBridgeModuleInstall.ps1') { . (Join-Path $SourceRoot "Private/$file") }
$state=@{Checks=0}
function Check($condition,$message) {if(-not $condition){throw $message};$state.Checks++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('nsp-toolkit-install-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function New-FakeModule([string]$Root,[string]$Name,[string]$Version,[switch]$Runner) {
    $dir=Join-Path (Join-Path $Root $Name) $Version
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir "$Name.psd1"),"@{ ModuleVersion = '$Version' }")
    if($Runner) { New-Item -ItemType Directory -Path (Join-Path $dir 'scripts') -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $dir 'scripts\Run-ScanBridge.ps1'),'# runner') }
    $dir
}
try {
    function Get-NSPDryRun { $state.DryRun }
    function Test-NSPScanBridgeElevated { $state.Elevated }
    function Write-NSPConsoleLine { param($Text,$Role) $state.Lines+=,"$Role|$Text" }
    function Read-NSPConfirm { param($Prompt,[switch]$DefaultYes) $state.Confirms++; $true }
    function Find-NSPPowerShell7 { $state.Pwsh }
    function Find-NSPGalleryModule { param($Name) if($state.Gallery[$Name]){[pscustomobject]@{Name=$Name;Version=$state.Gallery[$Name]}} }
    function Save-NSPGalleryModule { param($Name,$Version,$Path) $state.Saved+=,"$Name|$Version|$Path"; New-FakeModule -Root $Path -Name $Name -Version $Version -Runner:($Name -eq 'NSP.ScanBridge') | Out-Null }
    function Save-NSPPowerShell7Installer { param($Destination) $state.Downloads++; [pscustomobject]@{Path='C:\x\PowerShell-7.6.9-win-x64.msi';Version='v7.6.9';Signer='O=Microsoft Corporation'} }
    function Install-NSPPowerShell7Msi { param($MsiPath) $state.MsiInstalls++; $state.Pwsh=[pscustomobject]@{Path='C:\Program Files\PowerShell\7\pwsh.exe';Version='7.6.9'}; 0 }
    function Test-NSPScanBridgeModuleResolution { param($PowerShellPath,$ModuleRoot) $state.Resolutions++; @() }
    function Reset-Install {
        param([switch]$DryRun)
        $base=Join-Path $root ([guid]::NewGuid().ToString('N'))
        $script:NSPAllUsersModuleRootOverride=@((Join-Path $base 'WindowsPowerShell'),(Join-Path $base 'PowerShell'))
        foreach($r in $script:NSPAllUsersModuleRootOverride) { New-Item -ItemType Directory -Path $r -Force | Out-Null }
        $state.DryRun=[bool]$DryRun; $state.Elevated=$true; $state.Pwsh=$null; $state.Lines=@(); $state.Saved=@()
        $state.Confirms=0; $state.Downloads=0; $state.MsiInstalls=0; $state.Resolutions=0
        $state.Gallery=@{'NSP.ScanBridge'='0.1.0';'NSP.M365.Graph'='0.1.2';'Microsoft.Graph.Authentication'='2.40.0'}
    }

    # Fresh machine with stale Graph 0.1.0 in both folders and no PowerShell 7.
    Reset-Install
    $old=@($script:NSPAllUsersModuleRootOverride | ForEach-Object { New-FakeModule -Root $_ -Name 'NSP.M365.Graph' -Version '0.1.0' })
    Invoke-NSPScanBridgeModuleInstall | Out-Null
    Check ($state.Downloads -eq 1 -and $state.MsiInstalls -eq 1) 'Missing PowerShell 7 was not downloaded and installed.'
    Check ($state.Saved.Count -eq 6) "Expected three modules in two folders, saved $($state.Saved.Count)."
    foreach($r in $script:NSPAllUsersModuleRootOverride) {
        Check (@($state.Saved | Where-Object { $_ -eq "NSP.M365.Graph|0.1.2|$r" }).Count -eq 1) "Graph 0.1.2 not installed into $r."
        Check (@(Get-NSPAllUsersModuleVersion -Root $r -Name 'NSP.M365.Graph' | ForEach-Object { [string]$_.Version }) -join ',' -eq '0.1.2') "Older Graph was not replaced in $r."
    }
    Check (-not (Test-Path -LiteralPath $old[0]) -and -not (Test-Path -LiteralPath $old[1])) 'Old Graph 0.1.0 folders remain.'
    Check ($state.Confirms -eq 1 -and $state.Resolutions -eq 1) 'Plan was not confirmed once and then checked for resolution.'
    $runner=Resolve-NSPScanBridgeInstalledRunner
    Check ($runner -and $runner.Root -eq $script:NSPAllUsersModuleRootOverride[1] -and $runner.Runner -like '*NSP.ScanBridge\0.1.0\scripts\Run-ScanBridge.ps1') 'Installed runner was not taken from the PowerShell 7 folder.'

    # Nothing to do once installed; DRY RUN and non-elevated sessions change nothing.
    $state.Saved=@(); $state.Confirms=0
    Invoke-NSPScanBridgeModuleInstall | Out-Null
    Check ($state.Saved.Count -eq 0 -and $state.Confirms -eq 0 -and @($state.Lines | Where-Object { $_ -like 'Success|*already installed*' }).Count -eq 1) 'An up-to-date machine was changed or not reported as current.'
    Reset-Install -DryRun
    $stale=New-FakeModule -Root $script:NSPAllUsersModuleRootOverride[0] -Name 'NSP.M365.Graph' -Version '0.1.0'
    Invoke-NSPScanBridgeModuleInstall | Out-Null
    Check ($state.Saved.Count -eq 0 -and $state.Downloads -eq 0 -and (Test-Path -LiteralPath $stale) -and @($state.Lines | Where-Object { $_ -like '*Remove older NSP.M365.Graph 0.1.0*' }).Count -eq 1) 'DRY RUN installed or removed something, or did not plan the removal.'
    Reset-Install; $state.Elevated=$false
    Invoke-NSPScanBridgeModuleInstall | Out-Null
    Check ($state.Saved.Count -eq 0 -and @($state.Lines | Where-Object { $_ -like 'Error|*elevated*' }).Count -eq 1) 'A non-elevated session was not stopped.'

    # A module missing from the Gallery is reported and skipped; the rest still install.
    Reset-Install; $state.Pwsh=[pscustomobject]@{Path='C:\pwsh.exe';Version='7.6.9'}; $state.Gallery.Remove('NSP.ScanBridge')
    Invoke-NSPScanBridgeModuleInstall | Out-Null
    Check ($state.Saved.Count -eq 4 -and -not @($state.Saved | Where-Object { $_ -like 'NSP.ScanBridge|*' }).Count -and @($state.Lines | Where-Object { $_ -like 'Warning|NSP.ScanBridge*not on the PowerShell Gallery*' }).Count -eq 1 -and $state.Downloads -eq 0) 'An unpublished module was not reported and skipped.'
    Check ($null -eq (Resolve-NSPScanBridgeInstalledRunner)) 'A runner was reported without NSP.ScanBridge installed.'

    # Resolution probe against real PowerShell 7 with crafted folders (read-only, imports nothing).
    $pwshExe=Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if(Test-Path -LiteralPath $pwshExe) {
        Remove-Item function:Test-NSPScanBridgeModuleResolution
        . (Join-Path $SourceRoot 'Private/ScanBridgeModuleInstall.ps1')
        $a=Join-Path $root 'probeA'; $b=Join-Path $root "probe B'quote"
        New-FakeModule -Root $a -Name 'NSP.M365.Graph' -Version '0.1.0' | Out-Null
        New-FakeModule -Root $b -Name 'NSP.M365.Graph' -Version '0.1.2' | Out-Null
        New-FakeModule -Root $b -Name 'Microsoft.Graph.Authentication' -Version '2.40.0' | Out-Null
        $rows=@(Test-NSPScanBridgeModuleResolution -PowerShellPath $pwshExe -ModuleRoot $a,$b)
        $graph=@($rows | Where-Object Module -eq 'NSP.M365.Graph')[0]
        Check ($graph.Status -eq 'OlderFirst' -and $graph.FirstFound -eq '0.1.0' -and $graph.MeetsMinimum -eq '0.1.2') 'An older Graph earlier on the path was not reported as OlderFirst.'
        Check (@($rows | Where-Object Module -eq 'NSP.ScanBridge')[0].Status -eq 'Missing') 'A missing ScanBridge was not reported.'
        $rows=@(Test-NSPScanBridgeModuleResolution -PowerShellPath $pwshExe -ModuleRoot $b,$a)
        Check (@($rows | Where-Object Module -eq 'NSP.M365.Graph')[0].Status -eq 'OK' -and @($rows | Where-Object Module -eq 'Microsoft.Graph.Authentication')[0].Status -eq 'OK') 'Graph 0.1.2 first on the path was not OK.'
    } else { Microsoft.PowerShell.Utility\Write-Host 'PowerShell 7 not installed here; resolution probe checks skipped.' }

    Microsoft.PowerShell.Utility\Write-Host ('Passed: {0} module install checks in {1}; Gallery, installer and elevation mocked.' -f $state.Checks,$PSVersionTable.PSVersion)
} finally {
    $script:NSPAllUsersModuleRootOverride=$null
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
