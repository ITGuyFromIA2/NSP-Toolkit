<#
.SYNOPSIS
    Pre-push check for NSP-Toolkit: PSScriptAnalyzer, then Pester 5 under Windows PowerShell 5.1
    AND PowerShell 7 (pwsh). Exits non-zero if anything fails.
.PARAMETER CurrentEditionOnly
    Run Pester only in the current host (used internally for the per-edition child runs).
.EXAMPLE
    .\tools\Test-Repo.ps1
#>
[CmdletBinding()]
param([switch]$CurrentEditionOnly)

# Tests never install sibling modules from the Gallery (inherited by both child test runs).
$env:NSP_NO_AUTOINSTALL = '1'
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-RepoPester {
    Import-Module Pester -MinimumVersion 5.5.0 -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = Join-Path $repoRoot 'Tests'
    $cfg.Output.Verbosity = 'Normal'
    $cfg.Run.PassThru = $true
    $r = Invoke-Pester -Configuration $cfg
    return ($r.FailedCount -eq 0 -and $r.Result -ne 'Failed')
}

if ($CurrentEditionOnly) {
    if (Invoke-RepoPester) { exit 0 } else { exit 1 }
}

$failed = $false
Write-Host "`n=== PSScriptAnalyzer ===" -ForegroundColor Cyan
Import-Module PSScriptAnalyzer -Force
$analysis = Invoke-ScriptAnalyzer -Path $repoRoot -Recurse -Settings (Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1')
if ($analysis) {
    $analysis | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message
    if ($analysis | Where-Object Severity -in 'Error', 'Warning') { $failed = $true }
} else { Write-Host 'clean' -ForegroundColor Green }

foreach ($exe in 'powershell.exe', 'pwsh.exe') {
    Write-Host "`n=== Pester () ===" -ForegroundColor Cyan
    & $exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -CurrentEditionOnly
    if ($LASTEXITCODE -ne 0) { $failed = $true; Write-Host "Pester FAILED under $exe" -ForegroundColor Red }
}

if ($failed) { Write-Host "`nRESULT: FAIL" -ForegroundColor Red; exit 1 }
Write-Host "`nRESULT: PASS" -ForegroundColor Green
exit 0