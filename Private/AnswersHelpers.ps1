function ConvertTo-NSPAnswersObject {
    # Hashtable / ordered dictionary / JSON string -> pscustomobject; objects pass through.
    param([Parameter(Mandatory)][object]$Value)
    if ($Value -is [string]) { return (ConvertFrom-Json -InputObject $Value -ErrorAction Stop) }
    if ($Value -is [Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $Value.Keys) { $o[[string]$k] = $Value[$k] }
        return [pscustomobject]$o
    }
    return $Value
}

function Get-NSPShortText {
    param([AllowEmptyString()][string]$Text, [int]$Max = 200)
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "... ($($Text.Length - $Max) more chars)"
}
