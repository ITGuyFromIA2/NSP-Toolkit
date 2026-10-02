function Move-NSPToolLegacyData {
    <#
    .SYNOPSIS
        Finds what the zip-era version of a tool left on this server - extracted tool folders,
        answers files next to the old scripts, hand-back files, old shims with answers embedded -
        moves the data into the tool's work folder, then removes the old copies.

    .DESCRIPTION
        1. Finds the old extract folders (e.g. NPSStaging\NPSManager next to an NPS-Manager.ps1 shim)
           and old shims that still carry an embedded answers block, under -SearchPath.
        2. Merges the old answers file into the work folder's answers (the work folder wins; a
           differing field is prompted for unless -NonInteractive).
        3. Copies hand-back files and certificates (*_Response.json, ADInventory_*.json, *.pfx,
           *.cer) into the work folder's Responses\Legacy - PFX files are kept, they are
           password-protected.
        4. Lists what it will remove and asks once, then deletes the old extract folders and blanks
           the answers embedded in old shims (the shim file itself stays).
        5. Logs what moved and what was removed - names only, never values - to Logs\.

        -WhatIf lists everything and changes nothing. Returns a summary object.

    .PARAMETER Tool
        Tool key: AD, NPS, PKI, FortiClient.

    .PARAMETER SearchPath
        Folders to search (two levels deep). Defaults to C:\Admin, C:\Temp, C:\Scripts, C:\NSP and
        every user's Desktop and Downloads, plus any fixed path the tool used.

    .PARAMETER NonInteractive
        Never prompt: the work folder wins differing answers, and removal goes ahead without asking.

    .EXAMPLE
        Move-NSPToolLegacyData -Tool NPS -WhatIf

    .EXAMPLE
        Move-NSPToolLegacyData -Tool PKI -SearchPath 'D:\Tools'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string[]]$SearchPath,
        [switch]$NonInteractive
    )

    $def = Get-NSPToolDefinition -Tool $Tool
    $legacy = $def.Legacy
    if (-not $SearchPath) {
        $SearchPath = @('C:\Admin', 'C:\Temp', 'C:\Scripts', 'C:\NSP')
        foreach ($userDir in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) {
            $SearchPath += (Join-Path $userDir.FullName 'Desktop'), (Join-Path $userDir.FullName 'Downloads')
        }
    }
    $roots = @($SearchPath | Where-Object { $_ -and (Test-Path -LiteralPath $_) })

    # --- 1. find -----------------------------------------------------------------------------
    $extractDirs = @()
    $removeDirs = @()
    if ($legacy.StagingFolder) {
        foreach ($root in $roots) {
            $found = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $legacy.StagingFolder })
            foreach ($staging in $found) {
                $removeDirs += $staging.FullName
                $extract = Join-Path $staging.FullName $legacy.ExtractFolder
                if (Test-Path -LiteralPath $extract) { $extractDirs += $extract }
            }
        }
    }
    foreach ($fixed in @($legacy.FixedPaths)) {
        if ($fixed -and (Test-Path -LiteralPath $fixed)) { $removeDirs += $fixed; $extractDirs += $fixed }
    }
    $removeDirs = @($removeDirs | Select-Object -Unique)
    $extractDirs = @($extractDirs | Select-Object -Unique)

    $shims = @()
    if ($legacy.ShimAnswersVar) {
        $marker = '$' + $legacy.ShimAnswersVar + " = @'"
        foreach ($root in $roots) {
            foreach ($name in @($legacy.ShimNames)) {
                $shims += @(Get-ChildItem -LiteralPath $root -Filter $name -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                    Where-Object { (Get-NSPLegacyShimAnswers -Path $_.FullName -Variable $legacy.ShimAnswersVar) } |
                    ForEach-Object { $_.FullName })
            }
        }
        $shims = @($shims | Select-Object -Unique)
        Write-Verbose "Shim marker: $marker"
    }

    $answersFiles = @()
    $responseFiles = @()
    foreach ($dir in $extractDirs) {
        if ($legacy.AnswersFile) {
            $a = Join-Path $dir $legacy.AnswersFile
            if (Test-Path -LiteralPath $a) { $answersFiles += $a }
        }
        $responseFiles += @(Get-ChildItem -LiteralPath $dir -File -Recurse -Depth 1 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*_*Response.json' -or $_.Name -like 'ADInventory_*.json' -or $_.Extension -in '.pfx', '.cer' } |
            ForEach-Object { $_.FullName })
    }

    $summary = [pscustomobject]@{
        Tool = $def.Name; AnswersMerged = @(); ResponsesCopied = @(); FoldersRemoved = @(); ShimsBlanked = @(); Found = $false
    }
    if (-not ($removeDirs.Count + $shims.Count)) {
        Write-Host "No old $($def.DisplayName) files found on this server." -ForegroundColor DarkGray
        return $summary
    }
    $summary.Found = $true

    Write-Host ''
    Write-Host "Old $($def.DisplayName) files found:" -ForegroundColor Cyan
    foreach ($d in $removeDirs) { Write-Host "  folder  $d" }
    foreach ($s in $shims) { Write-Host "  shim    $s  (answers embedded)" }
    foreach ($a in $answersFiles) { Write-Host "  answers $a  -> work folder" -ForegroundColor DarkGray }
    foreach ($r in $responseFiles) { Write-Host "  file    $r  -> work folder Responses\Legacy" -ForegroundColor DarkGray }

    $log = New-Object Collections.Generic.List[string]

    # --- 2. answers -------------------------------------------------------------------------
    $shimSeeds = @(foreach ($s in $shims) { Get-NSPLegacyShimAnswers -Path $s -Variable $legacy.ShimAnswersVar })
    foreach ($source in @($answersFiles + $shims)) {
        $json = if ($answersFiles -contains $source) { [IO.File]::ReadAllText($source) } else { $shimSeeds[[array]::IndexOf($shims, $source)] }
        try { $incoming = ConvertFrom-Json -InputObject $json -ErrorAction Stop } catch { Write-Warning "Skipping unreadable answers in ${source}: $($_.Exception.Message)"; continue }
        if ($PSCmdlet.ShouldProcess((Get-NSPToolWorkPath -Tool $def.Name -Kind Answers), "Merge answers from $source")) {
            $merge = Merge-NSPHandoffAnswers -Live (Get-NSPToolAnswers -Tool $def.Name) -Incoming $incoming -NonInteractive:$NonInteractive
            Save-NSPToolAnswers -Tool $def.Name -Answers $merge.Answers
            $summary.AnswersMerged += $source
            $log.Add("answers merged from $source ($($merge.Added) added, $($merge.TookIncoming)/$($merge.Differing) differing took incoming)")
        }
    }

    # --- 3. hand-back files and certificates --------------------------------------------------
    foreach ($r in $responseFiles) {
        if ($PSCmdlet.ShouldProcess($r, 'Copy into the work folder (Responses\Legacy)')) {
            $dest = Join-Path (Get-NSPToolWorkPath -Tool $def.Name -Kind Responses -Create) 'Legacy'
            if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            $target = Join-Path $dest (Split-Path -Leaf $r)
            $n = 1
            while (Test-Path -LiteralPath $target) {
                $target = Join-Path $dest ('{0}.{1}{2}' -f [IO.Path]::GetFileNameWithoutExtension($r), $n, [IO.Path]::GetExtension($r)); $n++
            }
            Copy-Item -LiteralPath $r -Destination $target
            $summary.ResponsesCopied += $target
            $log.Add("copied $r -> $target")
        }
    }

    # --- 4. remove old copies ----------------------------------------------------------------
    if (-not $WhatIfPreference) {
        $go = $NonInteractive
        if (-not $go) {
            $q = "Remove the $($removeDirs.Count) old folder(s) and blank the answers in $($shims.Count) old shim(s)? Their data is now in the work folder."
            try { $go = (Read-Host "$q [y/N]") -match '^(?i)y(es)?$' } catch { $go = $false }
        }
        if (-not $go) {
            Write-Host 'Left the old files in place.' -ForegroundColor Yellow
        } else {
            foreach ($d in $removeDirs) {
                if ($PSCmdlet.ShouldProcess($d, 'Delete old extracted tool folder')) {
                    try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop; $summary.FoldersRemoved += $d; $log.Add("removed folder $d") }
                    catch { Write-Warning "Could not remove ${d}: $($_.Exception.Message)" }
                }
            }
            foreach ($s in $shims) {
                if ($PSCmdlet.ShouldProcess($s, 'Blank the embedded answers')) {
                    if (Clear-NSPLegacyShimAnswers -Path $s -Variable $legacy.ShimAnswersVar) { $summary.ShimsBlanked += $s; $log.Add("blanked answers in shim $s") }
                }
            }
        }
    }

    # --- 5. log ------------------------------------------------------------------------------
    if ($log.Count -and -not $WhatIfPreference) {
        $logDir = Get-NSPToolWorkPath -Tool $def.Name -Kind Logs -Create
        $logFile = Join-Path $logDir ('LegacyCleanup_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        [IO.File]::WriteAllLines($logFile, [string[]]$log)
    }
    return $summary
}
