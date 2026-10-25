@{
    RootModule        = 'NSP.Toolkit.psm1'
    ModuleVersion     = '0.1.3'
    GUID              = '768f2bfa-0068-4fa0-a2fd-ba6660e2f3ca'
    Author            = 'Network Systems Plus'
    CompanyName       = 'Network Systems Plus'
    Copyright         = '(c) Network Systems Plus. All rights reserved.'
    Description       = 'Shared plumbing and the single entry point for NSP operator tools: Start-NSPToolkit launcher, per-tool work folder and answers, hand-off files between tools, legacy clean-up, dry-run step engine and version stamp. Windows PowerShell 5.1 compatible.'

    # 5.1 is the floor for every NSP toolkit, and the module must import on a bare 5.1 host -
    # sibling NSP modules are loaded on first use (Private\Import-NSPToolkitModule.ps1), never
    # declared as RequiredModules.
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Start-NSPToolkit'
        'Get-NSPToolkitTool'
        'Get-NSPToolWorkPath'
        'Get-NSPToolAnswers'
        'Save-NSPToolAnswers'
        'Import-NSPToolSeedAnswers'
        'Merge-NSPHandoffAnswers'
        'New-NSPHandoff'
        'Export-NSPHandoff'
        'Import-NSPHandoff'
        'Move-NSPToolLegacyData'
        'Clear-NSPToolClientData'
        'Invoke-NSPStep'
        'Get-NSPDryRun'
        'Set-NSPDryRun'
        'Get-NSPToolVersionStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('NSP', 'Toolkit', 'Launcher', 'Handoff', 'DryRun')
            ProjectUri   = 'https://github.com/ITGuyFromIA2/NSP-Toolkit'
            LicenseUri   = 'https://github.com/ITGuyFromIA2/NSP-Toolkit/blob/main/LICENSE'
            ReleaseNotes = 'https://github.com/ITGuyFromIA2/NSP-Toolkit/blob/main/CHANGELOG.md'
        }
    }
}