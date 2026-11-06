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
            function Start-NSPEntraPairingWizard { param($SourceAnchor,$Server,$Path,[switch]$ReadOnly) throw 'Live wizard forbidden' }
            function Resolve-NSPEntraPairingSourceAnchor { param($ComputerName,[pscredential]$Credential) throw 'Live collector forbidden' }
            function Read-NSPMenu { param($Prompt,$Choices,$CancelLabel) throw 'Interactive menu forbidden' }
            function Read-NSPFilePath { param($Prompt,$Filter,[switch]$AllowBack) throw 'Interactive prompt forbidden' }
            function Test-NSPBackSignal { param($Value) $false }
        }
        BeforeEach {
            Mock Get-NSPDryRun { $false }
            Mock Import-NSPGalleryToolModule { }
            Mock Connect-NSPEntraPairingGraph { }
            Mock Resolve-NSPEntraPairingSourceAnchor { $script:anchor }
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
            Should -Invoke Import-NSPGalleryToolModule -Times 1 -ParameterFilter { $Name -eq 'NSP.ActiveDirectory' -and $MinimumVersion -eq '0.1.13' }
            Should -Invoke Import-NSPGalleryToolModule -Times 1 -ParameterFilter { $Name -eq 'NSP.M365.UserPairing' -and $MinimumVersion -eq '0.1.2' }
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
        It 'collects directly inside default startup without a JSON prerequisite' {
            Start-NSPUserPairingSetup | Out-Null
            Should -Invoke Resolve-NSPEntraPairingSourceAnchor -Times 1
            Should -Invoke Start-NSPEntraPairingWizard -Times 1
        }
        It 'passes the selected sync server and keeps evidence intact' {
            Start-NSPUserPairingSetup -SyncServer sync01.example.test | Out-Null
            Should -Invoke Resolve-NSPEntraPairingSourceAnchor -Times 1 -ParameterFilter { $ComputerName -eq 'sync01.example.test' }
        }
        It 'returns before connection when collection is cancelled' {
            Mock Resolve-NSPEntraPairingSourceAnchor { $null }
            Start-NSPUserPairingSetup | Should -BeNullOrEmpty
            Should -Invoke Connect-NSPEntraPairingGraph -Times 0
        }
        It 'blocks unverified collected evidence before connection' {
            $script:anchor.Provenance='Unverified'
            { Start-NSPUserPairingSetup } | Should -Throw '*Verified*'
            Should -Invoke Connect-NSPEntraPairingGraph -Times 0
        }
        It 'allows an explicit review while retaining global dry run and forbidding directory writes' {
            Mock Get-NSPDryRun { $true }
            Start-NSPUserPairingSetup -Review | Out-Null
            Should -Invoke Start-NSPEntraPairingWizard -Times 1 -ParameterFilter { $ReadOnly }
        }
        It 'collects nothing under Review WhatIf even without an anchor input' {
            Start-NSPUserPairingSetup -Review -WhatIf
            Should -Invoke Import-NSPGalleryToolModule -Times 0
            Should -Invoke Resolve-NSPEntraPairingSourceAnchor -Times 0
            Should -Invoke Connect-NSPEntraPairingGraph -Times 0
        }
        It 'routes the explicit review mode without changing the toolkit dry run setting' {
            Mock Get-NSPDryRun { $true }
            Mock Read-NSPMenu { 'review' }
            Mock Start-NSPUserPairingSetup { }
            Mock Set-NSPDryRun { throw 'Must not disable global protection' }
            Invoke-NSPToolkitTool UserPairing
            Should -Invoke Start-NSPUserPairingSetup -Times 1 -ParameterFilter { $Review }
            Should -Invoke Set-NSPDryRun -Times 0
        }
        It 'does nothing when the startup mode is cancelled' {
            Mock Get-NSPDryRun { $true }
            Mock Read-NSPMenu { $null }
            Mock Start-NSPUserPairingSetup { }
            Invoke-NSPToolkitTool UserPairing
            Should -Invoke Start-NSPUserPairingSetup -Times 0
        }
        It 'preserves the selected dry run mode across elevation' {
            Mock Import-NSPToolkitModule { }
            Mock Get-NSPDryRun { $false }
            Mock Invoke-NSPElevated { $true }
            Start-NSPToolkit -Tool AD
            Should -Invoke Invoke-NSPElevated -Times 1 -ParameterFilter { $Command -like '*Set-NSPDryRun -Enabled $false -Confirm:$false;*' }
        }
        It 'does not force elevation for pairing discovery' {
            Mock Import-NSPToolkitModule { }
            Mock Invoke-NSPElevated { throw 'Pairing review does not need local elevation' }
            Mock Invoke-NSPToolkitTool { }
            Start-NSPToolkit -Tool UserPairing
            Should -Invoke Invoke-NSPElevated -Times 0
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
        It 'upgrades an old installation and replaces its loaded module before using the new route' {
            $script:installed=[pscustomobject]@{Version=[version]'0.1.1';Path='old.psd1'}
            Mock Get-Module { if($ListAvailable){$script:installed}else{[pscustomobject]@{Version=[version]'0.1.1';Path='old.psd1'}} }
            Mock Install-NSPModule { $script:installed=[pscustomobject]@{Version=[version]'0.1.2';Path='new.psd1'} }
            Mock Remove-Module { }
            Import-NSPGalleryToolModule -Name NSP.M365.UserPairing -MinimumVersion 0.1.2
            Should -Invoke Install-NSPModule -Times 1 -ParameterFilter { $MinimumVersion -eq '0.1.2' }
            Should -Invoke Remove-Module -Times 1 -ParameterFilter { $Name -eq 'NSP.M365.UserPairing' }
            Should -Invoke Import-Module -Times 1 -ParameterFilter { $Name -eq 'new.psd1' }
        }
    }
}
