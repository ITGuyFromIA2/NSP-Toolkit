function Get-NSPToolAnswers {
    <#
    .SYNOPSIS
        Reads a tool's saved answers from its work folder (Answers\Answers.json). Returns $null when
        there are none or the file does not parse (with a warning).

    .EXAMPLE
        $answers = Get-NSPToolAnswers -Tool AD
        if ($answers) { $answers.CompanyName }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+$')][string]$Tool)

    $file = Join-Path (Get-NSPToolWorkPath -Tool $Tool -Kind Answers) 'Answers.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $raw = [IO.File]::ReadAllText($file)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return (ConvertFrom-Json -InputObject $raw -ErrorAction Stop) }
    catch {
        Write-Warning "$file does not parse ($($_.Exception.Message)) - ignoring it."
        return $null
    }
}
