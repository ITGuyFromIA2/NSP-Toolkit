[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[CmdletBinding()]
param([string]$SourceRoot)
$ErrorActionPreference='Stop'
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
$script:ModuleRoot=$SourceRoot
. (Join-Path $SourceRoot 'Private/ToolDefinitions.ps1')
. (Join-Path $SourceRoot 'Private/Invoke-NSPToolkitTool.ps1')
. (Join-Path $SourceRoot 'Public/Start-NSPToolkit.ps1')
$state=@{Checks=0;Local=0;Scan=0;Imports=0;Health=0;Watch=0;Errors=0;Queue=@()}
function Check($condition,$message) {if(-not $condition){throw $message};$state.Checks++}
function Import-NSPToolkitModule { param($Name,$MinimumVersion) $state.Imports++; if($Name -eq 'NSP.Console'){$state.ConsoleMinimum=[version]$MinimumVersion} }
function Get-Module { param([switch]$ListAvailable,$Name) [pscustomobject]@{Version=[version]'9.0.0';Path='synthetic';ModuleBase=$SourceRoot;ExportedCommands=@{'Watch-NSPScanBridgeReadiness'=(Get-Command Watch-Synthetic)}} }
function Watch-Synthetic {param($ConfigurationPath) $state.Watch++;Check ($ConfigurationPath -eq $state.Configuration) 'Diagnostic did not receive same PSD1.'}
function Start-NSPLocalAccountManager {$state.Local++}
function Start-NSPScanBridgeSetup {$state.Scan++}
Start-NSPToolkit -Tool LocalAccounts -NoElevate
Start-NSPToolkit -Tool ScanBridge -NoElevate
Check ($state.Local -eq 1 -and $state.Scan -eq 1) 'Direct launcher routing failed.'
Check ((Get-NSPToolDefinition ScanBridge).ModuleName -eq 'NSP.Toolkit') 'Setup entry depends on nonexistent ScanBridge manager.'
Check ((Get-NSPToolDefinition LocalAccounts).ModuleName -eq 'NSP.Win.LocalAccount') 'Account boundary incorrect.'
. (Join-Path $SourceRoot 'Public/Start-NSPScanBridgeSetup.ps1')
function Write-NSPConsoleHeader {param($Title,$Subtitle)}
function Write-NSPConsoleLine {param($Text,$Role)if($Role -eq 'Error'){$state.Errors++}}
function Read-NSPMenu {param($Choices,$Prompt,$CancelLabel) if($state.Queue.Count){$item=$state.Queue[0];$state.Queue=@($state.Queue|Select-Object -Skip 1);return $item};return $null}
function Get-NSPScanBridgeHealth {param($ConfigurationPath) $state.Health++;Check ($ConfigurationPath -eq $state.Configuration) 'Health did not receive same PSD1.'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('nsp-toolkit-helper-'+[guid]::NewGuid().ToString('N')+'.psd1')
[IO.File]::WriteAllText($fixture,'@{Routes=@()}')
try {
    $state.Configuration=$fixture
    $state.Queue=@('Dependencies','Account','Health','Watch')
    Start-NSPScanBridgeSetup -ConfigurationPath $fixture | Out-Null
    Check ($state.Local -eq 2 -and $state.Health -eq 1 -and $state.Watch -eq 1 -and $state.Errors -eq 0) 'Setup menu dispatch failed.'
    # Setup's NSP.Console minimum must cover the newest Console prompt it uses.
    $setupText=(Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'Private') -Filter 'ScanBridge*.ps1' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    if($setupText -match 'Read-NSPFolderPath') { Check ($state.ConsoleMinimum -ge [version]'0.1.5') "Setup uses Read-NSPFolderPath (NSP.Console 0.1.5) but requires only $($state.ConsoleMinimum)." }
    $state.Queue=@('Health')
    Start-NSPScanBridgeSetup -ConfigurationPath ($fixture+'.missing') | Out-Null
    Check ($state.Errors -eq 1 -and $state.Health -eq 1) 'Missing configuration was not held.'
    Write-Host ('Passed: {0} toolkit helper routing checks in {1}; imports/menu/actions mocked.' -f $state.Checks,$PSVersionTable.PSVersion)
} finally {[IO.File]::Delete($fixture)}
