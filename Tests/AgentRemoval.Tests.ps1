# Offline: the removal script is never run. Invoke-NSPAgentRemovalScript is mocked and writes the
# status file a check would; prompts are answered from a queue.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline stubs preserve production signatures and forbid live calls.')]
param()
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.Toolkit.psd1') -Force
BeforeAll { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'NSP.Toolkit.psd1') -Force }
AfterAll { Remove-Module NSP.Toolkit -Force -ErrorAction SilentlyContinue }
Describe 'Agent removal walkthrough' {
    InModuleScope NSP.Toolkit {
        BeforeAll {
            function New-NSPAgentRemovalScript { param($Path, [string[]]$Component, $TranscriptDirectory, $Company, $GeneratedBy, [switch]$Force) Set-Content -LiteralPath $Path -Value '# synthetic' }
            function Read-NSPConfirm { param($Prompt, [switch]$DefaultYes) throw 'Interactive prompt forbidden' }
            function Write-NSPConsoleLine { param($Text, $Role) }
            function Write-NSPConsoleHeader { param($Title, $Subtitle) }
            function script:Set-CheckResult([object]$Automate, [object[]]$ScreenConnect = @(), [string[]]$ShadowProtect = @()) {
                $script:checkRecord = [ordered]@{ Status = 'ReportOnly'; Components = [ordered]@{
                    Automate = $Automate; ScreenConnect = [ordered]@{ Found = @($ScreenConnect) }; ShadowProtect = [ordered]@{ Found = @($ShadowProtect) } } }
            }
        }
        BeforeEach {
            $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $script:root 'Logs') -Force | Out-Null
            $script:calls = New-Object System.Collections.Generic.List[object]
            $script:answers = New-Object System.Collections.Generic.Queue[bool]
            Set-CheckResult -Automate ([ordered]@{ Found = $true; ServerAddress = 'https://automate.example.test' }) `
                -ScreenConnect @([ordered]@{ Id = '0123456789abcdef'; Host = 'relay-a.example.test' }, [ordered]@{ Id = 'fedcba9876543210'; Host = 'relay-b.example.test' })
            $script:dryRun = $true
            $script:dryRunSets = New-Object System.Collections.Generic.List[bool]
            Mock Test-NSPAgentRemovalElevated { $true }
            Mock Import-NSPGalleryToolModule { }
            Mock Get-NSPToolWorkPath { if ($Kind -eq 'Logs') { Join-Path $script:root 'Logs' } else { $script:root } }
            Mock Get-NSPDryRun { $script:dryRun }
            Mock Set-NSPDryRun { $script:dryRun = $Enabled; $script:dryRunSets.Add($Enabled) }
            Mock Read-NSPConfirm { if ($script:answers.Count) { $script:answers.Dequeue() } else { throw "Unexpected prompt: $Prompt" } }
            Mock Invoke-NSPAgentRemovalScript {
                $script:calls.Add([pscustomobject]@{ Arguments = @($ArgumentList); Quiet = [bool]$Quiet; DryRun = $script:dryRun })
                $i = [array]::IndexOf(@($ArgumentList), '-StatusPath')
                if ($i -ge 0) { [IO.File]::WriteAllText($ArgumentList[$i + 1], (ConvertTo-Json -InputObject $script:checkRecord -Depth 8)) }
                0
            }
        }
        It 'is a Toolkit entry that needs elevation and loads NSP.ClientScripts 0.1.8 from the Gallery' {
            $def = Get-NSPToolDefinition AgentRemoval
            $def.EntryFunction | Should -Be 'Start-NSPAgentRemoval'
            $def.ModuleName | Should -Be 'NSP.ClientScripts'
            $def.RequiresAdmin | Should -BeTrue
            Mock Test-NSPAgentRemovalElevated { $false }
            { Start-NSPAgentRemoval } | Should -Throw '*elevated*'
            Should -Invoke Import-NSPGalleryToolModule -Times 0
        }
        It 'checks quietly in report-only mode and stops when nothing is installed' {
            Set-CheckResult -Automate ([ordered]@{ Found = $false; ServerAddress = '' })
            $r = Start-NSPAgentRemoval
            $script:calls.Count | Should -Be 1
            $script:calls[0].Quiet | Should -BeTrue
            $script:calls[0].Arguments | Should -Contain '-ReportOnly'
            $r.Selected | Should -BeNullOrEmpty
            Should -Invoke Import-NSPGalleryToolModule -Times 1 -ParameterFilter { $Name -eq 'NSP.ClientScripts' -and $MinimumVersion -eq '0.1.8' }
        }
        It 'removes nothing and leaves DRY RUN on when the live run is declined' {
            foreach ($a in $true, $true, $false, $false) { $script:answers.Enqueue($a) }   # Automate yes, SC 1 yes, SC 2 no, live no
            $r = Start-NSPAgentRemoval
            $script:calls.Count | Should -Be 1
            @($r.Selected.Instances) | Should -Be @('0123456789abcdef')
            $script:dryRunSets.Count | Should -Be 0
            $script:dryRun | Should -BeTrue
        }
        It 'switches to a live run for only the picked items, then turns DRY RUN back on' {
            foreach ($a in $true, $false, $true, $true, $false) { $script:answers.Enqueue($a) }  # Automate yes, SC1 no, SC2 yes, live yes, recheck no
            $r = Start-NSPAgentRemoval
            $script:calls.Count | Should -Be 2
            $live = $script:calls[1]
            $live.DryRun | Should -BeFalse
            $live.Quiet | Should -BeFalse
            $live.Arguments | Should -Not -Contain '-ReportOnly'
            $live.Arguments[[array]::IndexOf($live.Arguments, '-Component') + 1] | Should -Be 'Automate,ScreenConnect'
            $live.Arguments[[array]::IndexOf($live.Arguments, '-InstanceId') + 1] | Should -Be 'fedcba9876543210'
            @($script:dryRunSets) | Should -Be @($false, $true)
            $script:dryRun | Should -BeTrue
            $r.ExitCode | Should -Be 0
        }
        It 'turns DRY RUN back on even when the removal fails' {
            foreach ($a in $true, $false, $false, $true) { $script:answers.Enqueue($a) }
            Mock Invoke-NSPAgentRemovalScript {
                $script:calls.Add([pscustomobject]@{ Arguments = @($ArgumentList); Quiet = [bool]$Quiet; DryRun = $script:dryRun })
                if ($ArgumentList -contains '-ReportOnly') {
                    $i = [array]::IndexOf(@($ArgumentList), '-StatusPath')
                    [IO.File]::WriteAllText($ArgumentList[$i + 1], (ConvertTo-Json -InputObject $script:checkRecord -Depth 8)); 0
                } else { throw 'child failed' }
            }
            { Start-NSPAgentRemoval } | Should -Throw '*child failed*'
            $script:dryRun | Should -BeTrue
        }
        It 'offers ShadowProtect only when found, and leaves the ScreenConnect component out when no instance is picked' {
            Set-CheckResult -Automate ([ordered]@{ Found = $false; ServerAddress = '' }) -ScreenConnect @([ordered]@{ Id = '0123456789abcdef'; Host = 'relay-a.example.test' }) -ShadowProtect @('ShadowProtect SPX 7.5')
            $script:dryRun = $false
            foreach ($a in $false, $true, $true, $false) { $script:answers.Enqueue($a) }   # SC no, ShadowProtect yes, remove yes, recheck no
            Mock Invoke-NSPAgentRemovalScript {
                $script:calls.Add([pscustomobject]@{ Arguments = @($ArgumentList); Quiet = [bool]$Quiet; DryRun = $script:dryRun })
                $i = [array]::IndexOf(@($ArgumentList), '-StatusPath')
                [IO.File]::WriteAllText($ArgumentList[$i + 1], (ConvertTo-Json -InputObject $script:checkRecord -Depth 8))
                if ($ArgumentList -contains '-ReportOnly') { 0 } else { 3010 }
            }
            $r = Start-NSPAgentRemoval
            $live = $script:calls[1]
            $live.Arguments[[array]::IndexOf($live.Arguments, '-Component') + 1] | Should -Be 'ShadowProtect'
            $live.Arguments | Should -Not -Contain '-InstanceId'
            $r.ExitCode | Should -Be 3010
            $script:dryRunSets.Count | Should -Be 0 -Because 'DRY RUN was already off'
        }
        It 'changes nothing when nothing is picked' {
            foreach ($a in $false, $false, $false) { $script:answers.Enqueue($a) }
            Start-NSPAgentRemoval | Out-Null
            $script:calls.Count | Should -Be 1
            $script:dryRunSets.Count | Should -Be 0
        }
        It 'CheckOnly stops after the check' {
            Start-NSPAgentRemoval -CheckOnly | Out-Null
            $script:calls.Count | Should -Be 1
            Should -Invoke Read-NSPConfirm -Times 0
        }
    }
}
