function Export-NSPHandoff {
    <#
    .SYNOPSIS
        Writes a hand-off (from New-NSPHandoff) to a JSON file, with a SHA-256 of the payload so the
        reader can tell whether it was damaged or edited on the way.

    .DESCRIPTION
        The payload is serialized once and that exact text is both hashed and written, so the hash
        does not depend on which PowerShell edition reads the file later. Payload is always the last
        property in the file.

        With -Directory the file is named <Company>_<Tool>_<Kind>.json (Company reduced to letters,
        digits, - and _). Existing files are replaced.

    .PARAMETER Handoff
        Object from New-NSPHandoff.

    .PARAMETER Path
        Exact file to write.

    .PARAMETER Directory
        Folder to write into, using the standard file name.

    .EXAMPLE
        $h | Export-NSPHandoff -Directory C:\Temp

    .EXAMPLE
        Export-NSPHandoff -Handoff $h -Path C:\Temp\ExampleCo_NPS_Response.json
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Directory')]
    [OutputType([IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][object]$Handoff,
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Directory')][string]$Directory
    )

    process {
        if ($Handoff.Envelope -ne 'NSP.Handoff') { throw 'Export-NSPHandoff takes an object from New-NSPHandoff.' }

        if ($PSCmdlet.ParameterSetName -eq 'Directory') {
            $Path = Join-Path $Directory (Get-NSPHandoffFileName -Company $Handoff.Company -Tool $Handoff.Tool -Kind $Handoff.Kind)
        }

        $payloadJson = if ($null -eq $Handoff.Payload) { 'null' } else { ConvertTo-Json -InputObject $Handoff.Payload -Depth 20 -Compress }
        $header = [ordered]@{}
        foreach ($p in $Handoff.PSObject.Properties) {
            if ($p.Name -in 'Payload', 'PayloadSha256') { continue }
            $header[$p.Name] = $p.Value
        }
        $header['PayloadSha256'] = Get-NSPTextSha256 $payloadJson
        $headerJson = (ConvertTo-Json -InputObject $header -Depth 5).TrimEnd()
        # Re-open the header object and append Payload as its last property, verbatim.
        $text = $headerJson.Substring(0, $headerJson.LastIndexOf('}')).TrimEnd() + ",`r`n    `"Payload`":  " + $payloadJson + "`r`n}`r`n"
        $text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"

        if ($PSCmdlet.ShouldProcess($Path, "Write $($Handoff.Tool) $($Handoff.Kind) hand-off")) {
            $parent = Split-Path -Parent $Path
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
            Get-Item -LiteralPath $Path
        }
    }
}
