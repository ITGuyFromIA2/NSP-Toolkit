# Pick lists for ScanBridge setup values that would otherwise be typed: settings path, PowerShell
# host, run account and repeat interval. Choices are remembered as ScanBridge Toolkit answers.

function Get-NSPScanBridgeAnswerTable {
    $answers=[ordered]@{}
    $saved=Get-NSPToolAnswers -Tool ScanBridge
    if($saved) { foreach($p in $saved.PSObject.Properties) { $answers[$p.Name]=$p.Value } }
    $answers
}

function Save-NSPScanBridgeAnswer {
    # Saves changed fields only, and nothing under Toolkit DRY RUN.
    param([Parameter(Mandatory)][hashtable]$Values)
    if(Get-NSPDryRun) { return }
    $answers=Get-NSPScanBridgeAnswerTable
    $changed=$false
    foreach($key in $Values.Keys) { if([string]$answers[$key] -ne [string]$Values[$key]) { $answers[$key]=$Values[$key]; $changed=$true } }
    if($changed) { Save-NSPToolAnswers -Tool ScanBridge -Answers $answers -Confirm:$false }
}

function ConvertTo-NSPLocalAccountName {
    # '.\name', 'COMPUTER\name' (this computer) and 'name' -> 'name'; anything else -> $null.
    param([Parameter(Mandatory)][string]$Account)
    $value=$Account.Trim()
    if($value -match '^(?<domain>[^\\]+)\\(?<name>[^\\]+)$') {
        if($Matches.domain -ne '.' -and $Matches.domain -ine [Environment]::MachineName) { return $null }
        $value=$Matches.name
    }
    if($value -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,19}$') { $value } else { $null }
}

function Read-NSPScanBridgeConfigurationPath {
    $saved=[string](Get-NSPScanBridgeAnswerTable).ConfigurationPath
    $path=(Read-NSPNonEmpty -Prompt 'ScanBridge settings PSD1 path' -CurrentValue $saved).Trim().Trim('"')
    if(Test-Path -LiteralPath $path -PathType Leaf) { Save-NSPScanBridgeAnswer @{ConfigurationPath=(Get-Item -LiteralPath $path).FullName} }
    $path
}

function Read-NSPScanBridgeTaskHost {
    $saved=[string](Get-NSPScanBridgeAnswerTable).TaskPowerShellPath
    $candidates=@(
        @(Get-Command pwsh.exe -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source)
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | ForEach-Object { (Get-Item -LiteralPath $_).FullName } | Select-Object -Unique
    $choices=@(foreach($path in @($candidates)) {
        $version=(Get-Item -LiteralPath $path).VersionInfo.ProductVersion
        $isPwsh=[IO.Path]::GetFileName($path) -ieq 'pwsh.exe'
        $label=if($isPwsh){"PowerShell 7 ($version)"}else{"Windows PowerShell 5.1 ($version)"}
        if($path -ieq $saved) { $label+=' - last used' }
        $help=if($isPwsh){"$path. Must stay installed for the task account."}else{"$path. Built in to Windows, so always present."}
        [pscustomobject]@{Label=$label;Value=$path;Help=$help}
    })
    $choices+=[pscustomobject]@{Key='T';Label='Type a path';Value='Type';Help='Full path to powershell.exe or pwsh.exe.'}
    $pick=Read-NSPMenu -Choices $choices -Prompt 'PowerShell the task runs' -CancelLabel 'Back'
    if($null -eq $pick) { return $null }
    if($pick -eq 'Type') {
        $pick=(Read-NSPNonEmpty -Prompt 'Full path to powershell.exe or pwsh.exe' -CurrentValue $saved).Trim().Trim('"')
        if([IO.Path]::GetFileName($pick) -notin @('powershell.exe','pwsh.exe') -or -not (Test-Path -LiteralPath $pick -PathType Leaf)) { throw 'Choose an existing powershell.exe or pwsh.exe.' }
    }
    Save-NSPScanBridgeAnswer @{TaskPowerShellPath=$pick}
    $pick
}

function Read-NSPScanBridgeRunAccount {
    # Returns SYSTEM, COMPUTER\name or a typed domain\gMSA$ account.
    $saved=[string](Get-NSPScanBridgeAnswerTable).ServiceAccount
    $builtIn=@('Administrator','Guest','DefaultAccount','WDAGUtilityAccount')
    $locals=@(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -and $_.Name -notin $builtIn } | Sort-Object @{Expression={$_.Name -ne $saved}},Name)
    $choices=@(foreach($user in $locals) {
        $label="$([Environment]::MachineName)\$($user.Name)"
        if($user.Name -eq $saved) { $label+=' - ScanBridge service account (saved)' }
        $help=if($user.Description){[string]$user.Description}else{'Local account (no description).'}
        [pscustomobject]@{Label=$label;Value=$user.Name;Help=$help}
    })
    $choices+=[pscustomobject]@{Key='S';Label='SYSTEM';Value='SYSTEM';Help='No password to manage, but runs with full machine rights; the certificate must be in the computer store.'}
    $choices+=[pscustomobject]@{Key='T';Label='Type an account';Value='Type';Help='.\name for a local account on this computer, or domain\gMSA$ for a group managed service account.'}
    $pick=Read-NSPMenu -Choices $choices -Prompt 'Account the task runs as' -CancelLabel 'Back'
    if($null -eq $pick) { return $null }
    if($pick -eq 'Type') { $pick=(Read-NSPNonEmpty -Prompt 'Run account').Trim() }
    if($pick -in @('SYSTEM','NT AUTHORITY\SYSTEM')) { return 'SYSTEM' }
    $local=ConvertTo-NSPLocalAccountName -Account $pick
    if($local) { Save-NSPScanBridgeAnswer @{ServiceAccount=$local}; return [Environment]::MachineName+'\'+$local }
    if($pick -notmatch '^[^\\]+\\[^\\]+\$$') { throw "Use .\name for a local account or domain\name$ for a gMSA; '$pick' is neither." }
    $pick
}

function Read-NSPScanBridgeTaskInterval {
    $saved=[int](Get-NSPScanBridgeAnswerTable).TaskMinutes
    $choices=@(foreach($minutes in 5,10,15,30) {
        $help=switch($minutes) {
            5 { 'Scans reach SharePoint within about 5 minutes; most runs find nothing and exit quickly.' }
            10 { 'A balance between delay and how often the task wakes.' }
            15 { 'Fine when scans are not urgent.' }
            30 { 'Light catch-up sweep, for example alongside an event trigger.' }
        }
        $label="Every $minutes minutes"
        if($minutes -eq $saved) { $label+=' - last used' }
        [pscustomobject]@{Label=$label;Value=$minutes;Help=$help}
    })
    $choices+=[pscustomobject]@{Key='T';Label='Other interval';Value='Type';Help='Whole minutes.'}
    $pick=Read-NSPMenu -Choices $choices -Prompt 'How often the task runs' -CancelLabel 'Back'
    if($null -eq $pick) { return $null }
    if($pick -eq 'Type') {
        $typed=(Read-NSPNonEmpty -Prompt 'Repeat interval in minutes').Trim()
        if($typed -notmatch '^[1-9][0-9]{0,3}$') { throw 'Enter whole minutes from 1 to 9999.' }
        $pick=[int]$typed
    }
    Save-NSPScanBridgeAnswer @{TaskMinutes=[int]$pick}
    [int]$pick
}
