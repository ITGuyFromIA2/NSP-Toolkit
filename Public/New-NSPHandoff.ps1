function New-NSPHandoff {
    <#
    .SYNOPSIS
        Builds a hand-off object: the shared header every NSP tool puts around the data it passes to
        another tool (answers going out to a tool, or a response coming back).

    .DESCRIPTION
        One file per tool per server - hand-offs are never merged. The header says what the file is
        and where it came from; Payload is the tool's own data, unchanged. Write it with
        Export-NSPHandoff and read it back with Import-NSPHandoff.

    .PARAMETER Kind
        Answers (going to a tool) or Response (coming back from one).

    .PARAMETER Tool
        Tool key: AD, NPS, PKI, FortiClient, ...

    .PARAMETER Company
        Client the data belongs to.

    .PARAMETER Payload
        The tool's own data.

    .PARAMETER PayloadSchema
        Version of the payload's own shape (e.g. 4 for the CA response). Defaults to 1.

    .PARAMETER ToolVersion
        Version of the tool that produced it.

    .PARAMETER GeneratedBy
        Free text, e.g. 'Orchestrator 4.1.0' or 'NSP.NPS 0.1.0'.

    .EXAMPLE
        New-NSPHandoff -Kind Response -Tool NPS -Company 'Example Co' -Payload $data -ToolVersion '0.1.0' |
            Export-NSPHandoff -Directory (Get-NSPToolWorkPath -Tool NPS -Kind Responses -Create)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Answers', 'Response')][string]$Kind,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+$')][string]$Tool,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Company,
        [Parameter(Mandatory)][AllowNull()][object]$Payload,
        [int]$PayloadSchema = 1,
        [string]$ToolVersion = '',
        [string]$GeneratedBy = '',
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$Domain = $env:USERDNSDOMAIN
    )

    [pscustomobject][ordered]@{
        PSTypeName      = 'NSP.Handoff'
        Envelope        = 'NSP.Handoff'
        EnvelopeVersion = 1
        Kind            = $Kind
        Tool            = $Tool
        ToolVersion     = $ToolVersion
        PayloadSchema   = $PayloadSchema
        Company         = $Company
        ComputerName    = [string]$ComputerName
        Domain          = [string]$Domain
        Generated       = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        GeneratedBy     = $GeneratedBy
        Payload         = $Payload
    }
}
