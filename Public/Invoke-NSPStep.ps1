$script:NSPDryRun = $true

function Invoke-NSPStep {
    <#
    .SYNOPSIS
        Runs one state-changing step - or, in DRY RUN, only describes it. Returns a result object:
        Ran, Description, Commands, Output, Error.

    .DESCRIPTION
        Every mutating action in an NSP tool goes through this (moved from the IPSec toolkit's
        DryRunEngine, where it was Invoke-CAStep). While dry run is on (the default - see
        Set-NSPDryRun) it prints what it would do and runs nothing, so a whole wizard can be walked
        on any machine with no side effects, then re-run for real. The dry-run setting is shared by
        every tool module in the session.

    .PARAMETER Description
        One-line summary, e.g. "Create OU 'VPN' under DC=example,DC=com".

    .PARAMETER Commands
        The command(s) the step would run, shown in the preview. Illustrative.

    .PARAMETER Action
        Scriptblock doing the real work; only run when dry run is off. Its output lands in .Output;
        a throw lands in .Error and is re-thrown unless -ContinueOnError.

    .PARAMETER ContinueOnError
        Record a failure in .Error instead of re-throwing it.

    .EXAMPLE
        Invoke-NSPStep -Description "Create group 'VPN_Staff'" -Commands "New-ADGroup -Name VPN_Staff ..." -Action {
            New-ADGroup -Name VPN_Staff -GroupScope Global -Path $ou
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Description,
        [string[]]$Commands = @(),
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$ContinueOnError
    )

    $dry = Get-NSPDryRun
    Write-Host ''
    $label = if ($dry) { '[DRY RUN]' } else { '[APPLY]  ' }
    $color = if ($dry) { 'Cyan' } else { 'Yellow' }
    Write-Host ('  {0} {1}' -f $label, $Description) -ForegroundColor $color
    foreach ($c in $Commands) { Write-Host "      $c" -ForegroundColor DarkGray }

    $res = [pscustomobject]@{ Ran = $false; Description = $Description; Commands = $Commands; Output = $null; Error = $null }
    if ($dry) { return $res }

    try {
        $res.Output = & $Action
        $res.Ran = $true
        Write-Host '      -> done' -ForegroundColor Green
    } catch {
        $res.Error = $_.Exception.Message
        Write-Host "      -> ERROR: $($res.Error)" -ForegroundColor Red
        if (-not $ContinueOnError) { throw }
    }
    return $res
}
