function Get-NSPToolVersionStatus {
    <#
    .SYNOPSIS
        Compares a tool's version with the one this machine last launched, records the new one, and
        returns a header label such as "v1.2.0  (updated from v1.1.0)".

    .DESCRIPTION
        Moved from the IPSec toolkit's ToolVersion.ps1 (Get-ToolVersionStatus), same state:
        %ProgramData%\NSP\ToolVersions\<ToolKey>.txt - so a server that ran the zip-era AD-Manager
        1.1.0 shows "updated from v1.1.0" the first time the module version runs. Never throws; any
        I/O failure degrades to the plain label.

        Returns Current, Previous, Status (FirstRun / Unchanged / Updated / Downgraded) and Label.

    .PARAMETER ToolKey
        State file name, e.g. ADManager (the zip-era keys are ADManager, NPSManager, CAManager, FCT).

    .PARAMETER Version
        The version now running.

    .PARAMETER StateDir
        Override the state folder (tests).

    .EXAMPLE
        (Get-NSPToolVersionStatus -ToolKey ADManager -Version '2.0.0').Label
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$ToolKey,
        [Parameter(Mandatory)][string]$Version,
        [string]$StateDir = (Join-Path $env:ProgramData 'NSP\ToolVersions')
    )

    $result = [pscustomobject]@{ Current = $Version; Previous = $null; Status = 'FirstRun'; Label = "v$Version" }
    $stateFile = Join-Path $StateDir "$ToolKey.txt"

    try {
        if (Test-Path -LiteralPath $stateFile) {
            $prev = ([IO.File]::ReadAllText($stateFile)).Trim()
            if ($prev) {
                $result.Previous = $prev
                $cmp = $null
                try { $cmp = ([version]$Version).CompareTo([version]$prev) } catch { $cmp = $null }
                if ($null -eq $cmp) {
                    $result.Status = if ($prev -eq $Version) { 'Unchanged' } else { 'Updated' }
                } elseif ($cmp -gt 0) { $result.Status = 'Updated' }
                elseif ($cmp -lt 0) { $result.Status = 'Downgraded' }
                else { $result.Status = 'Unchanged' }
            }
        }
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Set-Content -LiteralPath $stateFile -Value $Version -Force -ErrorAction Stop
    } catch {
        Write-Verbose "Get-NSPToolVersionStatus: $($_.Exception.Message)"
    }

    $result.Label = switch ($result.Status) {
        'Updated' { "v$Version  (updated from v$($result.Previous))" }
        'Downgraded' { "v$Version  (DOWNGRADED from v$($result.Previous))" }
        default { "v$Version" }
    }
    return $result
}
