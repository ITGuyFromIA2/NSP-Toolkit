function Import-NSPHandoff {
    <#
    .SYNOPSIS
        Reads a hand-off file - the shared-header format, or one of the zip-era tools' own
        hand-back files - and returns it with the shared header, payload untouched.

    .DESCRIPTION
        Recognised old formats (wrapped with Legacy = $true and LegacyFormat set):
          *_CAResponse.json   CA-Manager menu 13 (Schema 1-4)        -> Tool PKI
          *_NPSResponse.json  NPS-Manager menu 7 (SchemaVersion 1)   -> Tool NPS
          ADInventory_*.json  AD-Manager menu 6 (SchemaVersion 1)    -> Tool AD

        HashValid is $true/$false for a shared-header file whose payload hash could be checked, and
        $null when it could not (old formats, or a file re-saved by another tool). A mismatch is a
        warning, not an error - the caller decides. -Tool / -Kind make the read throw when the file
        is something else.

    .PARAMETER Path
        File to read.

    .PARAMETER Tool
        Expected tool key; throws if the file is for a different tool.

    .PARAMETER Kind
        Expected kind (Answers or Response); throws if different.

    .EXAMPLE
        $h = Import-NSPHandoff -Path .\ExampleCo_NPS_Response.json -Tool NPS
        $h.Payload.RadiusClients

    .EXAMPLE
        Get-ChildItem .\Inbox -Filter *.json | ForEach-Object { Import-NSPHandoff $_.FullName }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)][Alias('FullName')][string]$Path,
        [string]$Tool,
        [ValidateSet('Answers', 'Response')][string]$Kind
    )

    process {
        $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath)
        try { $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
        catch { throw "$Path is not valid JSON: $($_.Exception.Message)" }
        if ($null -eq $data -or $data -is [array]) { throw "$Path is not a hand-off file (expected a JSON object)." }

        $fileName = Split-Path -Leaf $Path
        if ($data.PSObject.Properties['Envelope'] -and $data.Envelope -eq 'NSP.Handoff') {
            if ([int]$data.EnvelopeVersion -gt 1) { throw "$Path uses hand-off envelope version $($data.EnvelopeVersion); this NSP.Toolkit understands version 1. Update NSP.Toolkit." }
            $hashValid = $null
            $raw = Get-NSPRawPayloadText -FileText $text
            if ($null -ne $raw -and $data.PayloadSha256) { $hashValid = ((Get-NSPTextSha256 $raw) -eq $data.PayloadSha256) }
            if ($hashValid -eq $false) { Write-Warning "$fileName : the payload does not match its recorded hash - it was edited or damaged after it was written." }
            $result = [pscustomobject][ordered]@{
                PSTypeName      = 'NSP.Handoff'
                Envelope        = 'NSP.Handoff'
                EnvelopeVersion = [int]$data.EnvelopeVersion
                Kind            = [string]$data.Kind
                Tool            = [string]$data.Tool
                ToolVersion     = [string]$data.ToolVersion
                PayloadSchema   = [int]$data.PayloadSchema
                Company         = [string]$data.Company
                ComputerName    = [string]$data.ComputerName
                Domain          = [string]$data.Domain
                Generated       = [string]$data.Generated
                GeneratedBy     = [string]$data.GeneratedBy
                Payload         = $data.Payload
                Legacy          = $false
                LegacyFormat    = $null
                HashValid       = $hashValid
                Path            = $Path
            }
        } else {
            $legacy = ConvertTo-NSPLegacyHandoff -Data $data -FileName $fileName
            if (-not $legacy) { throw "$fileName is not a hand-off file this NSP.Toolkit recognises." }
            $result = [pscustomobject][ordered]@{
                PSTypeName      = 'NSP.Handoff'
                Envelope        = 'NSP.Handoff'
                EnvelopeVersion = 0
                Kind            = $legacy.Kind
                Tool            = $legacy.Tool
                ToolVersion     = $legacy.ToolVersion
                PayloadSchema   = $legacy.PayloadSchema
                Company         = $legacy.Company
                ComputerName    = $legacy.ComputerName
                Domain          = $legacy.Domain
                Generated       = $legacy.Generated
                GeneratedBy     = ''
                Payload         = $data
                Legacy          = $true
                LegacyFormat    = $legacy.LegacyFormat
                HashValid       = $null
                Path            = $Path
            }
        }

        if ($Tool -and $result.Tool -ne $Tool) { throw "$fileName is a $($result.Tool) hand-off, not $Tool." }
        if ($Kind -and $result.Kind -ne $Kind) { throw "$fileName is a $($result.Kind) hand-off, not $Kind." }
        $result
    }
}
