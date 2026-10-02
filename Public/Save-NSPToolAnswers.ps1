function Save-NSPToolAnswers {
    <#
    .SYNOPSIS
        Saves a tool's answers to its work folder (Answers\Answers.json), creating the folder.

    .DESCRIPTION
        Writes to a temporary file first and then replaces Answers.json, so an interrupted save never
        leaves half a file behind. $null answers are not written.

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
    $dir = Get-NSPToolWorkPath -Tool $Tool -Kind Answers -Create
    $file = Join-Path $dir 'Answers.json'
    if ($PSCmdlet.ShouldProcess($file, 'Save answers')) {
        $json = ConvertTo-Json -InputObject $Answers -Depth 20
        $tmp = "$file.tmp"
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $file -Force
    }
}
