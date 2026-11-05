function Start-NSPUserPairingSetup {
    <#
    .SYNOPSIS
        Loads published pairing dependencies and starts the Entra/AD pairing wizard.
    .DESCRIPTION
        Uses installed modules or installs their required versions from PSGallery, never a
        sibling checkout. Select the verified source-anchor JSON exported on the sync server,
        or pass the diagnostic result directly. Connects with Preflight read scopes and keeps
        the wizard's existing confirmation and write boundaries. Returns the complete wizard run.
        WhatIf and Toolkit DRY RUN perform no install, sign-in, inventory or directory action.
    .PARAMETER SourceAnchor
        The Verified result of Get-NSPEntraConnectSourceAnchor on the sync server.
    .PARAMETER SourceAnchorPath
        JSON exported from that diagnostic. If neither input is given, asks for this file.
        Keep it outside Git; it contains directory topology.
    .PARAMETER Server
        Optional domain controller passed to the pairing wizard.
    .PARAMETER Path
        Optional review queue path passed to the pairing wizard.
    .EXAMPLE
        Start-NSPUserPairingSetup -SourceAnchor $anchor
    .EXAMPLE
        Start-NSPToolkit -Tool UserPairing
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'File')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Object')][object]$SourceAnchor,
        [Parameter(ParameterSetName = 'File')][string]$SourceAnchorPath,
        [string]$Server,
        [string]$Path
    )
    if (Get-NSPDryRun) { Write-Host 'DRY RUN: load published pairing dependencies, select verified source anchor, connect with read scopes, then open review.'; return }
    if (-not $PSCmdlet.ShouldProcess('Entra/AD pairing', 'Load Gallery dependencies, connect with read scopes and open review')) { return }
    foreach ($dependency in @(
        @{Name='NSP.Console';MinimumVersion='0.1.5'},
        @{Name='NSP.M365.Graph';MinimumVersion='0.1.3'},
        @{Name='NSP.ActiveDirectory';MinimumVersion='0.1.12'},
        @{Name='NSP.M365.UserPairing';MinimumVersion='0.1.0'}
    )) { Import-NSPGalleryToolModule @dependency }
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        if (-not $SourceAnchorPath) {
            Write-NSPConsoleLine -Message 'Select the source-anchor JSON exported from the sync server. No anchor is guessed from user data.'
            $SourceAnchorPath = Read-NSPFilePath -Prompt 'Verified source-anchor JSON' -Filter 'JSON files (*.json)|*.json|All files (*.*)|*.*' -AllowBack
            if (-not $SourceAnchorPath -or (Test-NSPBackSignal $SourceAnchorPath)) { return }
        }
        $SourceAnchor = Get-Content -LiteralPath $SourceAnchorPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    if ($SourceAnchor.Provenance -ne 'Verified' -or $SourceAnchor.Strategy -notin @('ObjectGuid','ConsistencyGuid','ConsistencyGuidWithObjectGuidFallback')) {
        throw 'A Verified source-anchor diagnostic with a supported strategy is required. Run Get-NSPEntraConnectSourceAnchor on the sync server; keep its evidence intact.'
    }
    Connect-NSPEntraPairingGraph -Purpose Preflight | Out-Null
    $options = @{SourceAnchor=$SourceAnchor}
    if ($PSBoundParameters.ContainsKey('Server')) { $options.Server=$Server }
    if ($PSBoundParameters.ContainsKey('Path')) { $options.Path=$Path }
    Start-NSPEntraPairingWizard @options
}
