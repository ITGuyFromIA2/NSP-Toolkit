function Test-NSPAgentRemovalElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-NSPAgentRemovalScript {
    # Runs the generated AgentRemoval script in a child PowerShell of the same edition, through -File
    # (a fixed, readable entry point; no generated command text). -Quiet discards its console output;
    # its transcript and -StatusPath file remain. Returns the exit code.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ArgumentList = @(),
        [switch]$Quiet
    )
    $exe = (Get-Process -Id $PID).Path
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $ArgumentList
    if ($Quiet) { & $exe @arguments | Out-Null } else { & $exe @arguments | Out-Host }
    return [int]$LASTEXITCODE
}
