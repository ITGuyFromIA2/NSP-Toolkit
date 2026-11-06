function Start-NSPUserPairingSetup {
    <#
    .SYNOPSIS
        Loads published pairing dependencies and starts the Entra/AD pairing wizard.
    .DESCRIPTION
        Uses installed modules or installs their required versions from PSGallery, never a
        sibling checkout. Collects source-anchor evidence locally or from a chosen sync server;
        existing JSON and diagnostic objects remain supported. Connects with Preflight read scopes and keeps
        the wizard's existing confirmation and write boundaries. Returns the complete wizard run.
        WhatIf and the default startup preview perform no install, sign-in or collection.
        Review explicitly permits discovery and private queue saves with directory writes unavailable.
    .PARAMETER SourceAnchor
        The Verified result of Get-NSPEntraConnectSourceAnchor on the sync server.
    .PARAMETER SourceAnchorPath
        JSON exported from that diagnostic, as an optional fallback.
        Keep it outside Git; it contains directory topology.
    .PARAMETER Server
        Optional domain controller passed to the pairing wizard.
    .PARAMETER Path
        Optional review queue path passed to the pairing wizard.
    .PARAMETER SyncServer
        Optional Entra Connect Sync server hostname for confirmed read-only remote collection.
    .PARAMETER Review
        Explicitly load prerequisites and read/review while Toolkit DRY RUN stays enabled.
        Directory writes are unavailable in this mode; local review decisions can be saved.
    .EXAMPLE
        Start-NSPUserPairingSetup -SourceAnchor $anchor
    .EXAMPLE
        Start-NSPToolkit -Tool UserPairing
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Auto')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Object')][object]$SourceAnchor,
        [Parameter(Mandatory, ParameterSetName = 'File')][string]$SourceAnchorPath,
        [Parameter(ParameterSetName = 'Auto')][string]$SyncServer,
        [Parameter(ParameterSetName = 'Auto')][pscredential]$Credential,
        [switch]$Review,
        [string]$Server,
        [string]$Path
    )
    if ((Get-NSPDryRun) -and -not $Review) { Write-Host 'DRY RUN: preview only. Use Start-NSPUserPairingSetup -Review to load prerequisites, collect sync-rule evidence and open review without directory writes.'; return }
    if (-not $PSCmdlet.ShouldProcess('Entra/AD pairing', 'Load Gallery dependencies, connect with read scopes and open review')) { return }
    Write-Host $(if ($Review) { 'PAIRING REVIEW: discovery and previews; directory writes unavailable. Local decisions can be saved.' } else { 'PAIRING: discovery and review; directory actions require their separate confirmations.' })
    foreach ($dependency in @(
        @{Name='NSP.Console';MinimumVersion='0.1.5'},
        @{Name='NSP.M365.Graph';MinimumVersion='0.1.3'},
        @{Name='NSP.ActiveDirectory';MinimumVersion='0.1.13'},
        @{Name='NSP.M365.UserPairing';MinimumVersion='0.1.2'}
    )) { Import-NSPGalleryToolModule @dependency }
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $SourceAnchor = Get-Content -LiteralPath $SourceAnchorPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } elseif ($PSCmdlet.ParameterSetName -eq 'Auto') {
        $collection = @{}
        if ($SyncServer) { $collection.ComputerName = $SyncServer }
        if ($Credential) { $collection.Credential = $Credential }
        $SourceAnchor = Resolve-NSPEntraPairingSourceAnchor @collection
        if ($null -eq $SourceAnchor) { return }
    }
    if ($SourceAnchor.Provenance -ne 'Verified' -or $SourceAnchor.Strategy -notin @('ObjectGuid','ConsistencyGuid','ConsistencyGuidWithObjectGuidFallback')) {
        throw ('A Verified source-anchor diagnostic with a supported strategy is required. Review sync-server rules and retry collection. ' + (@($SourceAnchor.Reasons) -join '; '))
    }
    Connect-NSPEntraPairingGraph -Purpose Preflight | Out-Null
    $options = @{SourceAnchor=$SourceAnchor}
    if ($Review) { $options.ReadOnly = $true }
    if ($PSBoundParameters.ContainsKey('Server')) { $options.Server=$Server }
    if ($PSBoundParameters.ContainsKey('Path')) { $options.Path=$Path }
    Start-NSPEntraPairingWizard @options
}
