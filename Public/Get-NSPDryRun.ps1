function Get-NSPDryRun {
    <#
    .SYNOPSIS
        True while DRY RUN is on (the default): Invoke-NSPStep describes steps instead of running them.
    .EXAMPLE
        if (Get-NSPDryRun) { 'Nothing will change.' }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]$script:NSPDryRun
}
