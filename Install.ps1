#Requires -Version 5.1
<#
.SYNOPSIS
  One-time setup for Project Backup on Windows. Safe to re-run: each step checks
  whether it is already done.

  Run it from this folder with:
      powershell -ExecutionPolicy Bypass -File .\Install.ps1

  Steps (each asks first):
    1. Check rclone is installed and a Google Drive remote exists (offers to create it).
    2. Create config.json (asks for your projects folder).
    3. Register the daily Task Scheduler job.
    4. Add `backup` and `restore-backup` commands to your PowerShell profile.
    5. Add the Claude Code SessionStart hook to %USERPROFILE%\.claude\settings.json.

  .\Install.ps1 -Uninstall removes 3, 4 and 5. Your backups in Drive and config.json stay.
#>
[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
Import-Module (Join-Path $here 'lib/ProjectBackup.psm1') -Force -DisableNameChecking

$TaskName = 'Project Backup (daily)'
$ProfileStart = '# >>> ProjectBackup >>>'
$ProfileEnd = '# <<< ProjectBackup <<<'
$HookMarker = 'Start-BackgroundBackup.ps1'
$ClaudeSettings = Join-Path $HOME '.claude\settings.json'
$fwd = $here.Replace('\', '/')
$hereQ = $here.Replace("'", "''")   # for use inside single-quoted strings

function Confirm-Step([string]$Question) {
    $a = Read-Host "$Question [Y/n]"
    return ($a -eq '' -or $a -match '^(y|yes)$')
}

function Remove-ProfileBlock {
    if (-not (Test-Path -LiteralPath $PROFILE)) { return }
    $text = Get-Content -LiteralPath $PROFILE -Raw
    $pattern = '(?s)\r?\n?' + [regex]::Escape($ProfileStart) + '.*?' + [regex]::Escape($ProfileEnd) + '\r?\n?'
    $new = [regex]::Replace($text, $pattern, "`r`n")
    if ($new -ne $text) { Set-Content -LiteralPath $PROFILE -Value $new.TrimEnd() -Encoding UTF8; Write-Host 'Removed commands from your PowerShell profile.' }
}

function Read-ClaudeSettings {
    if (Test-Path -LiteralPath $ClaudeSettings) {
        $raw = Get-Content -LiteralPath $ClaudeSettings -Raw
        if ($raw.Trim()) { return ($raw | ConvertFrom-Json) }
    }
    return [pscustomobject]@{}
}

function Save-ClaudeSettings($Settings) {
    $dir = Split-Path $ClaudeSettings -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $ClaudeSettings) {
        $bak = "$ClaudeSettings.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $ClaudeSettings -Destination $bak
        Write-Host "Saved a copy of your Claude settings to $bak"
    }
    # UTF-8 without BOM, which Claude Code reads reliably.
    [System.IO.File]::WriteAllText($ClaudeSettings, ($Settings | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding $false))
}

function Remove-ClaudeHook {
    if (-not (Test-Path -LiteralPath $ClaudeSettings)) { return }
    $s = Read-ClaudeSettings
    if (-not ($s.PSObject.Properties.Name -contains 'hooks') -or -not ($s.hooks.PSObject.Properties.Name -contains 'SessionStart')) { return }
    $kept = @($s.hooks.SessionStart | Where-Object { -not (($_ | ConvertTo-Json -Depth 10) -like "*$HookMarker*") })
    if ($kept.Count -eq @($s.hooks.SessionStart).Count) { return }
    if ($kept.Count -eq 0) { $s.hooks.PSObject.Properties.Remove('SessionStart') } else { $s.hooks.SessionStart = $kept }
    Save-ClaudeSettings $s
    Write-Host 'Removed the Claude Code hook.'
}

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host 'Removed the daily scheduled task.'
    }
    Remove-ProfileBlock
    Remove-ClaudeHook
    Write-Host 'Uninstalled. Your backups in Google Drive and config.json were left alone.'
    exit 0
}

# ---------------------------------------------------------------- 1. rclone + Drive remote
Write-Host "`n== 1. rclone and Google Drive ==" -ForegroundColor Cyan
if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Write-Host 'rclone is not installed.'
    if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Confirm-Step 'Install it now with winget?')) {
        winget install --id Rclone.Rclone -e --accept-source-agreements --accept-package-agreements
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }
    if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
        Write-Host 'Install rclone (https://rclone.org/downloads/ or: winget install Rclone.Rclone), open a NEW PowerShell window, and run Install.ps1 again.' -ForegroundColor Yellow
        exit 1
    }
}
Write-Host "rclone found: $((Get-Command rclone).Source)"

$configPath = Join-Path $here 'config.json'
$remoteName = 'gdrive'
if (Test-Path -LiteralPath $configPath) { $remoteName = (Read-BackupConfig -Path $configPath).remote }
$remotes = @(rclone listremotes) | ForEach-Object { $_.Trim().TrimEnd(':') }
if ($remotes -contains $remoteName) {
    Write-Host "rclone remote '$remoteName' already exists."
} else {
    Write-Host "No rclone remote named '$remoteName' yet. Creating it opens your browser so you can sign in to Google."
    Write-Host "It uses the 'drive.file' scope: rclone can only see files it created itself, never the rest of your Drive."
    if (Confirm-Step "Create the '$remoteName' remote now?") {
        rclone config create $remoteName drive scope=drive.file
        if ($LASTEXITCODE -ne 0) { throw 'rclone config create failed. You can run "rclone config" yourself instead (choose Google Drive, scope drive.file).' }
    } else {
        Write-Host "Skipped. Run later:  rclone config create $remoteName drive scope=drive.file" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 2. config.json
Write-Host "`n== 2. config.json ==" -ForegroundColor Cyan
if (Test-Path -LiteralPath $configPath) {
    Write-Host "config.json already exists, leaving it as it is: $configPath"
} else {
    $cfg = Get-Content -LiteralPath (Join-Path $here 'config.example.json') -Raw | ConvertFrom-Json
    $roots = @()
    Write-Host 'Enter the folder(s) that CONTAIN your projects (each subfolder is backed up as one project).'
    Write-Host 'Press Enter on an empty line when done.'
    while ($true) {
        $r = Read-Host 'Projects folder'
        if (-not $r) { break }
        $r = $r.Trim('"', ' ')
        if (Test-Path -LiteralPath $r -PathType Container) { $roots += (Get-NormalizedPath $r) } else { Write-Host "  Not found: $r" -ForegroundColor Yellow }
    }
    $cfg.projectRoots = $roots
    $cfg.projects = @()
    $cfg.remote = $remoteName
    [System.IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Wrote $configPath. Edit it any time to add single projects, exclusions or retention."
}
$config = Read-BackupConfig -Path $configPath

# ---------------------------------------------------------------- 3. scheduled task
Write-Host "`n== 3. Daily backup ==" -ForegroundColor Cyan
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Scheduled task '$TaskName' already exists (re-run with -Uninstall first to change the time)."
} elseif (Confirm-Step "Back up changed projects every day at $($config.dailyTime)?") {
    $ps = (Get-Command powershell.exe).Source
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$here\Backup-Projects.ps1`" -IfChanged -Quiet" -WorkingDirectory $here
    $trigger = New-ScheduledTaskTrigger -Daily -At $config.dailyTime
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'Snapshots changed projects to Google Drive (Claude-Project-Backup).' | Out-Null
    Write-Host "Registered. If the PC is off at $($config.dailyTime), it runs the next time you log in."
}

# ---------------------------------------------------------------- 4. profile commands
Write-Host "`n== 4. 'backup' command ==" -ForegroundColor Cyan
$hasBlock = (Test-Path -LiteralPath $PROFILE) -and ((Get-Content -LiteralPath $PROFILE -Raw) -like "*$ProfileStart*")
if ($hasBlock) {
    Write-Host 'Your PowerShell profile already has the backup commands.'
} elseif (Confirm-Step "Add 'backup' and 'restore-backup' commands to your PowerShell profile?") {
    $block = @"
$ProfileStart
# Added by Claude-Project-Backup Install.ps1. Remove with: Install.ps1 -Uninstall
function backup {
    param([string]`$Label, [switch]`$All, [switch]`$DryRun, [switch]`$Status, [switch]`$IfChanged)
    `$a = @{}
    if (-not `$All -and -not `$Status) { `$a.Project = (Get-Location).Path }
    if (`$Label) { `$a.Label = `$Label }
    if (`$DryRun) { `$a.DryRun = `$true }
    if (`$Status) { `$a.Status = `$true }
    if (`$IfChanged) { `$a.IfChanged = `$true }
    & '$hereQ\Backup-Projects.ps1' @a
}
function restore-backup { & '$hereQ\Restore-Project.ps1' @args }
$ProfileEnd
"@
    $profileDir = Split-Path $PROFILE -Parent
    if (-not (Test-Path -LiteralPath $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    Add-Content -LiteralPath $PROFILE -Value "`r`n$block" -Encoding UTF8
    Write-Host "Added to $PROFILE (open a new PowerShell window to use it)."
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -eq 'Undefined' -or $policy -eq 'Restricted') {
        if ((Get-ExecutionPolicy) -in @('Restricted', 'AllSigned') -and (Confirm-Step 'PowerShell is set to block scripts, so the commands would not load. Allow local scripts for your user (RemoteSigned)?')) {
            Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
        }
    }
}

# ---------------------------------------------------------------- 5. Claude Code hook
Write-Host "`n== 5. Back up before every Claude Code session ==" -ForegroundColor Cyan
$settingsObj = Read-ClaudeSettings
$already = ($settingsObj | ConvertTo-Json -Depth 32) -like "*$HookMarker*"
if ($already) {
    Write-Host 'The Claude Code hook is already installed.'
} elseif (Confirm-Step 'Add a Claude Code hook that snapshots the project (in the background) whenever a Claude session starts?') {
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$fwd/hooks/$HookMarker`""
    $entry = [pscustomobject]@{
        matcher = 'startup'
        hooks   = @([pscustomobject]@{ type = 'command'; command = $command; timeout = 30 })
    }
    if (-not ($settingsObj.PSObject.Properties.Name -contains 'hooks')) { $settingsObj | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    if ($settingsObj.hooks.PSObject.Properties.Name -contains 'SessionStart') {
        $settingsObj.hooks.SessionStart = @($settingsObj.hooks.SessionStart) + $entry
    } else {
        $settingsObj.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue @($entry)
    }
    Save-ClaudeSettings $settingsObj
    Write-Host "Added to $ClaudeSettings. It takes effect in new Claude Code sessions."
}

Write-Host "`nAll done. Next steps:" -ForegroundColor Green
Write-Host '  1. Open a new PowerShell window.'
Write-Host '  2. backup -All -DryRun      # see which projects would be backed up, and their sizes'
Write-Host '  3. backup -All -Label first # first full backup'
Write-Host '  4. restore-backup           # check you can see and restore them'
