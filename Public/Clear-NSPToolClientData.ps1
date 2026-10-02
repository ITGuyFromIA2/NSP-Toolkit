function Clear-NSPToolClientData {
    <#
    .SYNOPSIS
        Blanks the secret fields (e.g. the RADIUS shared secret) in a tool's saved answers - for
        decommissioning a server, or whenever a tech wants them gone. -All deletes the whole
        answers file. PFX files and hand-back files are never touched.

    .DESCRIPTION
        The secret fields per tool come from the tool list (Get-NSPToolkitTool). Non-secret answers
        stay, so the tool still pre-fills names and addresses next time. Asks before changing
        anything (use -Confirm:$false to skip); -WhatIf shows what would change. Logs the field
        names cleared - never their values - to the work folder's Logs\.

    .PARAMETER Tool
        Tool key: AD, NPS, PKI, FortiClient.

    .PARAMETER All
        Delete the answers file entirely.

    .EXAMPLE
        Clear-NSPToolClientData -Tool NPS

    .EXAMPLE
        Clear-NSPToolClientData -Tool NPS -All -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [switch]$All
    )

    $def = Get-NSPToolDefinition -Tool $Tool
    $file = Join-Path (Get-NSPToolWorkPath -Tool $def.Name -Kind Answers) 'Answers.json'
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host "No saved $($def.DisplayName) answers on this server." -ForegroundColor DarkGray
        return
    }

    $cleared = @()
    if ($All) {
        if ($PSCmdlet.ShouldProcess($file, 'Delete all saved answers')) {
            Remove-Item -LiteralPath $file -Force
            $cleared = @('(all answers)')
        }
    } else {
        $answers = Get-NSPToolAnswers -Tool $def.Name
        if ($null -eq $answers) { return }
        $present = @($def.SecretFields | Where-Object { $answers.PSObject.Properties[$_] -and -not [string]::IsNullOrEmpty([string]$answers.$_) })
        if (-not $present.Count) {
            Write-Host "No secret fields are stored in the $($def.DisplayName) answers." -ForegroundColor DarkGray
            return
        }
        if ($PSCmdlet.ShouldProcess($file, "Blank $($present -join ', ')")) {
            foreach ($f in $present) { $answers.$f = '' }
            Save-NSPToolAnswers -Tool $def.Name -Answers $answers -Confirm:$false
            $cleared = $present
        }
    }

    if ($cleared.Count) {
        Write-Host "Cleared: $($cleared -join ', ')" -ForegroundColor Green
        $logDir = Get-NSPToolWorkPath -Tool $def.Name -Kind Logs -Create
        Add-Content -LiteralPath (Join-Path $logDir 'ClientDataCleared.log') -Value ('{0}  cleared {1}' -f (Get-Date -Format 's'), ($cleared -join ', '))
    }
}
