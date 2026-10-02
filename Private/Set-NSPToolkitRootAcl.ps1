function Set-NSPToolkitRootAcl {
    # Administrators + SYSTEM full control, inheritance from ProgramData cut (Users can read
    # ProgramData by default, and these folders hold client answers). Best effort: a failure (not
    # elevated, non-NTFS) is a warning, never an error.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
            $id = New-Object Security.Principal.SecurityIdentifier($sid)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', $inherit, 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    } catch {
        Write-Warning "Could not restrict permissions on ${Path}: $($_.Exception.Message). Client answers there may be readable by non-administrators."
    }
}
