# Offline stubs accept the real command signatures; all live calls are mocked.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline stubs preserve production signatures and forbid live calls.')]
param()
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.Toolkit.psd1') -Force
BeforeAll { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.Toolkit.psd1') -Force }
AfterAll { Remove-Module NSP.Toolkit -Force -ErrorAction SilentlyContinue }
Describe 'vCard import launcher' {
    InModuleScope NSP.Toolkit {
        BeforeAll {
            function Export-NSPOutlookContactCsv { param($Path,$OutputDirectory,$BatchSize,[switch]$Reparse,[switch]$Overwrite) throw 'Live conversion forbidden' }
            function ConvertFrom-NSPVCard { param($Path,$OutFile) throw 'Live parse forbidden' }
            # Not a Mock: Pester hides -WhatIf from mocks, and the preview/delete split is what these tests prove.
            function script:Remove-NSPGraphMailboxContact {
                [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')] param($UserId, $BackupDirectory, [switch]$Permanent)
                $call = [pscustomobject]@{ WhatIf = [bool]$WhatIfPreference; UserId = $UserId; Permanent = [bool]$Permanent }
                $script:removeCalls.Add($call)
                $null = $PSCmdlet.ShouldProcess($UserId, 'Delete every contact (synthetic)')
                [pscustomobject]@{ Found = 3; Folders = 1; BackupPath = 'synthetic.json'; Deleted = $(if ($call.WhatIf) { 0 } else { 3 }); AlreadyGone = 0; Failed = @(); Remaining = 0 }
            }
            function Connect-NSPGraph { param([string[]]$Scopes,[switch]$Connect) throw 'Live connection forbidden' }
            function Get-MgContext { throw 'Live context forbidden' }
            function Read-NSPMenu { param($Prompt,$Choices,$CancelLabel) throw 'Interactive menu forbidden' }
            function Read-NSPFilePath { param($Prompt,$Filter,[switch]$AllowBack) throw 'Interactive prompt forbidden' }
            function Read-NSPFolderPath { param($Prompt,$Default,[switch]$Create,[switch]$AllowBack) throw 'Interactive prompt forbidden' }
            function Read-NSPConfirm { param($Prompt) throw 'Interactive prompt forbidden' }
            function Read-NSPNonEmpty { param($Prompt) throw 'Interactive prompt forbidden' }
            function Test-NSPBackSignal { param($Value) $false }
        }
        BeforeEach {
            $script:vcf = Join-Path $TestDrive 'synthetic.vcf'
            Set-Content -LiteralPath $script:vcf -Value 'BEGIN:VCARD','VERSION:3.0','FN:Example Person','END:VCARD'
            $script:out = Join-Path $TestDrive 'out'
            Mock Get-NSPDryRun { $false }
            Mock Import-NSPGalleryToolModule { }
            Mock Import-Module { }
            Mock Write-Host { }
            Mock Export-NSPOutlookContactCsv { [pscustomobject]@{OutputDirectory=$OutputDirectory;Cards=3;Exported=3;Skipped=0;Extras=0;PossibleDuplicates=0;Batches=@(1);Seconds=0.1} }
            Mock ConvertFrom-NSPVCard { 1..3 | ForEach-Object { [pscustomobject]@{Index=$_} } }
            Mock Get-MgContext { [pscustomobject]@{AuthType='Delegated';Account='person@example.test';TenantId='00000000-0000-0000-0000-000000000000'} }
            Mock Connect-NSPGraph { Get-MgContext }
            $script:removeCalls = New-Object System.Collections.Generic.List[object]
            Mock Read-NSPConfirm { $true }
        }
        It 'registers VCFImport with a VCF alias and no elevation' {
            $def = Get-NSPToolDefinition VCF
            $def.Name | Should -Be 'VCFImport'
            $def.EntryFunction | Should -Be 'Start-NSPVCardImport'
            $def.RequiresAdmin | Should -BeFalse
            Mock Import-NSPToolkitModule { }
            Mock Invoke-NSPElevated { throw 'Must not elevate' }
            Mock Start-NSPVCardImport { }
            Start-NSPToolkit -Tool VCF
            Should -Invoke Start-NSPVCardImport -Times 1
            Should -Invoke Invoke-NSPElevated -Times 0
        }
        It 'still elevates a named admin tool' {
            Mock Import-NSPToolkitModule { }
            Mock Invoke-NSPElevated { $true }
            Start-NSPToolkit -Tool AD
            Should -Invoke Invoke-NSPElevated -Times 1
        }
        It 'DRY RUN writes nothing, installs nothing and signs in to nothing' {
            Mock Get-NSPDryRun { $true }
            Mock Get-Module { [pscustomobject]@{Name='NSP.LogParse';Version=[version]'0.1.1';Path='synthetic.psd1'} } -ParameterFilter { $ListAvailable }
            $r = Start-NSPVCardImport -Path $script:vcf -OutputDirectory $script:out -PurgeMode DeletedItems
            $r.Preview | Should -BeTrue
            $r.Cards | Should -Be 3
            Should -Invoke Export-NSPOutlookContactCsv -Times 0
            Should -Invoke Import-NSPGalleryToolModule -Times 0
            Should -Invoke Connect-NSPGraph -Times 0
            $script:removeCalls.Count | Should -Be 0
            Test-Path $script:out | Should -BeFalse
        }
        It 'DRY RUN without LogParse installed only says it would install it' {
            Mock Get-NSPDryRun { $true }
            Mock Get-Module { } -ParameterFilter { $ListAvailable }
            $r = Start-NSPVCardImport -Path $script:vcf -OutputDirectory $script:out
            $r.Cards | Should -BeNullOrEmpty
            Should -Invoke ConvertFrom-NSPVCard -Times 0
            Should -Invoke Import-NSPGalleryToolModule -Times 0
        }
        It 'WhatIf is a preview too' {
            Mock Get-Module { } -ParameterFilter { $ListAvailable }
            Start-NSPVCardImport -Path $script:vcf -OutputDirectory $script:out -WhatIf | Out-Null
            Should -Invoke Export-NSPOutlookContactCsv -Times 0
            Should -Invoke Import-NSPGalleryToolModule -Times 0
        }
        It 'the DRY RUN menu launch goes straight to the preview' {
            Mock Read-NSPMenu { throw 'No startup menu expected' }
            Mock Get-NSPDryRun { $true }
            Mock Start-NSPVCardImport { }
            Invoke-NSPToolkitTool VCFImport
            Should -Invoke Start-NSPVCardImport -Times 1
            Should -Invoke Read-NSPMenu -Times 0
        }
        It 'LocalOnly converts without Graph' {
            $r = Start-NSPVCardImport -Path $script:vcf -OutputDirectory $script:out -LocalOnly -BatchSize 500
            $r.Conversion.Exported | Should -Be 3
            Should -Invoke Export-NSPOutlookContactCsv -Times 1 -ParameterFilter { $BatchSize -eq 500 -and $OutputDirectory -eq $script:out }
            Should -Invoke Import-NSPGalleryToolModule -Times 1 -ParameterFilter { $Name -eq 'NSP.LogParse' -and $MinimumVersion -eq '0.1.1' }
            Should -Invoke Import-NSPGalleryToolModule -Times 0 -ParameterFilter { $Name -eq 'NSP.M365.Graph' }
            $script:removeCalls.Count | Should -Be 0
        }
        It 'rejects LocalOnly with a purge' {
            { Start-NSPVCardImport -Path $script:vcf -LocalOnly -PurgeMode Permanent } | Should -Throw '*LocalOnly*'
        }
        It 'Preview purge backs up and deletes nothing' {
            $r = Start-NSPVCardImport -Path $script:vcf -OutputDirectory $script:out -PurgeMode Preview
            Should -Invoke Import-NSPGalleryToolModule -Times 1 -ParameterFilter { $Name -eq 'NSP.M365.Graph' -and $MinimumVersion -eq '0.1.4' }
            Should -Invoke Connect-NSPGraph -Times 1 -ParameterFilter { $Scopes -contains 'Contacts.ReadWrite' }
            $script:removeCalls.Count | Should -Be 1
            $script:removeCalls[0].WhatIf | Should -BeTrue
            $script:removeCalls[0].UserId | Should -Be 'person@example.test'
            Should -Invoke Read-NSPConfirm -Times 0
            $r.Purge | Should -BeNullOrEmpty
        }
        It 'deletes to Deleted Items only after the preview and a confirmation' {
            $r = Start-NSPVCardImport -Path $script:vcf -OutputDirectory $script:out -PurgeMode DeletedItems
            $script:removeCalls.Count | Should -Be 2
            $script:removeCalls[0].WhatIf | Should -BeTrue
            $script:removeCalls[1].WhatIf | Should -BeFalse
            $script:removeCalls[1].Permanent | Should -BeFalse
            Should -Invoke Read-NSPConfirm -Times 1
            $r.Purge.Deleted | Should -Be 3
        }
        It 'does not delete when the confirmation is declined' {
            Mock Read-NSPConfirm { $false }
            Start-NSPVCardImport -Path $script:vcf -OutputDirectory $script:out -PurgeMode Permanent | Out-Null
            @($script:removeCalls | Where-Object { -not $_.WhatIf }).Count | Should -Be 0
        }
        It 'passes Permanent and keeps an existing app-only session' {
            Mock Get-MgContext { [pscustomobject]@{AuthType='AppOnly';AppName='synthetic';TenantId='00000000-0000-0000-0000-000000000000'} }
            Start-NSPVCardImport -Path $script:vcf -OutputDirectory $script:out -PurgeMode Permanent -UserId other@example.test | Out-Null
            Should -Invoke Connect-NSPGraph -Times 0
            $script:removeCalls[1].Permanent | Should -BeTrue
            $script:removeCalls[1].WhatIf | Should -BeFalse
            $script:removeCalls[1].UserId | Should -Be 'other@example.test'
        }
    }
}
