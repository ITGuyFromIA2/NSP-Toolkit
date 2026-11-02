# ScanBridge dispatch alerting setup: sender discovery, a scoped alert app and the settings PSD1's
# Alerts block. Nothing tenant- or client-specific lives here; every value comes from the operator,
# the tenant, the existing settings or the saved Toolkit answers.

$script:NSPScanBridgeAddressPattern='^[A-Za-z0-9.!%+_\-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'

function ConvertTo-NSPPsd1Text {
    # Value -> PSD1 literal text. Dictionaries keep their key order; nested lines are indented by
    # $Indent per level beyond $Level.
    param([AllowNull()][object]$Value,[int]$Level=0,[string]$Indent='  ',[string]$NewLine="`r`n")
    if($null -eq $Value) { return '$null' }
    if($Value -is [bool]) { return $(if($Value){'$true'}else{'$false'}) }
    if($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
    if($Value -is [Collections.IDictionary]) {
        $inner=$Indent*($Level+1)
        $lines=foreach($key in $Value.Keys) {
            $name=if([string]$key -match '^[A-Za-z_][A-Za-z0-9_]*$'){[string]$key}else{"'$(([string]$key) -replace "'","''")'"}
            '{0}{1} = {2}' -f $inner,$name,(ConvertTo-NSPPsd1Text -Value $Value[$key] -Level ($Level+1) -Indent $Indent -NewLine $NewLine)
        }
        return '@{'+$NewLine+(@($lines) -join $NewLine)+$NewLine+($Indent*$Level)+'}'
    }
    if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $items=@($Value)
        if(@($items | Where-Object { $_ -is [Collections.IDictionary] }).Count) {
            # A list of tables (such as Routes): one table per block, indented one level.
            $inner=$Indent*($Level+1)
            $blocks=foreach($item in $items) { $inner+(ConvertTo-NSPPsd1Text -Value $item -Level ($Level+1) -Indent $Indent -NewLine $NewLine) }
            return '@('+$NewLine+(@($blocks) -join $NewLine)+$NewLine+($Indent*$Level)+')'
        }
        return '@('+(($items | ForEach-Object { ConvertTo-NSPPsd1Text -Value $_ -Level $Level -Indent $Indent -NewLine $NewLine }) -join ', ')+')'
    }
    "'"+(([string]$Value) -replace "'","''")+"'"
}

function Set-NSPPsd1TopLevelEntry {
    <#
        Replaces (or appends) one top-level key of a PSD1 file in place, leaving every other byte,
        comment and the file's encoding alone. Returns the old and new entry text; -WhatIf only
        previews. The original is kept as <file>.<UTC stamp>.bak before writing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Key,[Parameter(Mandatory)][object]$Value)
    if($Value -isnot [Collections.IDictionary] -and -not ($Value -is [Collections.IEnumerable] -and $Value -isnot [string])) { throw 'A settings entry value must be a table or a list.' }
    $bytes=[IO.File]::ReadAllBytes($Path)
    $bom=$bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text=[IO.File]::ReadAllText($Path)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    if($errors.Count) { throw "Settings file does not parse: $($errors[0].Message)" }
    $root=$ast.Find({param($node) $node -is [Management.Automation.Language.HashtableAst]},$false)
    if(-not $root) { throw 'Settings file has no top-level hashtable.' }
    $newLine=if($text.Contains("`r`n")){"`r`n"}else{"`n"}
    $pair=@($root.KeyValuePairs | Where-Object { $_.Item1.Extent.Text.Trim("'",'"') -eq $Key })[0]
    if($pair) {
        $lineStart=$text.LastIndexOf("`n",[Math]::Max(0,$pair.Item1.Extent.StartOffset-1))+1
        $keyIndent=$text.Substring($lineStart,$pair.Item1.Extent.StartOffset-$lineStart)
        $step=if($keyIndent.Length){$keyIndent}else{'  '}
        $level=[Math]::Max(0,[int]($keyIndent.Length/[Math]::Max(1,$step.Length)))
        $valueText=ConvertTo-NSPPsd1Text -Value $Value -Level $level -Indent $step -NewLine $newLine
        $old=$pair.Item2.Extent.Text
        $updated=$text.Substring(0,$pair.Item2.Extent.StartOffset)+$valueText+$text.Substring($pair.Item2.Extent.EndOffset)
    } else {
        $first=@($root.KeyValuePairs)[0]
        $step='  '
        if($first) { $ls=$text.LastIndexOf("`n",[Math]::Max(0,$first.Item1.Extent.StartOffset-1))+1; $candidate=$text.Substring($ls,$first.Item1.Extent.StartOffset-$ls); if($candidate -match '^\s+$'){$step=$candidate} }
        $valueText=ConvertTo-NSPPsd1Text -Value $Value -Level 1 -Indent $step -NewLine $newLine
        $old=$null
        $close=$root.Extent.EndOffset-1
        $before=$text.Substring(0,$close).TrimEnd()
        $updated=$before+$newLine+$step+$Key+' = '+$valueText+$newLine+$text.Substring($close)
    }
    $check=[Management.Automation.Language.Parser]::ParseInput($updated,[ref]$tokens,[ref]$errors)
    if($errors.Count -or -not $check) { throw 'The updated settings would not parse; nothing was written.' }
    $result=[pscustomobject]@{Path=$Path;Key=$Key;OldText=$old;NewText=$valueText;BackupPath=$null;Written=$false}
    if($PSCmdlet.ShouldProcess($Path,"Update $Key")) {
        $result.BackupPath='{0}.{1}.bak' -f $Path,[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        [IO.File]::Copy($Path,$result.BackupPath,$false)
        $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try {
            [IO.File]::WriteAllText($temp,$updated,(New-Object Text.UTF8Encoding($bom)))
            [IO.File]::Replace($temp,$Path,[NullString]::Value)
        } finally { if(Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        $result.Written=$true
    }
    $result
}

function Test-NSPScanBridgeElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-NSPScanBridgeCertificateTarget {
    # Where an app certificate lives: a local service account (computer store; key read granted
    # later), this account's store, or the computer store for SYSTEM. Returns @{Store;ServiceAccount}
    # or $null when the operator backs out or the choice cannot work here.
    param([Parameter(Mandatory)][string]$Purpose,[Parameter(Mandatory)][Collections.IDictionary]$Answers,[bool]$DryRun)
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $store=Read-NSPMenu -Prompt "Where should the $Purpose certificate live?" -CancelLabel 'Back' -Choices @(
        [pscustomobject]@{Label='Service account (computer store, key readable by that account only)';Value='ServiceAccount';Help='For a dedicated local ScanBridge account: certificate in Cert:\LocalMachine\My, read access to its private key granted to that one account. Needs an elevated session.'}
        [pscustomobject]@{Label="This account's store (Cert:\CurrentUser\My, $identity)";Value='Cert:\CurrentUser\My';Help='Choose when the ScanBridge task runs as this account: run setup signed in as the service account.'}
        [pscustomobject]@{Label='Computer store (Cert:\LocalMachine\My)';Value='Cert:\LocalMachine\My';Help='Choose when the task runs as SYSTEM. Needs an elevated session.'}
    )
    if($null -eq $store) { return $null }
    $serviceAccount=$null
    if($store -eq 'ServiceAccount') {
        Import-NSPToolkitModule -Name NSP.Win.LocalAccount -MinimumVersion 0.1.0
        $typed=Read-NSPNonEmpty -Prompt 'Local account the ScanBridge task runs as (.\name)' -CurrentValue $(if($Answers.ServiceAccount){'.\'+[string]$Answers.ServiceAccount}else{''})
        $serviceAccount=ConvertTo-NSPLocalAccountName -Account $typed
        if(-not $serviceAccount) { Write-NSPConsoleLine "'$typed' is not a local account name on this computer (use .\name)." -Role Error; return $null }
        $found=try { Get-NSPLocalServiceAccount -Name $serviceAccount } catch { Write-NSPConsoleLine $_.Exception.Message -Role Error; return $null }
        if(-not $found) {
            if(-not $DryRun) { Write-NSPConsoleLine "Local account '$serviceAccount' does not exist. Create it with 'Prepare a local service account' first." -Role Error; return $null }
            Write-NSPConsoleLine "Local account '$serviceAccount' does not exist yet; create it before the real run." -Role Warning
        }
        $store='Cert:\LocalMachine\My'
    }
    if($store -like 'Cert:\LocalMachine\*' -and -not (Test-NSPScanBridgeElevated)) { Write-NSPConsoleLine 'The computer certificate store needs an elevated session. Restart PowerShell as administrator.' -Role Error; return $null }
    @{Store=$store;ServiceAccount=$serviceAccount}
}

function Grant-NSPScanBridgeCertificateKey {
    # Plans, then on confirm grants, read access to an app certificate's private key for one local
    # service account, and remembers that account as the ScanBridge default.
    param([Parameter(Mandatory)][string]$ServiceAccount,[Parameter(Mandatory)][string]$Thumbprint,[Parameter(Mandatory)][string]$Purpose,[Parameter(Mandatory)][Collections.IDictionary]$Answers,[bool]$DryRun)
    $grant=Grant-NSPLocalAccountCertificateAccess -Name $ServiceAccount -Thumbprint $Thumbprint
    Write-NSPConsoleLine ("Key access plan: {0} read on {1}." -f $grant.Rights,$grant.Account)
    if(-not $DryRun -and (Read-NSPConfirm -Prompt "Give $($grant.Account) read access to the $Purpose certificate's private key?" -DefaultYes)) {
        $grant=Grant-NSPLocalAccountCertificateAccess -Name $ServiceAccount -Thumbprint $Thumbprint -Execute -Confirm:$false
    }
    if($grant.Status -eq 'Granted') { Write-NSPConsoleLine "Granted. A renewed certificate has a new key: re-run this setup after renewal to grant it again." -Role Success }
    else { Write-NSPConsoleLine "Key access not granted; $ServiceAccount cannot sign in as the $Purpose app yet." -Role Warning }
    if(-not $DryRun -and $ServiceAccount -ne $Answers.ServiceAccount) { $Answers.ServiceAccount=$ServiceAccount; Save-NSPToolAnswers -Tool ScanBridge -Answers $Answers -Confirm:$false }
}

function Test-NSPPlaceholderValue {
    param([AllowNull()][object]$Value)
    [string]::IsNullOrWhiteSpace([string]$Value) -or ([string]$Value) -match '^<.*>$'
}

function Read-NSPScanBridgeAlertSender {
    # Search-and-pick, or a typed address resolved in the tenant. Returns a Find-NSPGraphMailbox
    # result, or $null when the operator backs out.
    param([string]$SearchTerm='scan',[string]$CurrentSender)
    $hintHelp=@{
        LikelyShared='Likely a shared mailbox (sign-in disabled, no license): a good sender.'
        LicensedUser='Licensed account that signs in (a person, or a copier using SMTP). Works; sent items land there.'
        Unlicensed='Enabled but unlicensed: may have no mailbox. The Exchange scoping step confirms it.'
        DisabledLicensed='Sign-in disabled but still licensed: check whether it is still in use.'
    }
    $term=$SearchTerm
    while($true) {
        $found=@(Find-NSPGraphMailbox -Search $term)
        $choices=@(foreach($mailbox in $found) {
            [pscustomobject]@{Label=('{0} <{1}>' -f $mailbox.DisplayName,$mailbox.Mail);Value=$mailbox;Help=$hintHelp[$mailbox.MailboxHint]}
        })
        if(-not $found.Count) { Write-NSPConsoleLine "No mail-enabled member accounts match '$term'." -Role Warning }
        if($CurrentSender) { $choices+=[pscustomobject]@{Key='C';Label="Keep the current sender <$CurrentSender>";Value='Current';Help='Re-checked in the tenant before use.'} }
        $choices+=[pscustomobject]@{Key='S';Label='Search with a different term';Value='Search';Help="Matches the start of words in name, address and sign-in name. Current term: '$term'."}
        $choices+=[pscustomobject]@{Key='T';Label='Type an exact address';Value='Type';Help='Resolved in this tenant (mail, sign-in name or alias) before use.'}
        $pick=Read-NSPMenu -Choices $choices -Prompt 'Choose the mailbox alerts are sent from' -CancelLabel 'Back'
        if($null -eq $pick) { return $null }
        if($pick -eq 'Search') { $term=Read-NSPNonEmpty -Prompt 'Search term' -CurrentValue $term; continue }
        $address=if($pick -eq 'Current'){$CurrentSender}elseif($pick -eq 'Type'){Read-NSPNonEmpty -Prompt 'Sender address'}else{$null}
        if(-not $address) { return $pick }
        $exact=@(Find-NSPGraphMailbox -Address $address)
        if($exact.Count -eq 1) { return $exact[0] }
        Write-NSPConsoleLine "'$address' does not resolve to exactly one mail-enabled member account in this tenant." -Role Warning
    }
}

function Invoke-NSPScanBridgeAlertSetup {
    <#
        Configures ScanBridge dispatch alerting for the client whose settings PSD1 is given:
        recipient (saved Toolkit default), sender (found in the tenant), a dedicated app with no
        Graph permissions, Exchange RBAC Mail.Send scoped to that sender, the Alerts block, and an
        optional test message. Each tenant or file change is planned first and confirmed; DRY RUN
        stops after the plans.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    Import-NSPToolkitModule -Name NSP.M365.Graph -MinimumVersion 0.1.2
    foreach($command in 'Find-NSPGraphMailbox','Set-NSPGraphMailSendScope') {
        if(-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "NSP.M365.Graph does not provide $command. Provision the build with dispatch alerting support first." }
    }
    $dryRun=[bool](Get-NSPDryRun)
    $config=Import-PowerShellDataFile -LiteralPath $ConfigurationPath -ErrorAction Stop
    $current=if($config.Alerts -is [Collections.IDictionary]){$config.Alerts}else{@{}}
    $saved=Get-NSPToolAnswers -Tool ScanBridge
    $answers=[ordered]@{}
    if($saved) { foreach($p in $saved.PSObject.Properties) { $answers[$p.Name]=$p.Value } }

    # 1. Recipient: an NSP-wide saved default, never a value in source.
    $default=if($answers.DispatchAddress){[string]$answers.DispatchAddress}elseif(-not (Test-NSPPlaceholderValue $current.To)){[string]$current.To}else{''}
    do {
        $to=(Read-NSPNonEmpty -Prompt 'Dispatch (ticket) address alerts are sent to' -CurrentValue $default).Trim()
        if($to -notmatch $script:NSPScanBridgeAddressPattern) { Write-NSPConsoleLine 'Enter a single mail address.' -Role Warning }
    } until($to -match $script:NSPScanBridgeAddressPattern)
    if($to -ne $answers.DispatchAddress -and -not $dryRun) {
        $answers.DispatchAddress=$to
        Save-NSPToolAnswers -Tool ScanBridge -Answers $answers -Confirm:$false
        Write-NSPConsoleLine 'Saved as the default dispatch address for future clients on this computer.' -Role Muted
    }

    # 2. Delegated sign-in to the client tenant (read users, create the app).
    $method=Read-NSPMenu -Prompt 'Sign in to the client tenant as an administrator' -CancelLabel 'Back' -Choices @(
        [pscustomobject]@{Label='Windows sign-in';Value='Broker';Help='Account picker / browser prompt. It can open behind other windows.'}
        [pscustomobject]@{Label='Device code';Value='DeviceCode';Help='Enter a code at microsoft.com/devicelogin from any browser; best over remote sessions.'}
    )
    if($null -eq $method) { return }
    $connect=@{Scopes=@('User.Read.All','Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Organization.Read.All');Connect=$true}
    if($method -eq 'DeviceCode') { $connect.UseDeviceCode=$true }
    $context=Connect-NSPGraph @connect
    $ingestionTenant=if($config.Auth -is [Collections.IDictionary]){[string]$config.Auth.TenantId}else{''}
    if(-not (Test-NSPPlaceholderValue $ingestionTenant) -and $ingestionTenant -ne $context.TenantId) {
        throw "Signed in to tenant $($context.TenantId), but this ScanBridge configuration uses tenant $ingestionTenant. Sign in to the client's tenant."
    }
    Write-NSPConsoleLine ('Signed in as {0} to tenant {1}.' -f $context.Account,$context.TenantId) -Role Muted

    # 3. Sender, found in the tenant.
    $currentFrom=if(Test-NSPPlaceholderValue $current.From){$null}else{[string]$current.From}
    $searchTerm=if($answers.SenderSearch){[string]$answers.SenderSearch}else{'scan'}
    $fromMailbox=Read-NSPScanBridgeAlertSender -SearchTerm $searchTerm -CurrentSender $currentFrom
    if($null -eq $fromMailbox) { return }
    Write-NSPConsoleLine ('Sender: {0} <{1}> ({2}).' -f $fromMailbox.DisplayName,$fromMailbox.Mail,$fromMailbox.MailboxHint) -Role Muted

    # 4. Dedicated alert app: no Graph permissions; mail access comes only from the scoped role.
    $appName=Read-NSPOptional -Prompt 'Alert app name' -Default $(if($answers.AlertAppName){[string]$answers.AlertAppName}else{'NSP-ScanBridge-Alerts'})
    $recordDirectory=Read-NSPOptional -Prompt 'Folder for the alert app record (client ID and thumbprint, never a key)' -Default (Join-Path (Split-Path -Parent $ConfigurationPath) 'AlertApp')
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $target=Read-NSPScanBridgeCertificateTarget -Purpose 'alert' -Answers $answers -DryRun $dryRun
    if($null -eq $target) { return }
    $store=$target.Store; $serviceAccount=$target.ServiceAccount
    $register=@{AppName=$appName;ApplicationPermissions=@();RecordDirectory=$recordDirectory;CertificateStore=$store;TenantId=$context.TenantId}
    $app=Register-NSPGraphAppOnlyRegistration @register
    if($app.Status -eq 'ExistingUnrecorded') { Write-NSPConsoleLine $app.Message -Role Error; return }
    if($app.Status -eq 'PlanOnly') {
        Write-NSPConsoleLine ("Alert app plan: {0}." -f ($app.Actions -join ', '))
        if($serviceAccount) { Write-NSPConsoleLine "Then: read access to the new certificate's private key for $serviceAccount only." }
        if($dryRun) { Write-NSPConsoleLine 'DRY RUN: no app, certificate, key access or Exchange scope created; the Alerts block is unchanged.' -Role Warning; return }
        if(-not (Read-NSPConfirm -Prompt "Create or repair '$appName' in tenant $($context.TenantId) now?")) { return }
        $app=Register-NSPGraphAppOnlyRegistration @register -Execute -Confirm:$false
    }
    $record=Get-Content -LiteralPath $app.RecordPath -Raw | ConvertFrom-Json
    if(-not $dryRun -and $appName -ne $answers.AlertAppName) { $answers.AlertAppName=$appName; Save-NSPToolAnswers -Tool ScanBridge -Answers $answers -Confirm:$false }
    if($serviceAccount) { Grant-NSPScanBridgeCertificateKey -ServiceAccount $serviceAccount -Thumbprint $record.CertificateThumbprint -Purpose 'alert' -Answers $answers -DryRun $dryRun }

    # 5. Exchange RBAC for Applications: Mail.Send as this sender only.
    Write-NSPConsoleLine 'Exchange Online sign-in follows (an Exchange administrator is needed to scope the app).' -Role Muted
    $scopeArgs=@{ClientId=$record.ClientId;ServicePrincipalId=$record.ServicePrincipalId;Mailbox=$fromMailbox.Mail;Connect=$true}
    $scope=Set-NSPGraphMailSendScope @scopeArgs
    if($scope.Status -in @('UnscopedEntraGrant','ConflictingAssignment')) { Write-NSPConsoleLine $scope.Message -Role Error; return }
    if($scope.Status -eq 'PlanOnly') {
        Write-NSPConsoleLine ("Mail scope plan for {0}: {1}." -f $scope.PrimarySmtpAddress,($scope.Actions -join ', '))
        if($dryRun) { Write-NSPConsoleLine 'DRY RUN: Exchange scope not created; the Alerts block is unchanged.' -Role Warning; return }
        if(-not (Read-NSPConfirm -Prompt "Allow '$appName' to send as $($scope.PrimarySmtpAddress) only?")) { return }
        $scope=Set-NSPGraphMailSendScope @scopeArgs -Execute -Confirm:$false
    }
    Write-NSPConsoleLine $scope.Message -Role $(if($scope.Verified){'Success'}else{'Warning'})
    if(-not $scope.Verified -and -not (Read-NSPConfirm -Prompt 'Write the Alerts settings anyway?')) { return }

    # 6. Alert state folder.
    $stateDefault=if(Test-NSPPlaceholderValue $current.StateDirectory){'C:\ProgramData\NSP\ScanBridge\AlertState'}else{[string]$current.StateDirectory}
    $stateDirectory=Read-NSPOptional -Prompt 'Alert state folder (restricted; the task account needs modify access)' -Default $stateDefault
    if(-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
        if($dryRun) { Write-NSPConsoleLine "DRY RUN: would create $stateDirectory." -Role Warning }
        elseif(Read-NSPConfirm -Prompt "Create $stateDirectory now?" -DefaultYes) { New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null }
        else { Write-NSPConsoleLine 'Alerting fails until the state folder exists.' -Role Warning }
    }
    Write-NSPConsoleLine 'Grant the task account modify access to the state folder with "Prepare a local service account" if it is not already covered.' -Role Muted

    # 7. Alerts block, previewed then written with a backup.
    $enable=Read-NSPMenu -Prompt 'Alerting state' -CancelLabel 'Back' -Choices @(
        [pscustomobject]@{Label='Enable alerting';Value=$true;Help='The ScanBridge alert task starts sending tickets for unresolved conditions.'}
        [pscustomobject]@{Label='Write settings with alerting disabled';Value=$false;Help='Keeps Enabled = $false until a test message has reached dispatch.'}
    )
    if($null -eq $enable) { return }
    $alerts=[ordered]@{Enabled=[bool]$enable;From=[string]$scope.PrimarySmtpAddress;To=$to;StateDirectory=$stateDirectory
        Auth=[ordered]@{TenantId=[string]$record.TenantId;ClientId=[string]$record.ClientId;CertificateThumbprint=[string]$record.CertificateThumbprint}}
    foreach($key in @($current.Keys | Where-Object { $_ -notin $alerts.Keys } | Sort-Object)) { $alerts[$key]=$current[$key] }
    $preview=Set-NSPPsd1TopLevelEntry -Path $ConfigurationPath -Key Alerts -Value $alerts -WhatIf
    Write-NSPConsoleLine 'Current Alerts:' -Role Muted
    Write-Host $(if($preview.OldText){$preview.OldText}else{'(none)'})
    Write-NSPConsoleLine 'New Alerts:' -Role Muted
    Write-Host $preview.NewText
    if($dryRun) { Write-NSPConsoleLine 'DRY RUN: settings file not changed.' -Role Warning; return }
    if(-not (Read-NSPConfirm -Prompt "Write this Alerts block to $ConfigurationPath (a backup is kept)?")) { return }
    $written=Set-NSPPsd1TopLevelEntry -Path $ConfigurationPath -Key Alerts -Value $alerts -Confirm:$false
    Write-NSPConsoleLine "Settings updated; backup at $($written.BackupPath)." -Role Success

    # 8. Optional test message through the new app.
    if(-not (Read-NSPConfirm -Prompt "Send a test message to $to now, signed in as the alert app?")) { return }
    try {
        Connect-NSPGraphAppOnly -ClientId $record.ClientId -TenantId $record.TenantId -CertificateThumbprint $record.CertificateThumbprint -ContextScope Process | Out-Null
        $body=@(
            'This is a ScanBridge alert setup test. No action is needed.'
            ('Computer: {0}' -f [Environment]::MachineName)
            ('Sent (UTC): {0}' -f [DateTime]::UtcNow.ToString('u'))
        ) -join [Environment]::NewLine
        Send-NSPGraphMail -From $scope.PrimarySmtpAddress -To $to -Subject '[NSP.ScanBridge] Alert setup test' -Body $body -ErrorAction Stop
        Write-NSPConsoleLine 'Graph accepted the test message. Confirm with dispatch that a ticket arrived; acceptance is not delivery.' -Role Success
        if($serviceAccount) { Write-NSPConsoleLine "This test ran as $identity; it does not prove $serviceAccount can read the key. The first scheduled alert run does." -Role Muted }
    } catch {
        Write-NSPConsoleLine "Test message failed: $($_.Exception.Message)" -Role Error
        Write-NSPConsoleLine 'A new Exchange scope can take up to two hours to apply to sendMail. The certificate must be in this account''s chosen store.' -Role Warning
    }
}
