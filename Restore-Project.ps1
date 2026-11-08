#Requires -Version 5.1
<#
.SYNOPSIS
  List and restore project snapshots from Google Drive. Always restores into a NEW folder;
  it never touches or overwrites your live project.

.EXAMPLE
  .\Restore-Project.ps1                                  # list projects that have backups
  .\Restore-Project.ps1 -Project MyApp                   # list MyApp's snapshots
  .\Restore-Project.ps1 -Project MyApp -Latest           # restore the newest into .\MyApp_restored_<time>
  .\Restore-Project.ps1 -Project MyApp -Snapshot MyApp_2026-11-08_210000.zip -Destination D:\Restores
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Snapshot,
    [switch]$Latest,
    [string]$Destination = (Get-Location).Path,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/ProjectBackup.psm1') -Force -DisableNameChecking
$config = Read-BackupConfig -Path $ConfigPath

if (-not $Project) {
    Write-Host "Projects with backups in $(Get-RemotePath -Config $config):"
    Invoke-Rclone @('lsf', (Get-RemotePath -Config $config), '--dirs-only') | ForEach-Object { '  ' + $_.TrimEnd('/') }
    Write-Host "`nNext: .\Restore-Project.ps1 -Project <name>"
    exit 0
}

$snaps = @(Get-RemoteSnapshots -Config $config -ProjectName $Project |
    ForEach-Object { ConvertFrom-SnapshotName $_ } | Where-Object { $_ } | Sort-Object Time -Descending)
if ($snaps.Count -eq 0) { throw "No snapshots found for '$Project'." }

if (-not $Snapshot -and -not $Latest) {
    Write-Host "Snapshots for ${Project} (newest first):"
    foreach ($s in $snaps) { '  {0}   {1:yyyy-MM-dd HH:mm}  {2}' -f $s.Name, $s.Time, $s.Label }
    Write-Host "`nNext: .\Restore-Project.ps1 -Project $Project -Latest   or   -Snapshot <name>"
    exit 0
}

$chosen = if ($Latest) { $snaps[0] } else { $snaps | Where-Object { $_.Name -eq $Snapshot } | Select-Object -First 1 }
if (-not $chosen) { throw "Snapshot '$Snapshot' not found. Run without -Snapshot to list them." }

$target = Join-Path $Destination ('{0}_restored_{1:yyyy-MM-dd_HHmmss}' -f $Project, $chosen.Time)
if (Test-Path -LiteralPath $target) { throw "Destination already exists: $target" }

$tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ("restore_" + $chosen.Name)
try {
    Write-Host "Downloading $($chosen.Name) ..."
    Invoke-Rclone @('copyto', (Get-RemotePath -Config $config -ProjectName $Project -FileName $chosen.Name), $tempZip) | Out-Null
    Write-Host "Extracting to $target ..."
    Expand-ProjectArchive -ZipPath $tempZip -Destination $target
    Write-Host "Restored to $target" -ForegroundColor Green
    Write-Host "Your live project was not changed. Compare, then copy back what you need."
} finally {
    if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force }
}
