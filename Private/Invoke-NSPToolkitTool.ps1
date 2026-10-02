function Invoke-NSPToolkitTool {
    # Installs (if missing or too old), imports and starts one tool from the tool list.
    param([Parameter(Mandatory)][string]$Tool)

    $def = Get-NSPToolDefinition -Tool $Tool
    $ok = Get-Module -ListAvailable -Name $def.ModuleName | Where-Object { $_.Version -ge [version]$def.MinimumVersion }
    if (-not $ok) {
        # A checkout next to this repository counts too (development, -ModuleRoot style testing).
        try { Import-NSPToolkitModule -Name $def.ModuleName -MinimumVersion $def.MinimumVersion; $ok = $true } catch { $ok = $false }
    }
    if (-not $ok) {
        Import-NSPToolkitModule -Name NSP.Bootstrap -MinimumVersion 0.1.3
        $scope = if (Test-NSPIsAdmin) { 'AllUsers' } else { 'CurrentUser' }
        Write-Host "Installing $($def.ModuleName) $($def.MinimumVersion)+ from the PowerShell Gallery..." -ForegroundColor Cyan
        Install-NSPModule -Name $def.ModuleName -MinimumVersion $def.MinimumVersion -Scope $scope
    }
    Import-NSPToolkitModule -Name $def.ModuleName -MinimumVersion $def.MinimumVersion
    & $def.EntryFunction
}
