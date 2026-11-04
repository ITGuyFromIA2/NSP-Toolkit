# ScanBridge first settings file: a copy of the installed module's example, placeholders kept,
# readable by administrators and SYSTEM only. Never replaces an existing file. Planned and
# confirmed; DRY RUN stops after the plan.

function Get-NSPScanBridgeSettingsExample {
    # The example shipped with the highest all-users NSP.ScanBridge, or $null.
    $copies=foreach($root in @(Get-NSPAllUsersModuleRoot)) { Get-NSPAllUsersModuleVersion -Root $root -Name 'NSP.ScanBridge' }
    foreach($copy in @($copies | Sort-Object Version -Descending)) {
        $example=Join-Path $copy.Path 'config\ScanBridge.example.psd1'
        if(Test-Path -LiteralPath $example -PathType Leaf) { return [pscustomobject]@{Path=$example;Version=$copy.Version} }
    }
}

function Set-NSPScanBridgePrivateAcl {
    # Administrators + SYSTEM full control, inheritance cut. Unlike Set-NSPToolkitRootAcl a failure
    # is an error: the file must not be reported as restricted when it is not.
    param([Parameter(Mandatory)][string]$Path)
    $isFolder=Test-Path -LiteralPath $Path -PathType Container
    $acl=if($isFolder){New-Object Security.AccessControl.DirectorySecurity}else{New-Object Security.AccessControl.FileSecurity}
    $acl.SetAccessRuleProtection($true,$false)
    $inherit=if($isFolder){[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
    foreach($sid in 'S-1-5-32-544','S-1-5-18') {
        $id=New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id,'FullControl',$inherit,'None','Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Test-NSPScanBridgeFolderOpenToUsers {
    # True when Users, Authenticated Users or Everyone can add to or change an existing folder.
    param([Parameter(Mandatory)][string]$Path)
    $broad='S-1-5-32-545','S-1-5-11','S-1-1-0'
    $write=[Security.AccessControl.FileSystemRights]'WriteData, AppendData, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    $rules=(Get-Acl -LiteralPath $Path -ErrorAction Stop).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    [bool]@($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -in $broad -and ($_.FileSystemRights -band $write) }).Count
}

function Test-NSPScanBridgePathHasLink {
    # True when any existing part of a path is a link; a restricted file must not land elsewhere.
    param([Parameter(Mandatory)][string]$Path)
    $current=$Path
    while($current) {
        $item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $true }
        $parent=Split-Path -Parent $current
        if(-not $parent -or $parent -eq $current) { break }
        $current=$parent
    }
    $false
}

function Invoke-NSPScanBridgeSettingsCreate {
    <#
        Creates the first ScanBridge settings file from the installed example. An existing file is
        selected, never replaced. The file gets its own protected ACL because the folder step gives
        the task account Modify on the lock folder, which is this folder by default. Returns the
        full path of the file now selected, or $null.
    #>
    [CmdletBinding()]
    param([string]$ConfigurationPath)
    $dryRun=[bool](Get-NSPDryRun)
    $default=if($ConfigurationPath){$ConfigurationPath}else{[string](Get-NSPScanBridgeAnswerTable).ConfigurationPath}
    if(-not $default) { $default=Join-Path $env:ProgramData 'NSP\ScanBridge\ScanBridge.psd1' }
    $typed=(Read-NSPNonEmpty -Prompt 'Settings file to create' -CurrentValue $default).Trim().Trim('"')
    if($typed -notmatch '^[A-Za-z]:\\' -or [IO.Path]::GetExtension($typed) -ine '.psd1') { Write-NSPConsoleLine 'Use a full local path ending in .psd1.' -Role Error; return }
    $path=[IO.Path]::GetFullPath($typed)
    if(Test-NSPScanBridgePathHasLink -Path $path) { Write-NSPConsoleLine 'That path goes through a link. Choose a plain local folder.' -Role Error; return }
    if(Test-Path -LiteralPath $path -PathType Container) { Write-NSPConsoleLine 'That path is a folder.' -Role Error; return }
    if(Test-Path -LiteralPath $path -PathType Leaf) {
        Write-NSPConsoleLine "A settings file already exists at $path. It was not changed and is now selected." -Role Warning
        Save-NSPScanBridgeAnswer @{ConfigurationPath=$path}
        return $path
    }
    $example=Get-NSPScanBridgeSettingsExample
    if(-not $example) { Write-NSPConsoleLine "NSP.ScanBridge is not installed for all users, so there is no example to copy. Run 'Install PowerShell 7 and ScanBridge modules for all users' first." -Role Error; return }
    $folder=Split-Path -Parent $path
    $folderExists=Test-Path -LiteralPath $folder -PathType Container

    Write-NSPConsoleLine 'Settings file plan:'
    Write-NSPConsoleLine ("  - {0} [create]: Administrators and SYSTEM only" -f $path)
    Write-NSPConsoleLine ("  - Copied from the NSP.ScanBridge {0} example; placeholders stay until the later steps fill them" -f $example.Version)
    Write-NSPConsoleLine ("  - {0}: {1}" -f $folder,$(if($folderExists){'exists; its access is left alone'}else{'[create] Administrators and SYSTEM only'}))
    if($folderExists -and (Test-NSPScanBridgeFolderOpenToUsers -Path $folder)) { Write-NSPConsoleLine 'Ordinary users can add files to that folder. The settings file itself is still restricted, but backups and other files there are not.' -Role Warning }
    if($dryRun) { Write-NSPConsoleLine 'DRY RUN: nothing created.' -Role Warning; return }
    if(-not (Test-NSPScanBridgeElevated)) { Write-NSPConsoleLine 'Restricting the settings file needs an elevated session. Restart PowerShell as administrator.' -Role Error; return }
    if(-not (Read-NSPConfirm -Prompt 'Create this settings file?')) { return }

    if(-not $folderExists) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-NSPScanBridgePrivateAcl -Path $folder
    }
    # CreateNew refuses a file that appeared since the check; it is ours to remove if a later step fails.
    [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None).Dispose()
    try {
        Set-NSPScanBridgePrivateAcl -Path $path
        [IO.File]::WriteAllBytes($path,[IO.File]::ReadAllBytes($example.Path))
        Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop | Out-Null
    } catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw
    }
    Save-NSPScanBridgeAnswer @{ConfigurationPath=$path}
    Write-NSPConsoleLine "Settings file created and selected: $path. Keep it private and off Git." -Role Success
    $path
}
