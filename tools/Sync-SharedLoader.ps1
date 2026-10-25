<#
.SYNOPSIS
    Copies the canonical Private\Import-NSPToolkitModule.ps1 into the sibling tool-module checkouts.
.DESCRIPTION
    NSP.ActiveDirectory, NSP.NPS, NSP.PKI, NSP.FortiClient, NSP.FileTransfer, NSP.M365.ConditionalAccess, NSP.Win.MDE, NSP.M365.Investigation and NSP.SSLCertificates each ship a private copy of this
    module's sibling loader (they can't depend on NSP.Toolkit to load NSP.Toolkit). This file is the
    one to edit; run this script afterwards, then each repo's tests (Tests\SharedLoader.Tests.ps1)
    confirm its copy matches. Checkouts that aren't present are reported and skipped.
.PARAMETER ToolkitsRoot
    The folder holding the NSP-* checkouts. Defaults to this repository's parent folder.
.EXAMPLE
    .\tools\Sync-SharedLoader.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$ToolkitsRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private\Import-NSPToolkitModule.ps1'
$text = [IO.File]::ReadAllText($source) -replace "`r?`n", "`r`n"
foreach ($repo in 'NSP-ActiveDirectory', 'NSP-NPS', 'NSP-PKI', 'NSP-FortiClient', 'NSP-FileTransfer', 'NSP-M365-ConditionalAccess', 'NSP-Win-MDE', 'NSP-M365-Investigation', 'NSP-SSLCertificates') {
    $target = Join-Path $ToolkitsRoot "$repo\Private\Import-NSPToolkitModule.ps1"
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $target))) { Write-Warning "$repo not found under $ToolkitsRoot - skipped."; continue }
    if ((Test-Path -LiteralPath $target) -and ([IO.File]::ReadAllText($target) -replace "`r?`n", "`r`n") -ceq $text) { Write-Host "$repo already current." -ForegroundColor DarkGray; continue }
    if ($PSCmdlet.ShouldProcess($target, 'Write the shared loader')) {
        [IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding($false)))
        Write-Host "$repo updated." -ForegroundColor Green
    }
}
