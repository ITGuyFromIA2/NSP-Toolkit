function Set-NSPDryRun {
    <#
    .SYNOPSIS
        Turns DRY RUN on or off for every NSP tool in this session.
    .EXAMPLE
        Set-NSPDryRun -Enabled $false   # APPLY: Invoke-NSPStep really runs steps
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][bool]$Enabled)
    if ($PSCmdlet.ShouldProcess('NSP tools in this session', "Set dry run to $Enabled")) {
        $script:NSPDryRun = $Enabled
    }
}
