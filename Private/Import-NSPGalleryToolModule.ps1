function Import-NSPGalleryToolModule {
    # Operator entry points must work without a development checkout. Never fall back to siblings.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][version]$MinimumVersion)
    # An installed copy (under a PSModulePath root) that is new enough and already loaded is kept.
    # Reloading would be wasted work, and for the Graph SDK harmful: Remove-Module and Import-Module
    # in a live process leave Get-MgContext throwing SessionNotInitialized and Connect-MgGraph failing.
    $loaded = Get-Module -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
    if ($loaded -and $loaded.ModuleBase -and $loaded.Version -ge $MinimumVersion) {
        $base = $loaded.ModuleBase.TrimEnd('\') + '\'
        foreach ($root in @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ })) {
            if ($base.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
        }
    }
    $find = {
        Get-Module -ListAvailable -Name $Name | Where-Object Version -ge $MinimumVersion |
            Sort-Object Version -Descending | Select-Object -First 1
    }
    $installed = & $find
    if (-not $installed) {
        if ($env:NSP_NO_AUTOINSTALL -eq '1') {
            throw "$Name $MinimumVersion or later is required. Install it from PSGallery; automatic installation is disabled."
        }
        Import-NSPToolkitModule -Name NSP.Bootstrap -MinimumVersion 0.1.3
        $scope = 'CurrentUser'
        if (Test-NSPIsAdmin) { $scope = 'AllUsers' }
        Write-Host "Installing $Name $MinimumVersion or later from PSGallery ($scope)..."
        Install-NSPModule -Name $Name -MinimumVersion $MinimumVersion.ToString() -Scope $scope -ErrorAction Stop
        $installed = & $find
        if (-not $installed) { throw "Cannot find an installed $Name $MinimumVersion or later after Gallery installation." }
    }
    # Compare folders: a loaded module's Path is its root .psm1, an available one's is its .psd1.
    if ($loaded -and $loaded.ModuleBase -and $loaded.ModuleBase -eq $installed.ModuleBase) { return }
    if ($loaded) { Remove-Module -Name $Name -Force -ErrorAction Stop }
    Import-Module -Name $installed.Path -Global -ErrorAction Stop
}
