# ScanBridge runtime provisioning for the task account: PowerShell 7 and the Gallery modules the
# worker loads, installed for all users in both module folders (Windows PowerShell and
# PowerShell 7), with older all-users NSP.M365.Graph copies removed. Plans first; DRY RUN stops
# after the plan.

$script:NSPScanBridgeRuntimeModules=@(
    [pscustomobject]@{Name='NSP.ScanBridge';MinimumVersion=[version]'0.1.0';ReplaceOlder=$false}
    [pscustomobject]@{Name='NSP.M365.Graph';MinimumVersion=[version]'0.1.2';ReplaceOlder=$true}
    [pscustomobject]@{Name='Microsoft.Graph.Authentication';MinimumVersion=[version]'2.0.0';ReplaceOlder=$false}
)

function Get-NSPAllUsersModuleRoot {
    # Windows PowerShell's all-users folder, then PowerShell 7's.
    if($script:NSPAllUsersModuleRootOverride) { return @($script:NSPAllUsersModuleRootOverride) }
    @((Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),(Join-Path $env:ProgramFiles 'PowerShell\Modules'))
}

function Get-NSPAllUsersModuleVersion {
    # Installed copies of one module under one root: versioned folders, or a flat (unversioned) copy.
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Name)
    $base=Join-Path $Root $Name
    if(-not (Test-Path -LiteralPath $base -PathType Container)) { return }
    $flat=Join-Path $base "$Name.psd1"
    if(Test-Path -LiteralPath $flat -PathType Leaf) {
        [pscustomobject]@{Name=$Name;Version=[version](Import-PowerShellDataFile -LiteralPath $flat).ModuleVersion;Path=$base;Layout='Flat'}
    }
    foreach($dir in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
        $manifest=Join-Path $dir.FullName "$Name.psd1"
        if(Test-Path -LiteralPath $manifest -PathType Leaf) {
            [pscustomobject]@{Name=$Name;Version=[version](Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion;Path=$dir.FullName;Layout='Versioned'}
        }
    }
}

function Find-NSPPowerShell7 {
    $candidates=@((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')) + @(Get-Command pwsh.exe -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source)
    foreach($path in $candidates) {
        if($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{Path=(Get-Item -LiteralPath $path).FullName;Version=(Get-Item -LiteralPath $path).VersionInfo.ProductVersion}
        }
    }
}

function Find-NSPGalleryModule {
    param([Parameter(Mandatory)][string]$Name)
    Find-Module -Name $Name -Repository PSGallery -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Save-NSPGalleryModule {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][version]$Version,[Parameter(Mandatory)][string]$Path)
    Save-Module -Name $Name -RequiredVersion $Version -Path $Path -Repository PSGallery -Force -ErrorAction Stop
}

function Save-NSPPowerShell7Installer {
    # Latest stable MSI for this processor from the PowerShell GitHub releases, kept only when its
    # Authenticode signature is valid and Microsoft Corporation's.
    param([Parameter(Mandatory)][string]$Destination)
    $architecture=if($env:PROCESSOR_ARCHITEW6432){$env:PROCESSOR_ARCHITEW6432}else{$env:PROCESSOR_ARCHITECTURE}
    $suffix=if($architecture -eq 'ARM64'){'win-arm64.msi'}else{'win-x64.msi'}
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $release=Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UseBasicParsing -ErrorAction Stop
    $asset=@($release.assets | Where-Object { $_.name -like "PowerShell-*-$suffix" })[0]
    if(-not $asset -or $asset.browser_download_url -notmatch '^https://github\.com/PowerShell/PowerShell/releases/download/') { throw "The latest PowerShell release has no $suffix from the PowerShell repository." }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $msi=Join-Path $Destination $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -UseBasicParsing -ErrorAction Stop
    $signature=Get-AuthenticodeSignature -LiteralPath $msi
    $signer=if($signature.SignerCertificate){$signature.SignerCertificate.Subject}else{''}
    if([string]$signature.Status -ne 'Valid' -or $signer -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        throw "Downloaded $($asset.name) is not validly signed by Microsoft (status $($signature.Status)). It was deleted."
    }
    [pscustomobject]@{Path=$msi;Version=[string]$release.tag_name;Signer=$signer}
}

function Install-NSPPowerShell7Msi {
    param([Parameter(Mandatory)][string]$MsiPath)
    $arguments=@('/i',"`"$MsiPath`"",'/qn','/norestart','ADD_PATH=1','REGISTER_MANIFEST=1','USE_MU=1','ENABLE_MU=1')
    $process=Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if($process.ExitCode -notin 0,3010) { throw "PowerShell 7 installer failed with exit code $($process.ExitCode)." }
    $process.ExitCode
}

function Test-NSPScanBridgeModuleResolution {
    # What a PowerShell 7 process without user-profile module folders would load: for each module,
    # the first folder on PSModulePath that has it (what Import-Module -Name picks) and the first
    # copy meeting the minimum version (what -MinimumVersion picks). Read-only; imports nothing.
    param([Parameter(Mandatory)][string]$PowerShellPath,[string[]]$ModuleRoot)
    $names=($script:NSPScanBridgeRuntimeModules | ForEach-Object { "$($_.Name)=$($_.MinimumVersion)" }) -join ';'
    $probe=@'
$profileRoot=[Environment]::GetFolderPath('UserProfile')
$roots=if($args[1]) { @($args[1] -split ';') } else { @($env:PSModulePath -split ';' | Where-Object { $_ -and -not $_.StartsWith($profileRoot,[StringComparison]::OrdinalIgnoreCase) }) }
foreach($pair in ($args[0] -split ';')) {
    $name,$minimum=$pair -split '='
    $first=$null;$satisfying=$null
    foreach($root in $roots) {
        $base=Join-Path $root $name
        if(-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        $manifests=@(Join-Path $base "$name.psd1") + @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName "$name.psd1" })
        $found=@(foreach($manifest in $manifests) {
            if(Test-Path -LiteralPath $manifest -PathType Leaf) {
                try { [pscustomobject]@{Version=[version](Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion;ModuleBase=(Split-Path -Parent $manifest)} } catch { }
            }
        }) | Sort-Object Version -Descending
        if(-not @($found).Count) { continue }
        $found=@($found)
        if(-not $first) { $first=$found[0] }
        if(-not $satisfying) { $satisfying=@($found | Where-Object { $_.Version -ge [version]$minimum })[0] }
    }
    '{0}|{1}|{2}|{3}|{4}' -f $name,$minimum,$(if($first){$first.Version}),$(if($first){$first.ModuleBase}),$(if($satisfying){$satisfying.Version})
}
'@
    $rootArgument=(@($ModuleRoot) -join ';') -replace "'","''"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("& {`n$probe`n} '$names' '$rootArgument'"))
    foreach($line in @(& $PowerShellPath -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded)) {
        $name,$minimum,$first,$base,$satisfying=([string]$line) -split '\|'
        [pscustomobject]@{Module=$name;Minimum=$minimum;FirstFound=$first;FirstFoundPath=$base;MeetsMinimum=$satisfying;
            Status=$(if(-not $first){'Missing'}elseif($first -and [version]$first -ge [version]$minimum){'OK'}elseif($satisfying){'OlderFirst'}else{'TooOld'})}
    }
}

function Invoke-NSPScanBridgeModuleInstall {
    <#
        Plans, then on confirm applies: PowerShell 7 when missing (Microsoft-signed MSI from the
        PowerShell GitHub releases), each runtime module from the Gallery into both all-users
        folders when no copy there meets the minimum, and removal of older all-users
        NSP.M365.Graph copies. Then checks what PowerShell 7 would load.
    #>
    [CmdletBinding()]
    param()
    $dryRun=[bool](Get-NSPDryRun)
    if(-not $dryRun -and -not (Test-NSPScanBridgeElevated)) { Write-NSPConsoleLine 'Installing for all users needs an elevated session. Restart PowerShell as administrator.' -Role Error; return }
    $roots=@(Get-NSPAllUsersModuleRoot)
    $pwsh=Find-NSPPowerShell7
    $steps=[System.Collections.Generic.List[object]]::new()
    if($pwsh) { Write-NSPConsoleLine ("PowerShell 7 {0} at {1}." -f $pwsh.Version,$pwsh.Path) -Role Muted }
    else { $steps.Add([pscustomobject]@{Action='InstallPowerShell7';Text='Install PowerShell 7 (latest stable MSI from Microsoft''s PowerShell GitHub releases; kept only when Microsoft-signed)'}) }
    foreach($module in $script:NSPScanBridgeRuntimeModules) {
        $gallery=Find-NSPGalleryModule -Name $module.Name
        if(-not $gallery -or [version]$gallery.Version -lt $module.MinimumVersion) {
            Write-NSPConsoleLine ("{0} {1} or later is not on the PowerShell Gallery yet; it cannot be installed." -f $module.Name,$module.MinimumVersion) -Role Warning
        }
        foreach($root in $roots) {
            $installed=@(Get-NSPAllUsersModuleVersion -Root $root -Name $module.Name)
            if(-not @($installed | Where-Object { $_.Version -ge $module.MinimumVersion }).Count -and $gallery -and [version]$gallery.Version -ge $module.MinimumVersion) {
                $steps.Add([pscustomobject]@{Action='Save';Name=$module.Name;Version=[version]$gallery.Version;Root=$root;Text="Install $($module.Name) $($gallery.Version) into $root"})
            }
            if($module.ReplaceOlder) {
                foreach($old in @($installed | Where-Object { $_.Version -lt $module.MinimumVersion })) {
                    $steps.Add([pscustomobject]@{Action='Remove';Name=$module.Name;Version=$old.Version;Path=$old.Path;Text="Remove older $($module.Name) $($old.Version) at $($old.Path)"})
                }
            }
        }
    }
    if(-not $steps.Count) { Write-NSPConsoleLine 'PowerShell 7 and every runtime module are already installed for all users.' -Role Success }
    else {
        Write-NSPConsoleLine 'Install plan:'
        foreach($step in $steps) { Write-NSPConsoleLine "  - $($step.Text)" }
        if($dryRun) { Write-NSPConsoleLine 'DRY RUN: nothing installed or removed.' -Role Warning }
        elseif(Read-NSPConfirm -Prompt 'Apply this install plan now?') {
            foreach($step in $steps) {
                try {
                    switch($step.Action) {
                        'InstallPowerShell7' {
                            $installer=Save-NSPPowerShell7Installer -Destination (Join-Path $env:ProgramData 'NSP\Installers')
                            Write-NSPConsoleLine ("Downloaded PowerShell {0}, signed by {1}." -f $installer.Version,$installer.Signer) -Role Muted
                            $code=Install-NSPPowerShell7Msi -MsiPath $installer.Path
                            Write-NSPConsoleLine $(if($code -eq 3010){'PowerShell 7 installed; Windows asks for a restart to finish.'}else{'PowerShell 7 installed.'}) -Role Success
                            $pwsh=Find-NSPPowerShell7
                        }
                        'Save' { Save-NSPGalleryModule -Name $step.Name -Version $step.Version -Path $step.Root; Write-NSPConsoleLine "Installed $($step.Name) $($step.Version) into $($step.Root)." -Role Success }
                        'Remove' { Remove-Item -LiteralPath $step.Path -Recurse -Force -ErrorAction Stop; Write-NSPConsoleLine "Removed $($step.Name) $($step.Version)." -Role Success }
                    }
                } catch { Write-NSPConsoleLine "$($step.Text) failed: $($_.Exception.Message)" -Role Error }
            }
        }
    }
    if(-not $pwsh) { Write-NSPConsoleLine 'PowerShell 7 is not installed, so its module resolution was not checked.' -Role Warning; return }
    $resolution=@(Test-NSPScanBridgeModuleResolution -PowerShellPath $pwsh.Path)
    foreach($row in $resolution) {
        $role=switch($row.Status) { 'OK' {'Success'} 'Missing' {'Error'} default {'Warning'} }
        $text=switch($row.Status) {
            'OK' { "{0}: PowerShell 7 loads {1} from {2}." -f $row.Module,$row.FirstFound,$row.FirstFoundPath }
            'Missing' { "{0}: not found by PowerShell 7 outside user profiles." -f $row.Module }
            'OlderFirst' { "{0}: {1} is found first ({2}); {3} meets the minimum only when requested by version." -f $row.Module,$row.FirstFound,$row.FirstFoundPath,$row.MeetsMinimum }
            default { "{0}: only {1} is found; {2} or later is needed." -f $row.Module,$row.FirstFound,$row.Minimum }
        }
        Write-NSPConsoleLine $text -Role $role
    }
    Write-NSPConsoleLine 'This check runs as you without user-profile folders; the task account''s first run is the real proof.' -Role Muted
    $resolution
}

function Resolve-NSPScanBridgeInstalledRunner {
    # The runner of the highest all-users NSP.ScanBridge (PowerShell 7's folder first), or $null.
    $roots=@(Get-NSPAllUsersModuleRoot)
    [array]::Reverse($roots)
    foreach($root in $roots) {
        $best=@(Get-NSPAllUsersModuleVersion -Root $root -Name 'NSP.ScanBridge' | Sort-Object Version -Descending)[0]
        if($best) {
            $runner=Join-Path $best.Path 'scripts\Run-ScanBridge.ps1'
            if(Test-Path -LiteralPath $runner -PathType Leaf) { return [pscustomobject]@{Runner=$runner;Version=$best.Version;Root=$root} }
        }
    }
}
