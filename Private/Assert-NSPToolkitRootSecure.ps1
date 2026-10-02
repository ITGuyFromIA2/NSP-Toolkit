function Test-NSPToolkitRootAcl {
    # $true when -Path's access list is cut off from its parent and only Administrators and SYSTEM
    # are allowed - the ACL Set-NSPToolkitRootAcl applies. A missing folder is not secure.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop } catch { return $false }
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $allowed = 'S-1-5-32-544', 'S-1-5-18'
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $allowed -notcontains $rule.IdentityReference.Value) { return $false }
    }
    return $true
}

function Assert-NSPToolkitRootSecure {
    <#
        Fail closed before secrets are written under the Toolkit root (security review SEC-B2): the
        root must be limited to Administrators and SYSTEM. An elevated session repairs it; otherwise
        this throws and nothing is written.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Reason = 'secrets'
    )
    if (Test-NSPToolkitRootAcl -Path $Root) { return }
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ((Test-Path -LiteralPath $Root -PathType Container) -and $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Locking $Root down to Administrators and SYSTEM before saving $Reason." -ForegroundColor DarkGray
        Set-NSPToolkitRootAcl -Path $Root
        if (Test-NSPToolkitRootAcl -Path $Root) { return }
    }
    throw "Not saving $Reason`: $Root is not limited to Administrators and SYSTEM. Run the tool elevated so the folder can be locked down."
}
