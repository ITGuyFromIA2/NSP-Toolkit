function Get-NSPLegacyShimAnswersPattern {
    param([Parameter(Mandatory)][string]$Variable)
    # $NPSAnswersJson = @'<newline> ... <newline>'@ - the zip-era shims' embedded answers block.
    return '(?s)(\$' + [regex]::Escape($Variable) + " = @'\r?\n)(.*?)(\r?\n'@)"
}

function Get-NSPLegacyShimAnswers {
    # The non-blank JSON embedded in a zip-era shim, or $null.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Variable)
    try { $text = [IO.File]::ReadAllText($Path) } catch { return $null }
    $m = [regex]::Match($text, (Get-NSPLegacyShimAnswersPattern -Variable $Variable))
    if (-not $m.Success) { return $null }
    $json = $m.Groups[2].Value.Trim()
    if (-not $json -or -not $json.StartsWith('{')) { return $null }
    return $json
}

function Clear-NSPLegacyShimAnswers {
    # Empties the embedded answers block, keeping the file's encoding (BOM or not) and checking the
    # result still parses before writing. Returns $true when the file was changed.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Variable)
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $text = [IO.File]::ReadAllText($Path)
        $blanked = [regex]::Replace($text, (Get-NSPLegacyShimAnswersPattern -Variable $Variable), '$1$3')
        if ($blanked -eq $text) { return $false }
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseInput($blanked, [ref]$null, [ref]$parseErrors) | Out-Null
        if ($parseErrors) { Write-Warning "Not blanking ${Path}: the result would not parse."; return $false }
        [IO.File]::WriteAllText($Path, $blanked, (New-Object Text.UTF8Encoding($hasBom)))
        return $true
    } catch {
        Write-Warning "Could not blank the answers in ${Path}: $($_.Exception.Message)"
        return $false
    }
}
