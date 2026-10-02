function Merge-NSPHandoffAnswers {
    <#
    .SYNOPSIS
        Merges incoming answers (a shim's seed, a re-staged snapshot) into the live answers a tool
        already has, field by field, and returns the result. Writes nothing.

    .DESCRIPTION
        The ShimEngine rule the zip-era shims used:
          - a field only the live answers have is kept (never destroyed);
          - a field only the incoming answers have is added;
          - a field that is the same in both needs no decision;
          - a field that differs keeps the live value, unless the operator takes the incoming one.
        Differing fields are prompted for one at a time - keep (L)ive, take (I)ncoming, take (A)ll
        incoming from here, (S)kip the rest - unless -NonInteractive or -TakeIncoming is given, or
        the session cannot prompt, in which case live wins. Long values are shortened on screen.

        Returns an object: Answers (the merged answers), Added, Differing, TookIncoming (counts).

    .PARAMETER Live
        The answers the tool has now ($null when it has none - incoming is then taken as-is).

    .PARAMETER Incoming
        The answers arriving.

    .PARAMETER NonInteractive
        Never prompt; live wins every differing field.

    .PARAMETER TakeIncoming
        Never prompt; incoming wins every differing field.

    .EXAMPLE
        $r = Merge-NSPHandoffAnswers -Live (Get-NSPToolAnswers -Tool NPS) -Incoming $seed
        Save-NSPToolAnswers -Tool NPS -Answers $r.Answers
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Live,
        [Parameter(Mandatory)][object]$Incoming,
        [switch]$NonInteractive,
        [switch]$TakeIncoming
    )

    $Incoming = ConvertTo-NSPAnswersObject $Incoming
    if ($null -eq $Live) {
        $count = @($Incoming.PSObject.Properties).Count
        return [pscustomobject]@{ Answers = $Incoming; Added = $count; Differing = 0; TookIncoming = 0 }
    }
    $Live = ConvertTo-NSPAnswersObject $Live

    $liveNames = @($Live.PSObject.Properties | ForEach-Object Name)
    $incomingNames = @($Incoming.PSObject.Properties | ForEach-Object Name)
    $allNames = @($liveNames + ($incomingNames | Where-Object { $liveNames -notcontains $_ }))

    $result = [ordered]@{}
    $added = 0; $differing = 0; $tookIncoming = 0
    $takeAll = [bool]$TakeIncoming
    $keepRest = [bool]$NonInteractive
    foreach ($name in $allNames) {
        $inLive = $liveNames -contains $name
        $inIncoming = $incomingNames -contains $name
        if ($inLive -and -not $inIncoming) { $result[$name] = $Live.$name; continue }
        if ($inIncoming -and -not $inLive) { $result[$name] = $Incoming.$name; $added++; continue }

        $liveJson = ConvertTo-Json -InputObject $Live.$name -Compress -Depth 20
        $incomingJson = ConvertTo-Json -InputObject $Incoming.$name -Compress -Depth 20
        if ($liveJson -eq $incomingJson) { $result[$name] = $Live.$name; continue }

        $differing++
        $choice = 'Live'
        if ($takeAll) { $choice = 'Incoming' }
        elseif (-not $keepRest) {
            Write-Host "  - ${name}:" -ForegroundColor Yellow
            Write-Host "      LIVE (on this server) : $(Get-NSPShortText $liveJson)" -ForegroundColor DarkCyan
            Write-Host "      INCOMING              : $(Get-NSPShortText $incomingJson)" -ForegroundColor Magenta
            $answer = $null
            try { $answer = Read-Host '    Keep (L)ive, take (I)ncoming, take (A)ll incoming from here, or (S)kip the rest (keep live)?' }
            catch {
                Write-Host '    (Cannot prompt in this session - keeping LIVE for this and the remaining fields.)' -ForegroundColor Yellow
                $keepRest = $true
            }
            switch -Regex ([string]$answer) {
                '^(?i)i$' { $choice = 'Incoming' }
                '^(?i)a$' { $choice = 'Incoming'; $takeAll = $true }
                '^(?i)s$' { $keepRest = $true }
            }
        }
        if ($choice -eq 'Incoming') { $result[$name] = $Incoming.$name; $tookIncoming++ } else { $result[$name] = $Live.$name }
    }

    [pscustomobject]@{ Answers = [pscustomobject]$result; Added = $added; Differing = $differing; TookIncoming = $tookIncoming }
}
