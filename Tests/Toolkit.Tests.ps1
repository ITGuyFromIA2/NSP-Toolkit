<#
    Pester 5. Every test points NSP_TOOLKIT_ROOT at $TestDrive, so nothing under ProgramData is
    touched, and builds any "old install" it needs inside $TestDrive.
#>

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.Toolkit.psd1') -Force -ErrorAction Stop
    $script:Fixtures = Join-Path $PSScriptRoot 'Fixtures'
}

AfterAll {
    Remove-Item Env:\NSP_TOOLKIT_ROOT -ErrorAction SilentlyContinue
    Remove-Module NSP.Toolkit -Force -ErrorAction SilentlyContinue
}

Describe 'NSP.Toolkit' {

BeforeEach {
    $env:NSP_TOOLKIT_ROOT = Join-Path $TestDrive ('tk_' + [guid]::NewGuid().ToString('N'))
}

Describe 'Hand-off files' {
    It 'round-trips a payload with a valid hash' {
        $payload = [ordered]@{ Name = "O'Brien " + [char]0x00EB; List = @('one'); Nested = @{ A = 1 } }
        $file = New-NSPHandoff -Kind Response -Tool NPS -Company 'Example Co.' -Payload $payload -ToolVersion '0.1.0' |
            Export-NSPHandoff -Directory $TestDrive
        $file.Name | Should -Be 'ExampleCo_NPS_Response.json'
        $h = Import-NSPHandoff -Path $file.FullName
        $h.Tool | Should -Be 'NPS'
        $h.Kind | Should -Be 'Response'
        $h.Legacy | Should -BeFalse
        $h.HashValid | Should -BeTrue
        $h.Payload.Name | Should -Be ("O'Brien " + [char]0x00EB)
        @($h.Payload.List).Count | Should -Be 1
        $h.Payload.List -is [array] | Should -BeTrue
    }

    It 'flags a payload edited after it was written' {
        $file = New-NSPHandoff -Kind Answers -Tool AD -Company X -Payload @{ Secret = 'a' } | Export-NSPHandoff -Directory $TestDrive
        (Get-Content $file.FullName -Raw).Replace('"a"', '"b"') | Set-Content $file.FullName -NoNewline
        $h = Import-NSPHandoff -Path $file.FullName -WarningVariable w -WarningAction SilentlyContinue
        $h.HashValid | Should -BeFalse
        $w | Should -Not -BeNullOrEmpty
    }

    It 'reports an unverifiable hash for a re-saved file instead of failing' {
        $file = New-NSPHandoff -Kind Answers -Tool AD -Company X -Payload @{ A = 1 } | Export-NSPHandoff -Directory $TestDrive
        $obj = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $obj | Add-Member -NotePropertyName Extra -NotePropertyValue 1
        $obj | ConvertTo-Json -Depth 5 | Set-Content $file.FullName
        (Import-NSPHandoff -Path $file.FullName).HashValid | Should -BeNullOrEmpty
    }

    It 'refuses the wrong tool or kind, unknown files and newer envelopes' {
        $file = New-NSPHandoff -Kind Answers -Tool AD -Company X -Payload @{ A = 1 } | Export-NSPHandoff -Directory $TestDrive
        { Import-NSPHandoff -Path $file.FullName -Tool NPS } | Should -Throw '*not NPS*'
        { Import-NSPHandoff -Path $file.FullName -Kind Response } | Should -Throw '*not Response*'
        $other = Join-Path $TestDrive 'other.json'; '{"Hello": 1}' | Set-Content $other
        { Import-NSPHandoff -Path $other } | Should -Throw '*not a hand-off file*'
        (Get-Content $file.FullName -Raw) -replace '"EnvelopeVersion":[ ]*1', '"EnvelopeVersion": 2' | Set-Content $file.FullName
        { Import-NSPHandoff -Path $file.FullName } | Should -Throw '*version 2*'
    }

    It 'wraps the zip-era <Format> file as a <Tool> response' -ForEach @(
        @{ File = 'ExampleCo_CAResponse.json'; Tool = 'PKI'; Format = 'CAResponse'; Schema = 4; Company = 'Example Co' }
        @{ File = 'Example_NPSResponse.json'; Tool = 'NPS'; Format = 'NPSResponse'; Schema = 1; Company = 'Example Co' }
        @{ File = 'ADInventory_example.test_20260115_100000.json'; Tool = 'AD'; Format = 'ADInventory'; Schema = 1; Company = '' }
    ) {
        $h = Import-NSPHandoff -Path (Join-Path $Fixtures $File)
        $h.Tool | Should -Be $Tool
        $h.Kind | Should -Be 'Response'
        $h.Legacy | Should -BeTrue
        $h.LegacyFormat | Should -Be $Format
        $h.PayloadSchema | Should -Be $Schema
        $h.Company | Should -Be $Company
        $h.HashValid | Should -BeNullOrEmpty
        # The payload is the old file's own object, untouched.
        $orig = Get-Content (Join-Path $Fixtures $File) -Raw | ConvertFrom-Json
        (ConvertTo-Json $h.Payload -Depth 20 -Compress) | Should -Be (ConvertTo-Json $orig -Depth 20 -Compress)
    }
}

Describe 'Work folder and answers' {
    It 'puts each tool under the toolkit root and creates on request' {
        $p = Get-NSPToolWorkPath -Tool NPS -Kind Responses
        $p | Should -Be (Join-Path $env:NSP_TOOLKIT_ROOT 'NPS\Responses')
        Test-Path $p | Should -BeFalse
        Get-NSPToolWorkPath -Tool NPS -Kind Responses -Create | Out-Null
        Test-Path $p | Should -BeTrue
    }

    It 'saves and reads answers' {
        Get-NSPToolAnswers -Tool AD | Should -BeNullOrEmpty
        Save-NSPToolAnswers -Tool AD -Answers @{ CompanyName = 'Example Co'; Groups = @('a') }
        (Get-NSPToolAnswers -Tool AD).CompanyName | Should -Be 'Example Co'
    }

    It 'seeds answers the first time, then merges later seeds keeping live values' {
        Import-NSPToolSeedAnswers -Tool NPS -SeedAnswersJson '{"CompanyName":"Example Co","RADIUSSecret":"s1"}' | Out-Null
        (Get-NSPToolAnswers -Tool NPS).RADIUSSecret | Should -Be 's1'
        $merged = Import-NSPToolSeedAnswers -Tool NPS -SeedAnswersJson '{"CompanyName":"Changed","NewField":"n"}' -NonInteractive
        $merged.CompanyName | Should -Be 'Example Co'
        $merged.NewField | Should -Be 'n'
        $merged.RADIUSSecret | Should -Be 's1'
    }

    It 'accepts an Answers hand-off as the seed and refuses one for another tool' {
        $h = New-NSPHandoff -Kind Answers -Tool AD -Company X -Payload @{ CompanyName = 'From envelope' }
        $json = ConvertTo-Json $h -Depth 20
        (Import-NSPToolSeedAnswers -Tool AD -SeedAnswersJson $json).CompanyName | Should -Be 'From envelope'
        { Import-NSPToolSeedAnswers -Tool NPS -SeedAnswersJson $json } | Should -Throw '*for the AD tool*'
    }

    It 'does nothing with a blank seed' {
        Import-NSPToolSeedAnswers -Tool PKI -SeedAnswersJson '' | Should -BeNullOrEmpty
        Test-Path (Get-NSPToolWorkPath -Tool PKI -Kind Answers) | Should -BeFalse
    }
}

Describe 'Merge-NSPHandoffAnswers prompts' {
    BeforeAll {
        $script:Live = [pscustomobject]@{ A = 1; B = 2; C = 3; OnlyLive = 'x' }
        $script:Incoming = [pscustomobject]@{ A = 10; B = 20; C = 30; New = 'n' }
    }
    It 'takes incoming for I and keeps live for L' {
        $script:answers = [Collections.Generic.Queue[string]]::new([string[]]@('i', 'l', 'l'))
        Mock -ModuleName NSP.Toolkit Read-Host { $script:answers.Dequeue() }
        Mock -ModuleName NSP.Toolkit Write-Host { }
        $r = Merge-NSPHandoffAnswers -Live $Live -Incoming $Incoming
        $r.Answers.A | Should -Be 10
        $r.Answers.B | Should -Be 2
        $r.Answers.OnlyLive | Should -Be 'x'
        $r.Answers.New | Should -Be 'n'
        $r.Differing | Should -Be 3
        $r.TookIncoming | Should -Be 1
    }
    It 'stops asking after A (all incoming) or S (skip, keep live)' {
        Mock -ModuleName NSP.Toolkit Write-Host { }
        Mock -ModuleName NSP.Toolkit Read-Host { 'a' }
        $r = Merge-NSPHandoffAnswers -Live $Live -Incoming $Incoming
        $r.TookIncoming | Should -Be 3
        Should -Invoke -ModuleName NSP.Toolkit Read-Host -Times 1 -Exactly
        Mock -ModuleName NSP.Toolkit Read-Host { 's' }
        $r = Merge-NSPHandoffAnswers -Live $Live -Incoming $Incoming
        $r.TookIncoming | Should -Be 0
    }
    It 'keeps live when the session cannot prompt' {
        Mock -ModuleName NSP.Toolkit Write-Host { }
        Mock -ModuleName NSP.Toolkit Read-Host { throw 'NonInteractive' }
        (Merge-NSPHandoffAnswers -Live $Live -Incoming $Incoming).TookIncoming | Should -Be 0
    }
}

Describe 'Dry-run step engine' {
    BeforeEach { Mock -ModuleName NSP.Toolkit Write-Host { } }
    AfterAll { Set-NSPDryRun -Enabled $true }

    It 'describes but does not run in dry run (the default)' {
        Get-NSPDryRun | Should -BeTrue
        $script:ran = $false
        $r = Invoke-NSPStep -Description 'x' -Action { $script:ran = $true }
        $r.Ran | Should -BeFalse
        $script:ran | Should -BeFalse
    }
    It 'runs, captures output and errors when applying' {
        Set-NSPDryRun -Enabled $false
        (Invoke-NSPStep -Description 'x' -Action { 42 }).Output | Should -Be 42
        { Invoke-NSPStep -Description 'x' -Action { throw 'boom' } } | Should -Throw 'boom'
        (Invoke-NSPStep -Description 'x' -Action { throw 'boom' } -ContinueOnError).Error | Should -Be 'boom'
        Set-NSPDryRun -Enabled $true
    }
}

Describe 'Get-NSPToolVersionStatus' {
    It 'reports first run, update, downgrade and no change' {
        $dir = Join-Path $TestDrive 'versions'
        (Get-NSPToolVersionStatus -ToolKey T -Version '1.0.0' -StateDir $dir).Status | Should -Be 'FirstRun'
        $u = Get-NSPToolVersionStatus -ToolKey T -Version '1.1.0' -StateDir $dir
        $u.Status | Should -Be 'Updated'
        $u.Label | Should -Be 'v1.1.0  (updated from v1.0.0)'
        (Get-NSPToolVersionStatus -ToolKey T -Version '1.1.0' -StateDir $dir).Status | Should -Be 'Unchanged'
        (Get-NSPToolVersionStatus -ToolKey T -Version '1.0.5' -StateDir $dir).Status | Should -Be 'Downgraded'
    }
}

Describe 'Move-NSPToolLegacyData' {
    BeforeEach {
        Mock -ModuleName NSP.Toolkit Write-Host { }
        $script:Old = Join-Path $TestDrive ('old_' + [guid]::NewGuid().ToString('N'))
        $extract = Join-Path $Old 'NPSStaging\NPSManager'
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        '{"CompanyName":"Old Co","RADIUSSecret":"old-secret","OldOnly":"o"}' | Set-Content (Join-Path $extract 'NPSAnswers.json')
        '{"SchemaVersion":1,"IasXml":{}}' | Set-Content (Join-Path $extract 'OldCo_NPSResponse.json')
        [IO.File]::WriteAllBytes((Join-Path $extract 'cert.pfx'), [byte[]](1, 2, 3))
        $script:Shim = Join-Path $Old 'NPS-Manager.ps1'
        @"
`$NPSShimVersion = 4
`$NPSAnswersJson = @'
{"CompanyName":"Shim Co","FromShim":"s"}
'@
Write-Output 'shim body'
"@ | Set-Content $Shim
    }

    It 'changes nothing under -WhatIf' {
        $r = Move-NSPToolLegacyData -Tool NPS -SearchPath $Old -WhatIf
        $r.Found | Should -BeTrue
        Test-Path (Join-Path $Old 'NPSStaging') | Should -BeTrue
        Get-NSPToolAnswers -Tool NPS | Should -BeNullOrEmpty
        (Get-Content $Shim -Raw) | Should -Match 'Shim Co'
    }

    It 'moves answers and files in, then removes the old copies' {
        Save-NSPToolAnswers -Tool NPS -Answers @{ CompanyName = 'Live Co' }
        $r = Move-NSPToolLegacyData -Tool NPS -SearchPath $Old -NonInteractive
        $a = Get-NSPToolAnswers -Tool NPS
        $a.CompanyName | Should -Be 'Live Co'
        $a.RADIUSSecret | Should -Be 'old-secret'
        $a.OldOnly | Should -Be 'o'
        $a.FromShim | Should -Be 's'
        $legacyDir = Join-Path (Get-NSPToolWorkPath -Tool NPS -Kind Responses) 'Legacy'
        Test-Path (Join-Path $legacyDir 'cert.pfx') | Should -BeTrue
        Test-Path (Join-Path $legacyDir 'OldCo_NPSResponse.json') | Should -BeTrue
        Test-Path (Join-Path $Old 'NPSStaging') | Should -BeFalse
        $shimText = Get-Content $Shim -Raw
        $shimText | Should -Not -Match 'Shim Co'
        $shimText | Should -Match 'shim body'
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseInput($shimText, [ref]$null, [ref]$parseErrors) | Out-Null
        $parseErrors | Should -BeNullOrEmpty
        @($r.FoldersRemoved).Count | Should -Be 1
        @(Get-ChildItem (Get-NSPToolWorkPath -Tool NPS -Kind Logs) -Filter 'LegacyCleanup_*.log').Count | Should -Be 1
        (Get-Content (Get-ChildItem (Get-NSPToolWorkPath -Tool NPS -Kind Logs) -Filter 'LegacyCleanup_*.log').FullName -Raw) | Should -Not -Match 'old-secret'
    }

    It 'leaves the old files when the operator says no' {
        Mock -ModuleName NSP.Toolkit Read-Host { 'n' }
        Move-NSPToolLegacyData -Tool NPS -SearchPath $Old | Out-Null
        Test-Path (Join-Path $Old 'NPSStaging') | Should -BeTrue
        (Get-NSPToolAnswers -Tool NPS).CompanyName | Should -Not -BeNullOrEmpty
    }

    It 'reports nothing found on a clean server' {
        (Move-NSPToolLegacyData -Tool AD -SearchPath $Old).Found | Should -BeFalse
    }
}

Describe 'Clear-NSPToolClientData' {
    BeforeEach { Mock -ModuleName NSP.Toolkit Write-Host { } }

    It 'blanks only the secret fields' {
        Save-NSPToolAnswers -Tool NPS -Answers @{ CompanyName = 'Example Co'; RADIUSSecret = 'shh' }
        Clear-NSPToolClientData -Tool NPS -WhatIf
        (Get-NSPToolAnswers -Tool NPS).RADIUSSecret | Should -Be 'shh'
        Clear-NSPToolClientData -Tool NPS -Confirm:$false
        $a = Get-NSPToolAnswers -Tool NPS
        $a.RADIUSSecret | Should -Be ''
        $a.CompanyName | Should -Be 'Example Co'
        (Get-Content (Join-Path (Get-NSPToolWorkPath -Tool NPS -Kind Logs) 'ClientDataCleared.log') -Raw) | Should -Not -Match 'shh'
    }

    It 'deletes everything with -All' {
        Save-NSPToolAnswers -Tool NPS -Answers @{ CompanyName = 'Example Co' }
        Clear-NSPToolClientData -Tool NPS -All -Confirm:$false
        Get-NSPToolAnswers -Tool NPS | Should -BeNullOrEmpty
    }
}

Describe 'Launcher' {
    It 'lists the four tools' {
        $t = @(Get-NSPToolkitTool)
        ($t.Name -join ',') | Should -Be 'AD,NPS,PKI,FortiClient'
        ($t | Where-Object Name -eq NPS).SecretFields | Should -Contain 'RADIUSSecret'
    }

    It 'starts a named tool without the menu' {
        Mock -ModuleName NSP.Toolkit Invoke-NSPToolkitTool { }
        Mock -ModuleName NSP.Toolkit Import-NSPToolkitModule { }
        Start-NSPToolkit -Tool AD -NoElevate
        Should -Invoke -ModuleName NSP.Toolkit Invoke-NSPToolkitTool -Times 1 -Exactly -ParameterFilter { $Tool -eq 'AD' }
    }

    It 'refuses an unknown tool' {
        Mock -ModuleName NSP.Toolkit Import-NSPToolkitModule { }
        { Start-NSPToolkit -Tool Nope -NoElevate } | Should -Throw '*Unknown tool*'
    }
}

}   # Describe NSP.Toolkit
