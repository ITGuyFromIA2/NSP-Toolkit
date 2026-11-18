function Get-NSPToolkitGraphContext {
    # The current Microsoft Graph context, or $null. Get-MgContext can throw a terminating
    # SessionNotInitialized (which -ErrorAction does not suppress) when the SDK's session was reset
    # in this process; that is "no context" here, not a failure.
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) { return $null }
    try { return (Get-MgContext -ErrorAction Stop) } catch { return $null }
}
