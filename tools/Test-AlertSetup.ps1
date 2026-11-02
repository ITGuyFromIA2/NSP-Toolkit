[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','',Justification='Offline contract intentionally shadows commands and accepts their signature; no live changes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','',Justification='State is read by the shadowed commands.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess','',Justification='Shadowed commands mirror the real signatures and record calls instead of changing anything.')]
[CmdletBinding()]
param([string]$SourceRoot)
$ErrorActionPreference='Stop'
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
. (Join-Path $SourceRoot 'Private/ScanBridgeAlertSetup.ps1')
$state=@{Checks=0}
function Check($condition,$message) {if(-not $condition){throw $message};$state.Checks++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('nsp-toolkit-alerts-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$tenant='aaaaaaaa-0000-0000-0000-000000000001'
$example=@"
@{
  # Copy to a private path outside the repository.
  LockPath = 'C:\ProgramData\NSP\ScanBridge\worker.lock'
  Auth = @{
    TenantId = '$tenant'
    ClientId = 'ingestion-client'
    CertificateThumbprint = 'INGEST'
  }
  Alerts = @{
    Enabled = `$false
    From = '<monitoring-mailbox@example.com>'
    To = '<dispatch-address@example.com>'
    StateDirectory = 'C:\ProgramData\NSP\ScanBridge\AlertState'
    Auth = @{ TenantId = '<tenant-guid>'; ClientId = '<app>'; CertificateThumbprint = '<thumb>' }
    Custom = 'kept'
  }
  Routes = @(
    @{ Name = 'Front'; Source = 'C:\Scans' } # route comment
  )
}
"@.Replace("`r`n","`n").Replace("`n","`r`n")

try {
    # Settings writer: in-place replacement keeps comments, other keys, line endings and BOM.
    $file=Join-Path $root 'replace.psd1'
    [IO.File]::WriteAllText($file,$example,(New-Object Text.UTF8Encoding($true)))
    $value=[ordered]@{Enabled=$true;From="o'brien@contoso.example";To='dispatch@contoso.example';Auth=[ordered]@{TenantId=$tenant}}
    $preview=Set-NSPPsd1TopLevelEntry -Path $file -Key Alerts -Value $value -WhatIf
    Check (-not $preview.Written -and [IO.File]::ReadAllText($file) -eq $example) 'WhatIf changed the settings file.'
    Check ($preview.OldText -match '^@\{' -and $preview.OldText -match "Custom = 'kept'") 'Preview did not return the existing block.'
    $written=Set-NSPPsd1TopLevelEntry -Path $file -Key Alerts -Value $value -Confirm:$false
    $text=[IO.File]::ReadAllText($file)
    $data=Import-PowerShellDataFile -LiteralPath $file
    Check ($written.Written -and (Test-Path -LiteralPath $written.BackupPath) -and [IO.File]::ReadAllText($written.BackupPath) -eq $example) 'Backup was not kept.'
    Check ($data.Alerts.Enabled -eq $true -and $data.Alerts.From -eq "o'brien@contoso.example" -and $data.Alerts.Auth.TenantId -eq $tenant) 'Replaced values did not round-trip.'
    Check ($data.Routes[0].Name -eq 'Front' -and $data.Auth.ClientId -eq 'ingestion-client' -and $text.Contains('# route comment') -and $text.Contains('# Copy to a private path')) 'Other content was not preserved.'
    Check ($text.Contains("`r`n  Alerts = @{`r`n    Enabled = `$true`r`n") -and $text.Contains("`r`n    Auth = @{`r`n      TenantId = '$tenant'`r`n    }`r`n  }`r`n  Routes")) 'Indentation or CRLF line endings were not matched.'
    $bytes=[IO.File]::ReadAllBytes($file)
    Check ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'BOM was not preserved.'

    $file=Join-Path $root 'append.psd1'
    [IO.File]::WriteAllText($file,"@{`n    Routes = @()`n}`n")
    Set-NSPPsd1TopLevelEntry -Path $file -Key Alerts -Value ([ordered]@{Enabled=$false}) -Confirm:$false | Out-Null
    $data=Import-PowerShellDataFile -LiteralPath $file
    $bytes=[IO.File]::ReadAllBytes($file)
    Check ($data.Alerts.Enabled -eq $false -and $data.Routes.Count -eq 0 -and [IO.File]::ReadAllText($file).Contains("`n    Alerts = @{`n        Enabled = `$false`n    }`n}") -and $bytes[0] -ne 0xEF) 'Appending a missing key failed.'
    [IO.File]::WriteAllText($file,'@{ Routes = @( }')
    $threw=$false; try { Set-NSPPsd1TopLevelEntry -Path $file -Key Alerts -Value @{} -Confirm:$false } catch { $threw=$true }
    Check $threw 'An unparseable settings file was not refused.'

    # Setup flow with every tenant, Exchange and console call shadowed.
    function Import-NSPToolkitModule { param($Name,$MinimumVersion) }
    function Get-NSPDryRun { $state.DryRun }
    function Get-NSPToolAnswers { param($Tool) $state.Answers }
    function Save-NSPToolAnswers { [CmdletBinding(SupportsShouldProcess)] param($Tool,$Answers) $state.Saved+=,([pscustomobject]$Answers) }
    function Write-NSPConsoleLine { param($Text,$Role) if($Role -eq 'Error'){$state.Errors+=,$Text} }
    function Write-Host { param($Object) }
    function Read-NSPNonEmpty { param($Prompt,$CurrentValue) $CurrentValue }
    function Read-NSPOptional { param($Prompt,$Default) $Default }
    function Read-NSPConfirm { param($Prompt,[switch]$DefaultYes) $state.Confirms+=,$Prompt; $true }
    function Read-NSPMenu {
        param($Choices,$Prompt,$CancelLabel)
        $state.Menus+=,$Prompt
        $next=$state.Menu[0]; $state.Menu=@($state.Menu | Select-Object -Skip 1)
        if($next -is [int]) { return @($Choices)[$next].Value }
        @($Choices | Where-Object { $_.Value -eq $next })[0].Value
    }
    function Connect-NSPGraph { param($Scopes,[switch]$Connect,[switch]$UseDeviceCode) $state.Scopes=$Scopes; [pscustomobject]@{TenantId=$state.Tenant;Account='admin@contoso.example'} }
    function Find-NSPGraphMailbox {
        param($Search,$Address)
        $state.Searches+=,$Search
        @([pscustomobject]@{Mail='scanner@contoso.example';DisplayName='Front Scanner';MailboxHint='LikelyShared'})
    }
    function Register-NSPGraphAppOnlyRegistration {
        [CmdletBinding(SupportsShouldProcess)] param($AppName,$ApplicationPermissions,$RecordDirectory,$CertificateStore,$TenantId,[switch]$Execute)
        $state.Register+=,[pscustomobject]@{Permissions=@($ApplicationPermissions);Execute=[bool]$Execute;Store=$CertificateStore}
        $recordPath=Join-Path $RecordDirectory "$TenantId.json"
        if(-not $Execute) { return [pscustomobject]@{Status='PlanOnly';Actions=@('CreateApplication');RecordPath=$recordPath} }
        New-Item -ItemType Directory -Path $RecordDirectory -Force | Out-Null
        @{TenantId=$TenantId;ClientId='bbbbbbbb-0000-0000-0000-000000000002';ServicePrincipalId='cccccccc-0000-0000-0000-000000000003';CertificateThumbprint='THUMB'} | ConvertTo-Json | Set-Content -LiteralPath $recordPath
        [pscustomobject]@{Status='Created';RecordPath=$recordPath}
    }
    function Set-NSPGraphMailSendScope {
        [CmdletBinding(SupportsShouldProcess)] param($ClientId,$ServicePrincipalId,$Mailbox,[switch]$Execute,[switch]$Connect)
        $state.Scope+=,[pscustomobject]@{Mailbox=$Mailbox;Execute=[bool]$Execute;ClientId=$ClientId}
        if(-not $Execute) { return [pscustomobject]@{Status='PlanOnly';Actions=@('CreateScope');PrimarySmtpAddress='scanner@contoso.example'} }
        [pscustomobject]@{Status='Scoped';Verified=$true;PrimarySmtpAddress='scanner@contoso.example';Message='ok'}
    }
    function Connect-NSPGraphAppOnly { param($ClientId,$TenantId,$CertificateThumbprint,$ContextScope) $state.AppOnly=$ContextScope }
    function Send-NSPGraphMail { param($From,$To,$Subject,$Body) $state.Mail+=,[pscustomobject]@{From=$From;To=@($To)} }
    function Reset-Flow {
        param([switch]$DryRun)
        $config=Join-Path $root ('flow-'+[guid]::NewGuid().ToString('N')+'.psd1')
        [IO.File]::WriteAllText($config,$example)
        $state.Config=$config; $state.DryRun=[bool]$DryRun; $state.Tenant=$tenant
        $state.Answers=[pscustomobject]@{DispatchAddress='dispatch@contoso.example';Other='kept'}
        $state.Saved=@(); $state.Errors=@(); $state.Confirms=@(); $state.Menus=@(); $state.Searches=@()
        $state.Register=@(); $state.Scope=@(); $state.Mail=@(); $state.AppOnly=$null
        # Sign-in, sender (first result), certificate store, enable alerting.
        $state.Menu=@('Broker',0,'Cert:\CurrentUser\My',$true)
    }

    Reset-Flow
    Invoke-NSPScanBridgeAlertSetup -ConfigurationPath $state.Config
    $data=Import-PowerShellDataFile -LiteralPath $state.Config
    Check ($state.Errors.Count -eq 0) "Happy path reported errors: $($state.Errors -join '; ')"
    Check ('User.Read.All' -in $state.Scopes -and 'Application.ReadWrite.All' -in $state.Scopes) 'Delegated sign-in scopes were incomplete.'
    Check ($state.Searches[0] -eq 'scan') 'Sender search did not default to scan.'
    Check ($state.Register.Count -eq 2 -and $state.Register[0].Permissions.Count -eq 0 -and -not $state.Register[0].Execute -and $state.Register[1].Execute -and $state.Register[1].Store -eq 'Cert:\CurrentUser\My') 'Alert app was not planned before creation with no Graph permissions.'
    Check ($state.Scope.Count -eq 2 -and -not $state.Scope[0].Execute -and $state.Scope[1].Execute -and $state.Scope[1].Mailbox -eq 'scanner@contoso.example') 'Mail scope was not planned before execution for the picked sender.'
    Check ($data.Alerts.Enabled -eq $true -and $data.Alerts.From -eq 'scanner@contoso.example' -and $data.Alerts.To -eq 'dispatch@contoso.example') 'Alerts sender/recipient not written.'
    Check ($data.Alerts.Auth.ClientId -eq 'bbbbbbbb-0000-0000-0000-000000000002' -and $data.Alerts.Auth.TenantId -eq $tenant -and $data.Alerts.Auth.CertificateThumbprint -eq 'THUMB') 'Alerts.Auth not taken from the app record.'
    Check ($data.Alerts.Custom -eq 'kept' -and $data.Auth.ClientId -eq 'ingestion-client' -and $data.Routes[0].Name -eq 'Front') 'Unrelated settings were not preserved.'
    Check ($state.Saved.Count -eq 1 -and $state.Saved[0].AlertAppName -eq 'NSP-ScanBridge-Alerts' -and $state.Saved[0].DispatchAddress -eq 'dispatch@contoso.example' -and $state.Saved[0].Other -eq 'kept') 'Saved answers were not merged.'
    Check ($state.Mail.Count -eq 1 -and $state.Mail[0].From -eq 'scanner@contoso.example' -and $state.Mail[0].To[0] -eq 'dispatch@contoso.example' -and $state.AppOnly -eq 'Process') 'Test message did not use the alert app in Process scope.'
    Check (@(Get-ChildItem -LiteralPath $root -Filter ((Split-Path -Leaf $state.Config)+'.*.bak')).Count -eq 1) 'Flow did not keep a settings backup.'

    Reset-Flow -DryRun
    Invoke-NSPScanBridgeAlertSetup -ConfigurationPath $state.Config
    Check ([IO.File]::ReadAllText($state.Config) -eq $example) 'DRY RUN changed the settings file.'
    Check ($state.Saved.Count -eq 0 -and @($state.Register | Where-Object Execute).Count -eq 0 -and $state.Scope.Count -eq 0 -and $state.Mail.Count -eq 0) 'DRY RUN saved answers or changed the tenant.'

    Reset-Flow
    $state.Tenant='dddddddd-0000-0000-0000-000000000004'
    $threw=$false; try { Invoke-NSPScanBridgeAlertSetup -ConfigurationPath $state.Config } catch { $threw=$_.Exception.Message -match 'Sign in to the client' }
    Check ($threw -and $state.Searches.Count -eq 0 -and $state.Register.Count -eq 0) 'A sign-in to another tenant was not refused before searching.'

    Microsoft.PowerShell.Utility\Write-Host ('Passed: {0} alert setup checks in {1}; tenant, Exchange and console calls mocked.' -f $state.Checks,$PSVersionTable.PSVersion)
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
