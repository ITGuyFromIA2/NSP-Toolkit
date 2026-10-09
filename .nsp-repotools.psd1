@{
    # Settings for NSP.RepoTools. Tracked: name what is accepted, never a client.
    Publish = @{
        # Launcher\Start-NSPToolkit.ps1 is distributed on its own, not in the module package.
        Exclude = @('Launcher/*')
    }
}