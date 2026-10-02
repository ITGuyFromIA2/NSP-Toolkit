function Import-NSPToolkitModule {
    <#
    .SYNOPSIS
        Loads a sibling NSP toolkit module on first use: an installed copy, else a checkout next to
        this repository (NSP-PoSHToolkits\NSP-X or GitRepo\NSP-X).
    .DESCRIPTION
        Copied from NSP.M365.ConditionalAccess, plus the second sibling location (NSP-Bootstrap
        lives directly under GitRepo, the others under NSP-PoSHToolkits). These modules are never
        RequiredModules entries, so this module still imports on a bare host. With
        -MinimumVersion, an older installed copy is passed over and a loaded older copy replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [version]$MinimumVersion,
        [switch]$Reload
    )

    $loaded = Get-Module -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
    if ($loaded -and -not $Reload -and (-not $MinimumVersion -or $loaded.Version -ge $MinimumVersion)) { return }
    $installed = Get-Module -ListAvailable -Name $Name | Where-Object { -not $MinimumVersion -or $_.Version -ge $MinimumVersion } |
        Sort-Object Version -Descending | Select-Object -First 1
    $path = if ($installed) { $installed.Path } else { $null }
    if (-not $path) {
        $folder = $Name.Replace('.', '-')
        $toolkits = Split-Path -Parent $script:ModuleRoot
        foreach ($candidate in @((Join-Path $toolkits "$folder\$Name.psd1"), (Join-Path (Split-Path -Parent $toolkits) "$folder\$Name.psd1"))) {
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            if ($MinimumVersion -and [version](Import-PowerShellDataFile -LiteralPath $candidate).ModuleVersion -lt $MinimumVersion) { continue }
            $path = $candidate
            break
        }
    }
    if (-not $path) {
        $wanted = if ($MinimumVersion) { "$Name $MinimumVersion or later" } else { $Name }
        throw "$wanted is required for this operation. Install it (Install-Module $Name), or check out $($Name.Replace('.', '-')) next to this repository."
    }
    if ($loaded) { Remove-Module -Name $Name -Force }
    Import-Module $path -Global -ErrorAction Stop
}