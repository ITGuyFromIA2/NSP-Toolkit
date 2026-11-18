function Start-NSPAgentRemoval {
    <#
    .SYNOPSIS
        Walks through removing the NSP Automate (AutoTek) agent, ScreenConnect access agents and,
        optionally, ShadowProtect from this computer: check, pick, then remove.
    .DESCRIPTION
        Written for someone outside NSP running it on their own server. Three steps:

        1. Check - runs NSP.ClientScripts' AgentRemoval script with -ReportOnly and shows what is
           installed: the Automate server the agent reports to, each ScreenConnect instance with
           its relay host, any ShadowProtect product. Nothing is changed.
        2. Pick - one question per item found. Nothing is typed: no instance ID or host name.
        3. Remove - under Toolkit DRY RUN (the default) it asks whether to switch to a live run for
           just these items; DRY RUN is switched back on afterwards. It then explains the result
           (done, restart needed, or what to do when something is left) and offers to check again.

        The script is generated into the Toolkit work folder (Administrators and SYSTEM only) and
        run with -File. Needs elevation: Start-NSPToolkit -Tool AgentRemoval asks for it.
        Loads NSP.ClientScripts 0.1.8+ from installed modules or PSGallery.
    .PARAMETER CheckOnly
        Stop after the check.
    .EXAMPLE
        Start-NSPToolkit -Tool AgentRemoval
    .EXAMPLE
        Start-NSPAgentRemoval -CheckOnly
    #>
    [CmdletBinding()]
    param([switch]$CheckOnly)

    if (-not (Test-NSPAgentRemovalElevated)) { throw 'Agent removal needs an elevated PowerShell. Use Start-NSPToolkit -Tool AgentRemoval, which asks for elevation.' }

    Import-NSPGalleryToolModule -Name NSP.Console -MinimumVersion 0.1.5
    Import-NSPGalleryToolModule -Name NSP.ClientScripts -MinimumVersion 0.1.8

    $root = Get-NSPToolWorkPath -Tool AgentRemoval -Create
    $logs = Get-NSPToolWorkPath -Tool AgentRemoval -Kind Logs -Create
    $script = Join-Path $root 'Remove-NSPAgents.ps1'
    New-NSPAgentRemovalScript -Path $script -Component Automate, ScreenConnect, ShadowProtect -TranscriptDirectory $logs `
        -Company $env:COMPUTERNAME -GeneratedBy 'NSP.Toolkit Start-NSPAgentRemoval' -Force -Confirm:$false | Out-Null

    $runCheck = {
        $statusFile = Join-Path $root 'check.json'
        Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
        $null = Invoke-NSPAgentRemovalScript -Path $script -ArgumentList @('-ReportOnly', '-Component', 'Automate,ScreenConnect,ShadowProtect', '-StatusPath', $statusFile) -Quiet
        if (-not (Test-Path -LiteralPath $statusFile)) { throw "The check did not finish. Its log is in $logs." }
        $c = (Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json).Components
        [pscustomobject]@{
            Automate      = [bool]$c.Automate.Found
            Server        = [string]$c.Automate.ServerAddress
            ScreenConnect = @($c.ScreenConnect.Found | Where-Object { $_ })
            ShadowProtect = @($c.ShadowProtect.Found | Where-Object { $_ })
        }
    }
    $show = {
        param($Found)
        Write-NSPConsoleLine 'Found on this server:'
        if ($Found.Automate) {
            $server = if ($Found.Server) { $Found.Server } else { '(no server recorded)' }
            Write-NSPConsoleLine "  Automate (AutoTek) agent - reports to $server"
        } else { Write-NSPConsoleLine '  Automate (AutoTek) agent - not installed' }
        if ($Found.ScreenConnect.Count) {
            foreach ($i in $Found.ScreenConnect) { Write-NSPConsoleLine "  ScreenConnect - instance $($i.Id), relay $($i.Host)" }
        } else { Write-NSPConsoleLine '  ScreenConnect - not installed' }
        if ($Found.ShadowProtect.Count) {
            foreach ($p in $Found.ShadowProtect) { Write-NSPConsoleLine "  ShadowProtect - $p" }
        } else { Write-NSPConsoleLine '  ShadowProtect - not installed' }
        Write-NSPConsoleLine ''
    }

    Write-NSPConsoleHeader -Title 'Remove NetSys+ agents' -Subtitle $env:COMPUTERNAME
    Write-NSPConsoleLine 'Step 1 of 3 - Check. Looking for the Automate (AutoTek) agent, ScreenConnect and ShadowProtect.'
    Write-NSPConsoleLine 'Nothing is changed in this step.'
    Write-NSPConsoleLine ''
    $found = & $runCheck
    & $show $found
    $result = [pscustomobject]@{ Found = $found; Selected = $null; ExitCode = $null; LogFolder = $logs }
    if (-not ($found.Automate -or $found.ScreenConnect.Count -or $found.ShadowProtect.Count)) {
        Write-NSPConsoleLine 'Nothing to remove on this server.'
        return $result
    }
    if ($CheckOnly) { return $result }

    Write-NSPConsoleLine 'Step 2 of 3 - Choose what to remove. Each question shows where the item connects to.'
    $removeAutomate = $false
    if ($found.Automate) {
        $server = if ($found.Server) { $found.Server } else { 'no recorded server' }
        $removeAutomate = Read-NSPConfirm -Prompt "Remove the Automate (AutoTek) agent that reports to $server?" -DefaultYes
    }
    $instances = @(foreach ($i in $found.ScreenConnect) {
        if (Read-NSPConfirm -Prompt "Remove ScreenConnect instance $($i.Id) (relay $($i.Host))?" -DefaultYes) { $i.Id }
    })
    $removeShadowProtect = $false
    if ($found.ShadowProtect.Count) {
        $removeShadowProtect = Read-NSPConfirm -Prompt "Also remove $($found.ShadowProtect -join ', ')? The server needs a restart afterwards."
    }
    $components = @()
    if ($removeAutomate) { $components += 'Automate' }
    if ($instances.Count) { $components += 'ScreenConnect' }
    if ($removeShadowProtect) { $components += 'ShadowProtect' }
    $result.Selected = [pscustomobject]@{ Components = $components; Instances = $instances }
    Write-NSPConsoleLine ''
    if (-not $components.Count) {
        Write-NSPConsoleLine 'Nothing selected. Nothing was changed.'
        return $result
    }
    Write-NSPConsoleLine 'Will remove:'
    if ($removeAutomate) { Write-NSPConsoleLine '  Automate (AutoTek) agent' }
    foreach ($id in $instances) { Write-NSPConsoleLine "  ScreenConnect instance $id" }
    if ($removeShadowProtect) { Write-NSPConsoleLine "  $($found.ShadowProtect -join ', ')" }
    Write-NSPConsoleLine ''

    Write-NSPConsoleLine 'Step 3 of 3 - Remove.'
    $wasDryRun = Get-NSPDryRun
    if ($wasDryRun) {
        Write-NSPConsoleLine 'The Toolkit is in DRY RUN mode, so nothing has been changed so far.'
        if (-not (Read-NSPConfirm -Prompt 'Switch to a live run and remove the items above now?')) {
            Write-NSPConsoleLine 'Still in DRY RUN. Nothing was changed.'
            return $result
        }
    } elseif (-not (Read-NSPConfirm -Prompt 'Remove the items above now?')) {
        Write-NSPConsoleLine 'Nothing was changed.'
        return $result
    }

    $arguments = @('-Component', ($components -join ','), '-StatusPath', (Join-Path $root 'removal.json'))
    if ($instances.Count) { $arguments += @('-InstanceId', ($instances -join ',')) }
    try {
        if ($wasDryRun) { Set-NSPDryRun -Enabled $false -Confirm:$false }
        Write-NSPConsoleLine 'LIVE RUN - removing...'
        $result.ExitCode = Invoke-NSPAgentRemovalScript -Path $script -ArgumentList $arguments
    } finally {
        if ($wasDryRun) { Set-NSPDryRun -Enabled $true -Confirm:$false }
    }

    Write-NSPConsoleLine ''
    switch ($result.ExitCode) {
        0 { Write-NSPConsoleLine 'Done. The selected items were removed.' }
        3010 { Write-NSPConsoleLine 'Removed. Restart this server when convenient to finish.' }
        default { Write-NSPConsoleLine "Something could not be removed (exit $($result.ExitCode)). Restart this server, then run this again. Logs: $logs" -Role Error }
    }
    if ($wasDryRun) { Write-NSPConsoleLine 'DRY RUN is back on.' }
    if (Read-NSPConfirm -Prompt 'Check this server again now?' -DefaultYes) {
        Write-NSPConsoleLine ''
        $result.Found = & $runCheck
        & $show $result.Found
    }
    return $result
}
