function Save-NSPToolAnswers {
    <#
    .SYNOPSIS
        Saves a tool's answers to its work folder (Answers\Answers.json), creating the folder.

    .DESCRIPTION
        Writes to a temporary file first and then replaces Answers.json, so an interrupted save never
        leaves half a file behind. $null answers are not written.

        Answers that hold one of the tool's secret fields (NPS RADIUSSecret, PKI FortiGatePfxPassword)
        are only written when the Toolkit root is limited to Administrators and SYSTEM: an elevated
        session locks it down, otherwise the save fails and nothing is written. A NSP_TOOLKIT_ROOT
        override (tests, portable use) is not checked - protecting that folder is the caller's job.

    .PARAMETER Tool
        Tool key.

    .PARAMETER Answers
        Object or hashtable to save.

    .EXAMPLE
        Save-NSPToolAnswers -Tool AD -Answers $script:ADAnswers
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+$')][string]$Tool,
        [Parameter(Mandatory)][AllowNull()][object]$Answers
    )

    if ($null -eq $Answers) { return }
    $def = $script:NSPToolDefinitions | Where-Object { $_.Name -eq $Tool } | Select-Object -First 1
    $secrets = @(foreach ($field in @(if ($def) { $def.SecretFields })) {
        $value = if ($Answers -is [Collections.IDictionary]) { $Answers[$field] } elseif ($Answers.PSObject.Properties[$field]) { $Answers.$field } else { $null }
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $field }
    })
    $dir = Get-NSPToolWorkPath -Tool $Tool -Kind Answers -Create
    if ($secrets.Count -and -not $env:NSP_TOOLKIT_ROOT) {
        Assert-NSPToolkitRootSecure -Root (Join-Path $env:ProgramData 'NSP\Toolkit') -Reason "$Tool answers holding $($secrets -join ', ')"
    }
    $file = Join-Path $dir 'Answers.json'
    if ($PSCmdlet.ShouldProcess($file, 'Save answers')) {
        $json = ConvertTo-Json -InputObject $Answers -Depth 20
        $tmp = "$file.tmp"
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $file -Force
    }
}
