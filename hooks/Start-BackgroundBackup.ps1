#Requires -Version 5.1
<#
  Called by the Claude Code SessionStart hook. Starts a backup of the project Claude
  is opening in a hidden background process and returns at once, so Claude isn't delayed.
  Never fails the hook: any problem is written to the backup log instead.
#>
$ErrorActionPreference = 'SilentlyContinue'
try {
    $dir = $env:CLAUDE_PROJECT_DIR
    if (-not $dir -and [Console]::IsInputRedirected) {
        $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
        $dir = $payload.cwd
    }
    if (-not $dir) { exit 0 }
    $dir = $dir.TrimEnd([char]92, [char]47)   # a trailing backslash would break the quoted argument

    $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Backup-Projects.ps1'
    $exe = (Get-Process -Id $PID).Path   # same PowerShell that runs this hook (powershell.exe or pwsh)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script`"",
                 '-Project', "`"$dir`"", '-Label', 'pre-claude', '-IfChanged', '-Quiet')
    Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden | Out-Null
} catch { }
exit 0
