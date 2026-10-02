function Get-NSPToolWorkPath {
    <#
    .SYNOPSIS
        Path of a tool's work folder (or one of its Answers / Responses / Logs sub-folders) under
        %ProgramData%\NSP\Toolkit, optionally creating it.

    .DESCRIPTION
        Every module-hosted tool keeps its client data here instead of next to its script: the
        answers it was seeded with or has saved, the hand-off files it writes, and its logs. When
        -Create makes the Toolkit root on an elevated session, the root's permissions are reset to
        Administrators and SYSTEM only (inherited by everything under it).

        The NSP_TOOLKIT_ROOT environment variable overrides the root (tests, portable use); no
        permissions are changed then.

    .PARAMETER Tool
        Tool key, e.g. AD, NPS, PKI, FortiClient (any letters/digits are accepted).

    .PARAMETER Kind
        Root (the tool's folder), Answers, Responses or Logs.

    .PARAMETER Create
        Create the folder if it does not exist.

    .EXAMPLE
        Get-NSPToolWorkPath -Tool NPS -Kind Responses -Create
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+$')][string]$Tool,
        [ValidateSet('Root', 'Answers', 'Responses', 'Logs')][string]$Kind = 'Root',
        [switch]$Create
    )

    $override = $env:NSP_TOOLKIT_ROOT
    $toolkitRoot = if ($override) { $override } else { Join-Path $env:ProgramData 'NSP\Toolkit' }
    $toolRoot = Join-Path $toolkitRoot $Tool
    $path = if ($Kind -eq 'Root') { $toolRoot } else { Join-Path $toolRoot $Kind }

    if ($Create -and -not (Test-Path -LiteralPath $path)) {
        $newRoot = -not (Test-Path -LiteralPath $toolkitRoot)
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        if ($newRoot -and -not $override) { Set-NSPToolkitRootAcl -Path $toolkitRoot }
    }
    return $path
}
