#Requires -Version 5.1
<#
.SYNOPSIS
  Back up projects to Google Drive as timestamped zip snapshots (add-only, never a mirror).

.EXAMPLE
  .\Backup-Projects.ps1                         # back up every configured project
  .\Backup-Projects.ps1 -IfChanged              # only projects changed since their last snapshot (the daily task uses this)
  .\Backup-Projects.ps1 -Project . -Label v1-working   # milestone snapshot of the current project (never pruned)
  .\Backup-Projects.ps1 -DryRun                 # list projects, file counts and sizes; uploads nothing
  .\Backup-Projects.ps1 -Status                 # when each project was last backed up
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Label,
    [switch]$IfChanged,
    [switch]$DryRun,
    [switch]$Status,
    [switch]$NoPrune,
    [switch]$Quiet,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/ProjectBackup.psm1') -Force -DisableNameChecking

Initialize-BackupLog -Quiet:$Quiet
$config = Read-BackupConfig -Path $ConfigPath

if ($Project) { $targets = @(Resolve-ProjectForPath -Path $Project -Config $config) }
else { $targets = @(Get-ConfiguredProjects -Config $config) }

if ($targets.Count -eq 0) { Write-BackupLog 'No projects found. Check projectRoots / projects in config.json.' 'WARN'; exit 0 }

$state = Read-BackupState

if ($Status) {
    foreach ($t in $targets) {
        $s = $state[$t.Path]
        $when = if ($s) { $s.lastBackup } else { 'never' }
        $snap = if ($s) { $s.lastSnapshot } else { '' }
        '{0,-32} {1,-20} {2}' -f $t.Name, $when, $snap
    }
    exit 0
}

$lock = $null
if (-not $DryRun) { $lock = Enter-BackupLock }

$maxBytes = [int64]$config.maxProjectSizeMB * 1MB
$failed = 0; $done = 0; $skippedUnchanged = 0
$totalBytes = [int64]0
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) 'ProjectBackup'
if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

try {
    foreach ($t in $targets) {
        $zipPath = $null
        try {
            $excludes = Get-ProjectExcludes -ProjectPath $t.Path -BaseExcludes $config.exclude
            $scan = Get-ProjectFiles -ProjectPath $t.Path -Excludes $excludes
            foreach ($e in $scan.Errors) { Write-BackupLog "[$($t.Name)] $e" 'WARN' }
            $bytes = [int64]0; foreach ($f in $scan.Files) { $bytes += $f.Length }
            $sizeText = '{0:N1} MB' -f ($bytes / 1MB)

            if ($DryRun) {
                $prev = $state[$t.Path]
                $fp = Get-FileListFingerprint -Files $scan.Files
                $changed = if (-not $prev) { 'never backed up' } elseif ($prev.fingerprint -ne $fp) { 'changed' } else { 'unchanged' }
                $flag = if ($bytes -gt $maxBytes) { '  <-- over maxProjectSizeMB, would be SKIPPED' } else { '' }
                Write-Host ('{0,-32} {1,7} files {2,12}  {3,-16} {4}{5}' -f $t.Name, $scan.Files.Count, $sizeText, $changed, $t.Path, $flag)
                $totalBytes += $bytes
                continue
            }

            if ($scan.Files.Count -eq 0) { Write-BackupLog "[$($t.Name)] no files to back up, skipped." 'WARN'; continue }
            if ($bytes -gt $maxBytes) {
                Write-BackupLog "[$($t.Name)] $sizeText is over maxProjectSizeMB ($($config.maxProjectSizeMB)). Skipped. Add big folders to exclude / .backupignore, or raise the limit." 'ERROR'
                $failed++; continue
            }

            $fingerprint = Get-FileListFingerprint -Files $scan.Files
            $prev = $state[$t.Path]
            if ($IfChanged -and $prev -and $prev.fingerprint -eq $fingerprint) {
                Write-BackupLog "[$($t.Name)] unchanged since $($prev.lastBackup), skipped."
                $skippedUnchanged++; continue
            }

            $now = Get-Date
            $snapName = Get-SnapshotName -ProjectName $t.Name -Time $now -Label $Label
            $zipPath = Join-Path $tempDir $snapName
            if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

            Write-BackupLog "[$($t.Name)] zipping $($scan.Files.Count) files ($sizeText)..."
            $result = New-ProjectArchive -ZipPath $zipPath -Files $scan.Files
            foreach ($s in $result.Skipped) { Write-BackupLog "[$($t.Name)] could not read (skipped): $s" 'WARN' }
            $zipSize = (Get-Item -LiteralPath $zipPath).Length

            $remoteFile = Get-RemotePath -Config $config -ProjectName $t.Name -FileName $snapName
            Write-BackupLog "[$($t.Name)] uploading $('{0:N1} MB' -f ($zipSize / 1MB)) to $remoteFile ..."
            Invoke-Rclone @('copyto', $zipPath, $remoteFile) | Out-Null

            # Confirm it actually arrived before recording success or pruning anything.
            $remoteNames = Get-RemoteSnapshots -Config $config -ProjectName $t.Name
            if ($remoteNames -notcontains $snapName) { throw "Upload reported success but $snapName is not listed on the remote." }

            $state[$t.Path] = [pscustomobject]@{
                fingerprint  = $fingerprint
                lastBackup   = $now.ToString('yyyy-MM-dd HH:mm:ss')
                lastSnapshot = $snapName
                name         = $t.Name
            }
            Save-BackupState -State $state
            $done++
            Write-BackupLog "[$($t.Name)] backed up: $snapName" 'OK'

            if (-not $NoPrune) {
                $toPrune = @(Select-SnapshotsToPrune -Names $remoteNames -Retention $config.retention -Now $now)
                foreach ($old in $toPrune) {
                    if ($old -eq $snapName) { continue }
                    Invoke-Rclone @('deletefile', (Get-RemotePath -Config $config -ProjectName $t.Name -FileName $old)) | Out-Null
                    Write-BackupLog "[$($t.Name)] pruned old snapshot (moved to Drive trash): $old"
                }
            }
        } catch {
            $failed++
            Write-BackupLog "[$($t.Name)] FAILED: $($_.Exception.Message)" 'ERROR'
        } finally {
            if ($zipPath -and (Test-Path -LiteralPath $zipPath)) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
        }
    }
} finally {
    if ($lock) { $lock.Dispose() }
}

if ($DryRun) {
    Write-Host ('{0} projects, {1:N1} MB total before compression. Nothing was uploaded.' -f $targets.Count, ($totalBytes / 1MB))
    exit 0
}
$level = if ($failed) { 'ERROR' } else { 'OK' }
Write-BackupLog "Finished: $done backed up, $skippedUnchanged unchanged, $failed failed." $level
if ($failed) { exit 1 }
