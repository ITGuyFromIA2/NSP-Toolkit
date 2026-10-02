<#
.SYNOPSIS
    One-line entry point for NSP tools on any server: installs NSP.Bootstrap and NSP.Toolkit from
    the PowerShell Gallery if needed, then opens the NSP Toolkit menu.

.DESCRIPTION
    On a server with PowerShellGet the simplest start needs no script at all:

        Install-Module NSP.Toolkit -Scope AllUsers; Start-NSPToolkit

    This file is for a server that can't do that from a prompt (no NuGet provider yet, TLS 1.2
    not enabled). Download it over HTTPS, check it (and its signature, when signed) and run the
    saved copy - right-click > Run with PowerShell. Do not pipe a downloaded copy straight into
    Invoke-Expression. Needs HTTPS access to www.powershellgallery.com. Not part of the
    NSP.Toolkit package itself.
#>
$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { Write-Verbose "TLS 1.2 could not be enabled: $_" }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$scope = if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'AllUsers' } else { 'CurrentUser' }

foreach ($m in @(@{ Name = 'NSP.Bootstrap'; Min = '0.1.3' }, @{ Name = 'NSP.Toolkit'; Min = '0.1.0' })) {
    if (-not (Get-Module -ListAvailable -Name $m.Name | Where-Object { $_.Version -ge [version]$m.Min })) {
        Write-Host "Installing $($m.Name) from the PowerShell Gallery..." -ForegroundColor Cyan
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope $scope | Out-Null
        }
        Install-Module -Name $m.Name -MinimumVersion $m.Min -Repository PSGallery -Scope $scope -Force -AllowClobber
    }
}
Import-Module NSP.Toolkit -MinimumVersion 0.1.0 -Force
Start-NSPToolkit
