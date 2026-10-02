function Get-NSPToolkitTool {
    <#
    .SYNOPSIS
        Lists the tools Start-NSPToolkit can launch, with whether each is installed and whether it
        applies to this machine.

    .DESCRIPTION
        Applies runs each tool's detection check (e.g. "NPS service installed"); it is a hint for
        the menu, not a restriction. Installed is the newest installed version of the tool's module,
        or $null.

    .PARAMETER Name
        Return only this tool (wildcards allowed).

    .EXAMPLE
        Get-NSPToolkitTool | Format-Table Name, ModuleName, Installed, Applies
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name = '*')

    foreach ($def in @($script:NSPToolDefinitions | Where-Object { $_.Name -like $Name })) {
        $installed = Get-Module -ListAvailable -Name $def.ModuleName | Sort-Object Version -Descending | Select-Object -First 1
        $applies = $false
        try { $applies = [bool](& $def.Detect) } catch { $applies = $false }
        [pscustomobject]@{
            PSTypeName     = 'NSP.ToolkitTool'
            Name           = $def.Name
            DisplayName    = $def.DisplayName
            Description    = $def.Description
            ModuleName     = $def.ModuleName
            MinimumVersion = $def.MinimumVersion
            EntryFunction  = $def.EntryFunction
            ShimFunction   = $def.ShimFunction
            Installed      = if ($installed) { [string]$installed.Version } else { $null }
            Applies        = $applies
            DetectHint     = $def.DetectHint
            SecretFields   = @($def.SecretFields)
        }
    }
}
