function Start-NSPVCardImport {
    <#
    .SYNOPSIS
        Converts a vCard export (Apple Contacts) into Outlook import CSV batches and, optionally,
        clears the target mailbox's contacts first.
    .DESCRIPTION
        Loads NSP.LogParse 0.1.1+ (and NSP.M365.Graph 0.1.4+ for a purge) from installed modules
        or PSGallery, never a sibling checkout. NSP_NO_AUTOINSTALL=1 prevents installation.

        1. Convert: Export-NSPOutlookContactCsv writes OutlookContacts_NNN.csv batches, an
           ImportManifest.csv and a work\ folder (what moved to Notes, what was skipped, possible
           duplicates) to the output folder. Nothing leaves this computer.
        2. Purge (optional): signs in to Graph with delegated Contacts.ReadWrite (the signed-in
           user's own mailbox) unless an app-only session is already connected, then runs
           Remove-NSPGraphMailboxContact -WhatIf: inventory and a verified JSON backup, no delete.
           Only after that, and a confirmation, does it delete: to Deleted Items, or with
           PurgeMode Permanent through permanentDelete. Phones syncing over ActiveSync lose the
           contacts too.
        3. Import: the batches are imported in Outlook by hand (File > Open & Export > Import/Export
           > Import from another program or file > Comma Separated Values), in manifest order.

        Toolkit DRY RUN and -WhatIf: a preview only. No installation, no file is written, no
        sign-in and no mailbox change. When NSP.LogParse is already installed, the vCard is parsed
        in memory to report how many cards and batches the conversion would produce.
    .PARAMETER Path
        The .vcf file (or a .jsonl from an earlier parse). Prompted when omitted.
    .PARAMETER OutputDirectory
        Where the batches go. Prompted when omitted; default is OutlookImport beside the source.
        Keep it outside Git: it holds the contacts.
    .PARAMETER BatchSize
        Contacts per CSV batch.
    .PARAMETER Overwrite
        Replace existing OutlookContacts_*.csv batches in the output folder.
    .PARAMETER Reparse
        Parse the vCard again even though an earlier parse of the same file is present.
    .PARAMETER PurgeMode
        None, Preview (inventory and backup only), DeletedItems or Permanent. Prompted when omitted.
    .PARAMETER UserId
        The mailbox to purge. Default: the signed-in account.
    .PARAMETER BackupDirectory
        Where Remove-NSPGraphMailboxContact writes its backup. Default: its own default.
    .PARAMETER LocalOnly
        Convert only: no Graph module, sign-in or mailbox change.
    .EXAMPLE
        Start-NSPToolkit -Tool VCFImport
    .EXAMPLE
        Start-NSPVCardImport -Path .\Contacts.vcf -OutputDirectory .\OutlookImport -LocalOnly
    .EXAMPLE
        Start-NSPVCardImport -Path .\Contacts.vcf -OutputDirectory .\OutlookImport -PurgeMode Preview
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Path,
        [string]$OutputDirectory,
        [ValidateRange(1, 100000)][int]$BatchSize = 1500,
        [switch]$Overwrite,
        [switch]$Reparse,
        [ValidateSet('None', 'Preview', 'DeletedItems', 'Permanent')][string]$PurgeMode,
        [string]$UserId,
        [string]$BackupDirectory,
        [switch]$LocalOnly
    )
    if ($LocalOnly -and $PurgeMode -and $PurgeMode -ne 'None') { throw '-LocalOnly converts only; it cannot be combined with a purge.' }

    $dryRun = Get-NSPDryRun
    if ($dryRun -or $WhatIfPreference) {
        $label = if ($dryRun) { 'DRY RUN' } else { 'WhatIf' }
        Write-Host "${label}: preview only - no installation, no files written, no sign-in, no mailbox change."
        if (-not $Path -and (Get-Command Read-NSPFilePath -ErrorAction SilentlyContinue)) {
            $Path = Read-NSPFilePath -Prompt 'vCard file to preview (.vcf)' -Filter 'vCard (*.vcf)|*.vcf|Parsed vCard (*.jsonl)|*.jsonl|All files (*.*)|*.*' -AllowBack
            if (Test-NSPBackSignal $Path) { return }
        }
        if ($Path -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The vCard file '$Path' does not exist." }
        $logParse = Get-Module -ListAvailable -Name NSP.LogParse | Where-Object { $_.Version -ge [version]'0.1.1' } | Sort-Object Version -Descending | Select-Object -First 1
        $cards = $null
        if (-not $logParse) {
            Write-Host 'Would install NSP.LogParse 0.1.1+ from PSGallery.'
        } elseif ($Path -and [IO.Path]::GetExtension($Path) -ne '.jsonl') {
            Import-Module -Name $logParse.Path -Global -ErrorAction Stop
            $cards = @(ConvertFrom-NSPVCard -Path $Path).Count
            Write-Host "Parsed in memory: $cards card(s), about $([math]::Ceiling($cards / $BatchSize)) batch(es) of up to $BatchSize. Nothing was written."
        }
        $target = if ($OutputDirectory) { $OutputDirectory } elseif ($Path) { Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Path).ProviderPath) 'OutlookImport' } else { '(prompted)' }
        Write-Host "Would write the Outlook CSV batches to: $target"
        $purgeNote = if ($LocalOnly -or $PurgeMode -eq 'None') { 'no mailbox purge' } elseif ($PurgeMode) { "mailbox purge mode $PurgeMode (sign-in, backup, then delete after confirmation)" } else { 'a prompt for a mailbox purge' }
        Write-Host "Would then offer: $purgeNote."
        return [pscustomobject]@{ Preview = $true; Path = $Path; OutputDirectory = $target; Cards = $cards; PurgeMode = $PurgeMode }
    }

    if (-not $PSCmdlet.ShouldProcess('vCard import', 'Load Gallery dependencies and write Outlook CSV batches')) { return }
    Import-NSPGalleryToolModule -Name NSP.Console -MinimumVersion 0.1.5
    Import-NSPGalleryToolModule -Name NSP.LogParse -MinimumVersion 0.1.1

    if (-not $Path) {
        $Path = Read-NSPFilePath -Prompt 'vCard file to convert (.vcf)' -Filter 'vCard (*.vcf)|*.vcf|Parsed vCard (*.jsonl)|*.jsonl|All files (*.*)|*.*' -AllowBack
        if (Test-NSPBackSignal $Path) { return }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The vCard file '$Path' does not exist." }
    if (-not $OutputDirectory) {
        $default = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Path).ProviderPath) 'OutlookImport'
        $OutputDirectory = Read-NSPFolderPath -Prompt 'Output folder for the Outlook CSV batches' -Default $default -Create -AllowBack
        if (Test-NSPBackSignal $OutputDirectory) { return }
    }

    $convert = @{ Path = $Path; OutputDirectory = $OutputDirectory; BatchSize = $BatchSize }
    if ($Overwrite) { $convert.Overwrite = $true }
    if ($Reparse) { $convert.Reparse = $true }
    Write-Host "Converting $Path ..."
    $conversion = Export-NSPOutlookContactCsv @convert
    Write-Host ("{0} cards: {1} exported in {2} batch(es), {3} skipped, {4} possible duplicates, {5} values moved to Notes or dropped ({6:N1} s)." -f `
            $conversion.Cards, $conversion.Exported, @($conversion.Batches).Count, $conversion.Skipped, $conversion.PossibleDuplicates, $conversion.Extras, $conversion.Seconds)
    Write-Host "Review $(Join-Path $conversion.OutputDirectory 'work') before importing."

    $result = [pscustomobject]@{ Conversion = $conversion; Purge = $null; PurgePreview = $null }

    if ($LocalOnly) { $PurgeMode = 'None' }
    if (-not $PurgeMode) {
        $PurgeMode = Read-NSPMenu -Prompt 'Clear the mailbox contacts before importing?' -CancelLabel 'Skip' -Choices @(
            [pscustomobject]@{ Label = 'No - convert only'; Value = 'None' }
            [pscustomobject]@{ Label = 'Preview: inventory and back up the mailbox contacts, delete nothing'; Value = 'Preview' }
            [pscustomobject]@{ Label = 'Back up, then move every contact to Deleted Items'; Value = 'DeletedItems' }
            [pscustomobject]@{ Label = 'Back up, then permanently delete every contact (Recoverable Items only)'; Value = 'Permanent' }
        )
        if ($null -eq $PurgeMode) { $PurgeMode = 'None' }
    }

    if ($PurgeMode -ne 'None') {
        Import-NSPGalleryToolModule -Name NSP.M365.Graph -MinimumVersion 0.1.4
        $context = if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) { Get-MgContext } else { $null }
        if (-not ($context -and "$($context.AuthType)" -eq 'AppOnly')) {
            $context = Connect-NSPGraph -Scopes 'Contacts.ReadWrite' -Connect
            if (-not $context -and (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) { $context = Get-MgContext }
        }
        if (-not $UserId) {
            if ($context -and $context.Account) { $UserId = [string]$context.Account }
            else { $UserId = Read-NSPNonEmpty -Prompt 'Mailbox to clear (UPN)' }
        }
        $authLabel = if ($context -and "$($context.AuthType)" -eq 'AppOnly') { "app-only ($($context.AppName))" } else { "delegated as $($context.Account)" }
        Write-Host "Mailbox: $UserId  Tenant: $($context.TenantId)  Session: $authLabel"

        $purge = @{ UserId = $UserId }
        if ($BackupDirectory) { $purge.BackupDirectory = $BackupDirectory }
        $preview = Remove-NSPGraphMailboxContact @purge -WhatIf
        $result.PurgePreview = $preview
        Write-Host "Found $($preview.Found) contact(s) in $($preview.Folders) folder(s). Backup: $($preview.BackupPath)"

        if ($PurgeMode -in @('DeletedItems', 'Permanent') -and [int]$preview.Found -gt 0) {
            $where = if ($PurgeMode -eq 'Permanent') { 'PERMANENTLY delete' } else { 'move to Deleted Items' }
            if (Read-NSPConfirm -Prompt "$where all $($preview.Found) contact(s) in $UserId? Phones syncing this mailbox lose them too") {
                if ($PurgeMode -eq 'Permanent') { $purge.Permanent = $true }
                $result.Purge = Remove-NSPGraphMailboxContact @purge -Confirm:$false
                Write-Host "Deleted $($result.Purge.Deleted), already gone $($result.Purge.AlreadyGone), failed $(@($result.Purge.Failed).Count), remaining $($result.Purge.Remaining)."
            } else {
                Write-Host 'Purge skipped. The backup above was still written.'
            }
        }
    }

    Write-Host ''
    Write-Host "Import in Outlook, one batch at a time in ImportManifest.csv order: $($conversion.OutputDirectory)"
    Write-Host 'File > Open & Export > Import/Export > Import from another program or file > Comma Separated Values.'
    return $result
}
