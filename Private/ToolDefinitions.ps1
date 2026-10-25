# The tools Start-NSPToolkit knows about, and what the shared plumbing needs to know about each:
# where its module lives, how to start it, which answer fields are secrets, and where the old
# zip-era installs left their files (for Move-NSPToolLegacyData).
#
# Name is the short key used everywhere else (work folder, hand-off files): AD, NPS, PKI, FortiClient, MDE.

$script:NSPToolDefinitions = @(
    [pscustomobject]@{
        Name             = 'AD'
        DisplayName      = 'AD Manager'
        Description      = 'VPN groups and OUs, certificate auto-enrollment GPO, WMI filters, VPN inventory export.'
        ModuleName       = 'NSP.ActiveDirectory'
        MinimumVersion   = '0.1.0'
        EntryFunction    = 'Start-NSPADManager'
        ShimFunction     = 'New-NSPADShim'
        RequiresAdmin    = $true
        Detect           = { [bool](Get-Module -ListAvailable -Name ActiveDirectory) }
        DetectHint       = 'ActiveDirectory module (RSAT) present'
        SecretFields     = @()
        Legacy           = [pscustomobject]@{
            StagingFolder   = 'ADStaging'
            ExtractFolder   = 'ADManager'
            AnswersFile     = 'ADAnswers.json'
            ShimNames       = @('AD-Manager.ps1', 'AD-Manager-Shim.ps1')
            ShimAnswersVar  = 'ADAnswersJson'
            FixedPaths      = @()
        }
    }
    [pscustomobject]@{
        Name             = 'NPS'
        DisplayName      = 'NPS Manager'
        Description      = 'NPS / RADIUS: clients, policies, troubleshooting, NPS Extension, hand-back to the Orchestrator.'
        ModuleName       = 'NSP.NPS'
        MinimumVersion   = '0.1.0'
        EntryFunction    = 'Start-NSPNpsManager'
        ShimFunction     = 'New-NSPNpsShim'
        RequiresAdmin    = $true
        Detect           = { [bool](Get-Service -Name IAS -ErrorAction SilentlyContinue) }
        DetectHint       = 'NPS service (IAS) installed'
        SecretFields     = @('RADIUSSecret')
        Legacy           = [pscustomobject]@{
            StagingFolder   = 'NPSStaging'
            ExtractFolder   = 'NPSManager'
            AnswersFile     = 'NPSAnswers.json'
            ShimNames       = @('NPS-Manager.ps1', 'NPS-Manager_Shim.ps1')
            ShimAnswersVar  = 'NPSAnswersJson'
            FixedPaths      = @()
        }
    }
    [pscustomobject]@{
        Name             = 'PKI'
        DisplayName      = 'PKI Manager'
        Description      = 'Certificate Authority, templates, OCSP, TameMyCerts, App Proxy CRL, FortiGate certificate hand-off.'
        ModuleName       = 'NSP.PKI'
        MinimumVersion   = '0.1.0'
        EntryFunction    = 'Start-NSPPkiManager'
        ShimFunction     = 'New-NSPPkiShim'
        RequiresAdmin    = $true
        Detect           = { [bool](Get-Service -Name CertSvc -ErrorAction SilentlyContinue) }
        DetectHint       = 'Certificate Services (CertSvc) installed'
        SecretFields     = @('FortiGatePfxPassword')
        Legacy           = [pscustomobject]@{
            StagingFolder   = 'CAStaging'
            ExtractFolder   = 'CAManager'
            AnswersFile     = 'CAAnswers.json'
            ShimNames       = @('CA-Manager.ps1', 'CA-Manager-Shim.ps1')
            ShimAnswersVar  = 'CAAnswersJson'
            FixedPaths      = @()
        }
    }
    [pscustomobject]@{
        Name             = 'FortiClient'
        DisplayName      = 'FortiClient Troubleshooting'
        Description      = 'Endpoint FortiClient VPN troubleshooting toolkit.'
        ModuleName       = 'NSP.FortiClient'
        MinimumVersion   = '0.1.0'
        EntryFunction    = 'Start-NSPFortiClientToolkit'
        ShimFunction     = 'New-NSPFortiClientShim'
        RequiresAdmin    = $true
        Detect           = {
            [bool](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'FortiClient*' })
        }
        DetectHint       = 'FortiClient installed'
        SecretFields     = @()
        Legacy           = [pscustomobject]@{
            StagingFolder   = $null
            ExtractFolder   = $null
            AnswersFile     = $null
            ShimNames       = @()
            ShimAnswersVar  = $null
            FixedPaths      = @('C:\Admin\FCTToolkit\Staging')
        }
    }
    [pscustomobject]@{
        Name             = 'MDE'
        DisplayName      = 'MDE Troubleshooter'
        Description      = 'Defender for Endpoint: prove an MsSense (EDR) sharing-violation collision with an app, for an EDR exclusion request.'
        ModuleName       = 'NSP.Win.MDE'
        MinimumVersion   = '0.1.0'
        EntryFunction    = 'Start-NSPMDETroubleshooter'
        ShimFunction     = $null
        RequiresAdmin    = $true
        Detect           = { [bool](Get-Service -Name Sense -ErrorAction SilentlyContinue) }
        DetectHint       = 'Defender for Endpoint sensor (Sense) installed'
        SecretFields     = @()
        Legacy           = [pscustomobject]@{
            StagingFolder   = $null
            ExtractFolder   = $null
            AnswersFile     = $null
            ShimNames       = @()
            ShimAnswersVar  = $null
            FixedPaths      = @()
        }
    }
)

function Get-NSPToolDefinition {
    param([Parameter(Mandatory)][string]$Tool)
    $def = $script:NSPToolDefinitions | Where-Object { $_.Name -eq $Tool }
    if (-not $def) { throw "Unknown tool '$Tool'. Known tools: $(($script:NSPToolDefinitions | ForEach-Object Name) -join ', ')." }
    return $def
}
