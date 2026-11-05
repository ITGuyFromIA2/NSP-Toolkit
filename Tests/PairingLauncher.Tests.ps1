# Offline stubs accept the real command signatures; all live calls are mocked.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline stubs preserve production signatures and forbid live calls.')]
param()
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.Toolkit.psd1') -Force
BeforeAll { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.Toolkit.psd1') -Force }
AfterAll { Remove-Module NSP.Toolkit -Force -ErrorAction SilentlyContinue }
Describe 'Published pairing launcher' {
    InModuleScope NSP.Toolkit {
        BeforeAll {
            function Connect-NSPEntraPairingGraph { param($Purpose) throw 'Live connection forbidden' }
            function Start-NSPEntraPairingWizard { param($SourceAnchor,$Server,$Path) throw 'Live wizard forbidden' }
            function Read-NSPFilePath { param($Prompt,$Filter,[switch]$AllowBack) throw 'Interactive prompt forbidden' }
            function Test-NSPBackSignal { param($Value) $false }
        }
        BeforeEach {
            Mock Get-NSPDryRun { $false }
            Mock Import-NSPGalleryToolModule { }
            Mock Connect-NSPEntraPairingGraph { }
            Mock Start-NSPEntraPairingWizard { [pscustomobject]@{Queue='synthetic';Anchor=$SourceAnchor} }
            $script:anchor=[pscustomobject]@{Provenance='Verified';Strategy='ConsistencyGuidWithObjectGuidFallback';Evidence=@('synthetic')}
        }
        It 'registers a Gallery-backed entry without importing a private checkout first' {
            $def=Get-NSPToolDefinition UserPairing
            $def.ModuleName | Should -Be 'NSP.M365.UserPairing'
            $def.EntryFunction | Should -Be 'Start-NSPUserPairingSetup'
            Mock Start-NSPUserPairingSetup { }
            Invoke-NSPToolkitTool UserPairing
            Should -Invoke Start-NSPUserPairingSetup -Times 1
            Should -Invoke Import-NSPGalleryToolModule -Times 0
        }
        It 'requires published suffix-capable AD and returns the wizard result with intact evidence' {
            $result=Start-NSPUserPairingSetup -SourceAnchor $script:anchor -Server dc01.example.test -Path 'synthetic.json'
            $result.Queue | Should -Be 'synthetic'
            $result.Anchor.Evidence | Should -Contain 'synthetic'
            Should -Invoke Import-NSPGalleryToolModule -Times 1 -ParameterFilter { $Name -eq 'NSP.ActiveDirectory' -and $MinimumVersion -eq '0.1.12' }
            Should -Invoke Import-NSPGalleryToolModule -Times 1 -ParameterFilter { $Name -eq 'NSP.M365.UserPairing' -and $MinimumVersion -eq '0.1.0' }
            Should -Invoke Connect-NSPEntraPairingGraph -Times 1 -ParameterFilter { $Purpose -eq 'Preflight' }
            Should -Invoke Start-NSPEntraPairingWizard -Times 1 -ParameterFilter { $Server -eq 'dc01.example.test' -and $Path -eq 'synthetic.json' }
        }
        It 'reads a saved source anchor as JSON before connecting' {
            $file=Join-Path $TestDrive 'anchor.json'
            $script:anchor | ConvertTo-Json -Depth 20 | Set-Content $file
            Start-NSPUserPairingSetup -SourceAnchorPath $file | Out-Null
            Should -Invoke Start-NSPEntraPairingWizard -Times 1 -ParameterFilter { $SourceAnchor.Provenance -eq 'Verified' }
        }
        It 'blocks an unverified anchor before sign-in or collection' {
            $script:anchor.Provenance='Unverified'
            { Start-NSPUserPairingSetup -SourceAnchor $script:anchor } | Should -Throw '*Verified*'
            Should -Invoke Connect-NSPEntraPairingGraph -Times 0
            Should -Invoke Start-NSPEntraPairingWizard -Times 0
        }
        It 'performs no installation or sign-in in WhatIf' {
            Start-NSPUserPairingSetup -SourceAnchor $script:anchor -WhatIf
            Should -Invoke Import-NSPGalleryToolModule -Times 0
            Should -Invoke Connect-NSPEntraPairingGraph -Times 0
        }
        It 'performs no installation or sign-in in Toolkit DRY RUN' {
            Mock Get-NSPDryRun { $true }
            Start-NSPUserPairingSetup -SourceAnchor $script:anchor
            Should -Invoke Import-NSPGalleryToolModule -Times 0
            Should -Invoke Connect-NSPEntraPairingGraph -Times 0
        }
    }
}
Describe 'Gallery module loading' {
    InModuleScope NSP.Toolkit {
        BeforeEach {
            $script:priorAutoInstall=$env:NSP_NO_AUTOINSTALL
            $env:NSP_NO_AUTOINSTALL='0'
            $script:installed=$null
            Mock Get-Module { if ($ListAvailable) { $script:installed } }
            Mock Import-NSPToolkitModule { }
            Mock Test-NSPIsAdmin { $false }
            Mock Install-NSPModule { $script:installed=[pscustomobject]@{Version=[version]'0.1.0';Path='synthetic.psd1'} }
            Mock Import-Module { }
        }
        AfterEach { $env:NSP_NO_AUTOINSTALL=$script:priorAutoInstall }
        It 'installs from the Gallery and imports the verified installed path' {
            Import-NSPGalleryToolModule -Name NSP.M365.UserPairing -MinimumVersion 0.1.0
            Should -Invoke Install-NSPModule -Times 1 -ParameterFilter { $Name -eq 'NSP.M365.UserPairing' -and $Scope -eq 'CurrentUser' }
            Should -Invoke Import-Module -Times 1 -ParameterFilter { $Name -eq 'synthetic.psd1' -and $Global }
        }
        It 'uses AllUsers when elevated' {
            Mock Test-NSPIsAdmin { $true }
            Import-NSPGalleryToolModule -Name NSP.M365.UserPairing -MinimumVersion 0.1.0
            Should -Invoke Install-NSPModule -Times 1 -ParameterFilter { $Scope -eq 'AllUsers' }
        }
        It 'uses an adequate installed version without installing' {
            $script:installed=[pscustomobject]@{Version=[version]'0.1.0';Path='synthetic.psd1'}
            Import-NSPGalleryToolModule -Name NSP.M365.UserPairing -MinimumVersion 0.1.0
            Should -Invoke Install-NSPModule -Times 0
        }
        It 'never falls back to sibling source when automatic installation is disabled' {
            $env:NSP_NO_AUTOINSTALL='1'
            { Import-NSPGalleryToolModule -Name NSP.M365.UserPairing -MinimumVersion 0.1.0 } | Should -Throw '*disabled*'
            Should -Invoke Import-NSPToolkitModule -Times 0
            Should -Invoke Install-NSPModule -Times 0
        }
        It 'stops when Gallery installation fails' {
            Mock Install-NSPModule { throw 'synthetic Gallery failure' }
            { Import-NSPGalleryToolModule -Name NSP.M365.UserPairing -MinimumVersion 0.1.0 } | Should -Throw '*Gallery failure*'
            Should -Invoke Import-Module -Times 0
        }
    }
}
