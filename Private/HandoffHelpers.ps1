function Get-NSPTextSha256 {
    param([AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Get-NSPHandoffFileName {
    param([AllowEmptyString()][string]$Company, [string]$Tool, [string]$Kind)
    $stem = [regex]::Replace([string]$Company, '[^A-Za-z0-9_-]', '')
    if (-not $stem) { $stem = 'Unknown' }
    return "${stem}_${Tool}_${Kind}.json"
}

function Get-NSPRawPayloadText {
    # The exact payload text Export-NSPHandoff wrote: everything after the LAST top-level
    # "Payload": key up to the final closing brace. $null when the file isn't laid out that way
    # (hand-edited or re-saved by another tool) - the hash is then reported as unverifiable.
    param([string]$FileText)
    $m = [regex]::Match($FileText, '(?s),\s*"Payload"\s*:\s*(.*)\}\s*$')
    if (-not $m.Success) { return $null }
    $raw = $m.Groups[1].Value.TrimEnd()
    # Payload must be the last property: if anything follows it, the capture is not valid JSON.
    try { $null = ConvertFrom-Json -InputObject $raw -ErrorAction Stop } catch { return $null }
    return $raw
}

function ConvertTo-NSPLegacyHandoff {
    # Recognises the hand-back files the zip-era tools wrote and wraps them in the shared header,
    # payload untouched. Returns $null for anything it does not recognise.
    param([Parameter(Mandatory)][object]$Data, [string]$FileName = '')

    $names = @($Data.PSObject.Properties.Name)

    # CA-Manager menu 13: <Company>_CAResponse.json, Schema 1 (synthesized) .. 4.
    if (($FileName -like '*_CAResponse.json') -or ($names -contains 'Schema' -and ($names -contains 'CACommonName' -or $names -contains 'FortiGateCertName'))) {
        return [pscustomobject][ordered]@{
            Tool = 'PKI'; Kind = 'Response'; LegacyFormat = 'CAResponse'
            PayloadSchema = [int]$Data.Schema
            ToolVersion = [string]$Data.CAManagerVersion
            Company = [string]$Data.Company
            ComputerName = ''; Domain = ''
            Generated = [string]$Data.GeneratedUtc
        }
    }
    # NPS-Manager menu 7: <stem>_NPSResponse.json, SchemaVersion 1.
    if (($FileName -like '*_NPSResponse.json') -or ($names -contains 'SchemaVersion' -and $names -contains 'IasXml')) {
        return [pscustomobject][ordered]@{
            Tool = 'NPS'; Kind = 'Response'; LegacyFormat = 'NPSResponse'
            PayloadSchema = [int]$Data.SchemaVersion
            ToolVersion = [string]$Data.ToolVersion
            Company = [string]$Data.Company
            ComputerName = [string]$Data.ComputerName; Domain = [string]$Data.Domain
            Generated = [string]$Data.Generated
        }
    }
    # AD-Manager menu 6: ADInventory_<domain>_<timestamp>.json, SchemaVersion 1.
    if (($FileName -like 'ADInventory_*.json') -or ($names -contains 'SchemaVersion' -and $names -contains 'Groups' -and $names -contains 'Sources')) {
        return [pscustomobject][ordered]@{
            Tool = 'AD'; Kind = 'Response'; LegacyFormat = 'ADInventory'
            PayloadSchema = [int]$Data.SchemaVersion
            ToolVersion = ([string]$Data.Tool -replace '^\s*AD-Manager\s*', '')   # "AD-Manager 1.1.0"
            Company = ''
            ComputerName = [string]$Data.ComputerName; Domain = [string]$Data.Domain
            Generated = [string]$Data.Generated
        }
    }
    return $null
}
