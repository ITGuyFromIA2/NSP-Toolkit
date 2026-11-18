function Start-NSPToolkit {
    <#
    .SYNOPSIS
        The single entry point: a menu of every NSP operator tool. Picking one installs its module
        from the PowerShell Gallery if needed, then starts it.

    .DESCRIPTION
        Relaunches elevated first, except named UserPairing discovery, and preserves DRY RUN.
        Tools that apply to this
        machine - NPS on an NPS server, PKI on a CA - are marked. -Tool skips the menu.
        Needs NSP.Console and NSP.Bootstrap; they are loaded on first use.

    .PARAMETER Tool
        Start this tool directly (AD, NPS, PKI, FortiClient, MDE, LocalAccounts, ScanBridge, UserPairing,
        VCFImport - or VCF).

    .PARAMETER NoElevate
        Do not relaunch elevated.

    .EXAMPLE
        Start-NSPToolkit

    .EXAMPLE
        Start-NSPToolkit -Tool NPS
    #>
    [CmdletBinding()]
    param(
        [string]$Tool,
        [switch]$NoElevate
    )

    Import-NSPToolkitModule -Name NSP.Bootstrap -MinimumVersion 0.1.3
    Import-NSPToolkitModule -Name NSP.Console -MinimumVersion 0.1.2

    # A named tool that needs no admin rights (UserPairing, VCFImport) is not elevated.
    $named = if ($Tool) { Get-NSPToolDefinition -Tool $Tool } else { $null }
    if ($named) { $Tool = $named.Name }
    if (-not $NoElevate -and -not ($named -and -not $named.RequiresAdmin)) {
        # By path, so a checkout or -ModuleRoot copy relaunches the same build, not an installed one.
        $manifest = (Join-Path $script:ModuleRoot 'NSP.Toolkit.psd1').Replace("'", "''")
        $mode = if (Get-NSPDryRun) { '$true' } else { '$false' }
        $relaunch = "Import-Module '$manifest'; Set-NSPDryRun -Enabled $mode -Confirm:`$false; Start-NSPToolkit"
        if ($Tool) { $relaunch += " -Tool '$($Tool.Replace("'", "''"))'" }
        if (Invoke-NSPElevated -Command $relaunch -NoExit) { return }
    }

    if ($Tool) {
        Invoke-NSPToolkitTool -Tool $Tool
        return
    }

    while ($true) {
        Clear-NSPConsole
        $toolkitVersion = (Get-Module NSP.Toolkit | Sort-Object Version -Descending | Select-Object -First 1).Version
        Write-NSPConsoleHeader -Title 'NSP Toolkit' -Subtitle "$env:COMPUTERNAME  v$toolkitVersion"
        Write-NSPConsoleLine ''
        $tools = @(Get-NSPToolkitTool)
        $choices = foreach ($t in $tools) {
            $status = if ($t.Installed) { "installed v$($t.Installed)" } else { 'not installed - picking it installs it' }
            $mark = if ($t.Applies) { "  [applies here: $($t.DetectHint)]" } else { '' }
            [pscustomobject]@{ Label = $t.DisplayName + $mark; Value = $t.Name; Help = "$($t.Description)  ($($t.ModuleName), $status)" }
        }
        $pick = Read-NSPMenu -Choices $choices -Prompt 'Start a tool' -CancelLabel 'Quit'
        if ($null -eq $pick) { return }
        try { Invoke-NSPToolkitTool -Tool $pick }
        catch {
            Write-NSPConsoleLine "Could not start ${pick}: $($_.Exception.Message)" -Role Error
            Read-Host 'Press Enter to return to the menu' | Out-Null
        }
    }
}
