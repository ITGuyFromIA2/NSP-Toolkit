function Import-NSPToolSeedAnswers {
    <#
    .SYNOPSIS
        Takes the answers a shim embedded (its -SeedAnswersJson) and merges them into the tool's
        saved answers in its work folder. What every Start-NSP*Manager does with -SeedAnswersJson.

    .DESCRIPTION
        The seed may be plain answers JSON or an Answers hand-off (New-NSPHandoff -Kind Answers);
        a hand-off for a different tool is refused. Merging follows Merge-NSPHandoffAnswers: the
        live answers win unless the operator takes the incoming value. Returns the merged answers.

    .PARAMETER Tool
        Tool key.

    .PARAMETER SeedAnswersJson
        The embedded JSON. Blank does nothing and returns the current answers.

    .PARAMETER NonInteractive
        Never prompt; live wins every differing field.

    .EXAMPLE
        $script:Answers = Import-NSPToolSeedAnswers -Tool AD -SeedAnswersJson $SeedAnswersJson
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+$')][string]$Tool,
        [AllowEmptyString()][string]$SeedAnswersJson,
        [switch]$NonInteractive
    )

    $live = Get-NSPToolAnswers -Tool $Tool
    if ([string]::IsNullOrWhiteSpace($SeedAnswersJson)) { return $live }

    try { $seed = ConvertFrom-Json -InputObject $SeedAnswersJson -ErrorAction Stop }
    catch { throw "The embedded answers are not valid JSON: $($_.Exception.Message)" }

    if ($seed.PSObject.Properties['Envelope'] -and $seed.Envelope -eq 'NSP.Handoff') {
        if ($seed.Tool -ne $Tool) { throw "These answers are for the $($seed.Tool) tool, not $Tool." }
        if ($seed.Kind -ne 'Answers') { throw "This is a $($seed.Kind) hand-off, not answers." }
        $seed = $seed.Payload
    }
    if ($null -eq $seed) { return $live }

    $merge = Merge-NSPHandoffAnswers -Live $live -Incoming $seed -NonInteractive:$NonInteractive
    if (-not $PSCmdlet.ShouldProcess("$Tool answers", 'Save the merged answers')) { return $merge.Answers }
    Save-NSPToolAnswers -Tool $Tool -Answers $merge.Answers
    if ($null -eq $live) {
        Write-Host "Saved the $($merge.Added) answer field(s) this launcher carried." -ForegroundColor Green
    } elseif ($merge.Added -or $merge.Differing) {
        Write-Host "Answers merged: $($merge.Added) new field(s) added, $($merge.TookIncoming) of $($merge.Differing) differing field(s) took the incoming value." -ForegroundColor Green
    }
    return $merge.Answers
}
