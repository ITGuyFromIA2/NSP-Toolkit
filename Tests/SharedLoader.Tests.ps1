<#
    Pester 5. The sibling loader: this repo holds the canonical copy; the tool modules carry generated
    copies (tools\Sync-SharedLoader.ps1). Checks each sibling checkout that is present.
#>

Describe 'Shared sibling loader' {
    BeforeAll {
        $script:Canonical = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private\Import-NSPToolkitModule.ps1'
        $script:Text = [IO.File]::ReadAllText($Canonical) -replace "`r?`n", "`r`n"
        $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    It 'marks itself as the canonical copy' {
        $Text | Should -Match 'CANONICAL COPY: NSP-Toolkit\\Private\\Import-NSPToolkitModule\.ps1'
    }
    It '<_> carries an identical copy (when checked out next to this repo)' -ForEach @('NSP-ActiveDirectory', 'NSP-NPS', 'NSP-PKI', 'NSP-FortiClient') {
        $copy = Join-Path $Root "$_\Private\Import-NSPToolkitModule.ps1"
        if (-not (Test-Path -LiteralPath (Join-Path $Root $_))) { Set-ItResult -Skipped -Because "$_ is not checked out next to NSP-Toolkit"; return }
        ([IO.File]::ReadAllText($copy) -replace "`r?`n", "`r`n") | Should -BeExactly $Text -Because 'run NSP-Toolkit\tools\Sync-SharedLoader.ps1 after editing the loader'
    }
}
