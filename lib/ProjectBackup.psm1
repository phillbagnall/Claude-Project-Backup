#Requires -Version 5.1
<#
  Shared functions for the Project Backup toolkit.
  Works in Windows PowerShell 5.1 (built into Windows) and PowerShell 7+.

  Safety rules this module follows:
    * Backups are ADD-ONLY snapshots. Nothing here ever runs `rclone sync`, `purge`
      or deletes anything in your project folders.
    * The only remote deletion is retention pruning of old snapshot zips, which
      only touches files whose names match the snapshot naming pattern, and on
      Google Drive those go to the Drive trash (recoverable for 30 days).
#>

Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:SnapshotPattern = '^(?<project>.+)_(?<ts>\d{4}-\d{2}-\d{2}_\d{6})(?:_(?<label>[A-Za-z0-9-]+))?\.zip$'
$script:TimestampFormat = 'yyyy-MM-dd_HHmmss'

# ---------------------------------------------------------------- config / paths

function Get-BackupDataDir {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $HOME '.local/share' }
    $dir = Join-Path $base 'ProjectBackup'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-DefaultConfig {
    [pscustomobject]@{
        projectRoots       = @()
        projects           = @()
        remote             = 'gdrive'
        remoteFolder       = 'ProjectBackups'
        exclude            = @('node_modules', '.venv', 'venv', 'env', '__pycache__', '.pytest_cache', '.mypy_cache',
                               'bin', 'obj', 'dist', 'build', 'out', '.next', '.nuxt', '.turbo', '.parcel-cache',
                               'target', '.gradle', 'coverage', '.cache', '*.log', 'Thumbs.db', '.DS_Store')
        maxProjectSizeMB   = 10240
        dailyTime          = '21:00'
        retention          = [pscustomobject]@{
            keepLast          = 20
            keepDailyDays     = 30
            keepMonthlyMonths = 12
            unprotectedLabels = @('pre-claude', 'daily')
        }
    }
}

function Read-BackupConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path. Copy config.example.json to config.json and edit it (or run Install.ps1)."
    }
    $user = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $cfg = Get-DefaultConfig
    foreach ($p in $user.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }   # allow "_comment" keys
        if ($p.Name -eq 'retention') {
            foreach ($r in $p.Value.PSObject.Properties) { $cfg.retention.$($r.Name) = $r.Value }
        } elseif ($cfg.PSObject.Properties.Name -contains $p.Name) {
            $cfg.$($p.Name) = $p.Value
        } else {
            Write-Warning "Unknown config setting '$($p.Name)' ignored."
        }
    }
    foreach ($k in 'projectRoots', 'projects', 'exclude') { $cfg.$k = @($cfg.$k | Where-Object { $_ }) }
    $cfg.retention.unprotectedLabels = @($cfg.retention.unprotectedLabels)
    return $cfg
}

# ---------------------------------------------------------------- logging

$script:LogFile = $null
$script:Quiet = $false

function Initialize-BackupLog {
    param([switch]$Quiet)
    $script:Quiet = [bool]$Quiet
    $logDir = Join-Path (Get-BackupDataDir) 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $script:LogFile = Join-Path $logDir ("backup_{0}.log" -f (Get-Date -Format 'yyyy-MM'))
}

function Write-BackupLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
    if (-not $script:Quiet) {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
    }
}

# ---------------------------------------------------------------- project discovery

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Get-ConfiguredProjects {
    <# Returns objects: Path, Name (the Drive folder name). #>
    param([Parameter(Mandatory)]$Config)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($root in $Config.projectRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { Write-BackupLog "Project root not found: $root" 'WARN'; continue }
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $_.Name -notlike '.*' } |
            ForEach-Object { $paths.Add((Get-NormalizedPath $_.FullName)) }
    }
    foreach ($p in $Config.projects) {
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { Write-BackupLog "Project folder not found: $p" 'WARN'; continue }
        $paths.Add((Get-NormalizedPath $p))
    }
    $unique = @($paths | Sort-Object -Unique)
    $unique = @($unique | Where-Object { -not (Test-Path -LiteralPath (Join-Path $_ '.nobackup')) })
    return @(Resolve-ProjectNames -Paths $unique)
}

function Resolve-ProjectNames {
    <# Drive folder name = folder name; if two projects share a folder name, prefix the parent folder name. #>
    param([string[]]$Paths)
    $leafCounts = @{}
    foreach ($p in $Paths) { $l = (Split-Path $p -Leaf).ToLowerInvariant(); $leafCounts[$l] = 1 + [int]$leafCounts[$l] }
    foreach ($p in $Paths) {
        $leaf = Split-Path $p -Leaf
        $name = $leaf
        if ($leafCounts[$leaf.ToLowerInvariant()] -gt 1) { $name = '{0}-{1}' -f (Split-Path (Split-Path $p -Parent) -Leaf), $leaf }
        [pscustomobject]@{ Path = $p; Name = (ConvertTo-SafeName $name) }
    }
}

function ConvertTo-SafeName {
    param([Parameter(Mandatory)][string]$Name)
    $safe = ($Name -replace '[\\/:*?"<>|\x00-\x1f]', '-').Trim(' ', '.')
    if (-not $safe) { $safe = 'project' }
    return $safe
}

function ConvertTo-SafeLabel {
    param([string]$Label)
    if (-not $Label) { return '' }
    return (($Label -replace '[^A-Za-z0-9-]+', '-').Trim('-'))
}

function Resolve-ProjectForPath {
    <#
      Given any folder (e.g. where Claude was started), return the configured project
      that contains it. If it isn't inside a configured project, treat the folder itself
      as the project, unless it is a drive root or the user's home folder.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Config)
    $target = Get-NormalizedPath $Path
    $configured = Get-ConfiguredProjects -Config $Config
    $sep = [System.IO.Path]::DirectorySeparatorChar
    foreach ($proj in ($configured | Sort-Object { $_.Path.Length } -Descending)) {
        if ($target -ieq $proj.Path -or $target.StartsWith($proj.Path + $sep, [StringComparison]::OrdinalIgnoreCase)) { return $proj }
    }
    $homeDir = Get-NormalizedPath $HOME
    $driveRoot = Get-NormalizedPath ([System.IO.Path]::GetPathRoot($target))
    if ($target -ieq $homeDir -or $target -ieq $driveRoot) {
        throw "Refusing to back up '$target' (drive root or home folder). Run it from inside a project folder."
    }
    return [pscustomobject]@{ Path = $target; Name = (ConvertTo-SafeName (Split-Path $target -Leaf)) }
}

# ---------------------------------------------------------------- file enumeration / exclusion

function Get-ProjectExcludes {
    <# Config excludes plus the project's own .backupignore lines (one pattern per line, # comments). #>
    param([Parameter(Mandatory)][string]$ProjectPath, [string[]]$BaseExcludes)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($e in $BaseExcludes) { if ($e) { $list.Add($e) } }
    $ignore = Join-Path $ProjectPath '.backupignore'
    if (Test-Path -LiteralPath $ignore) {
        foreach ($line in Get-Content -LiteralPath $ignore) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith('#')) { $list.Add($t.TrimEnd('/', '\')) }
        }
    }
    return , $list.ToArray()
}

function Test-Excluded {
    <#
      $Name: file or folder name. $RelativePath: path within the project using '/'.
      A pattern without '/' matches the name of any file or folder at any depth (wildcards * ? allowed).
      A pattern with '/' matches the relative path from the project root.
    #>
    param([string]$Name, [string]$RelativePath, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        if ($p.Contains('/') -or $p.Contains('\')) {
            $pp = $p.Replace('\', '/').TrimStart('/')
            if ($RelativePath -like $pp) { return $true }
        } elseif ($Name -like $p) { return $true }
    }
    return $false
}

function Get-ProjectFiles {
    <#
      Walks the project, never descending into excluded folders or links/junctions.
      Returns @{ Files = list of [pscustomobject]@{FullName;RelativePath;Length;LastWriteTimeUtc}; Errors = list of strings }
    #>
    param([Parameter(Mandatory)][string]$ProjectPath, [string[]]$Excludes)
    $root = Get-NormalizedPath $ProjectPath
    $files = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@((New-Object System.IO.DirectoryInfo $root), ''))
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $dir = $item[0]; $rel = $item[1]
        try { $entries = @($dir.EnumerateFileSystemInfos()) }
        catch { $errors.Add("Cannot read folder '$($dir.FullName)': $($_.Exception.Message)"); continue }
        foreach ($e in $entries) {
            $childRel = if ($rel) { "$rel/$($e.Name)" } else { $e.Name }
            if (Test-Excluded -Name $e.Name -RelativePath $childRel -Patterns $Excludes) { continue }
            $isLink = [bool]($e.Attributes -band [IO.FileAttributes]::ReparsePoint)
            if ($e -is [System.IO.DirectoryInfo]) {
                if ($isLink) { continue }   # don't follow junctions/symlinks (avoids loops and backing up other places)
                $stack.Push(@($e, $childRel))
            } else {
                $files.Add([pscustomobject]@{
                    FullName         = $e.FullName
                    RelativePath     = $childRel
                    Length           = $e.Length
                    LastWriteTimeUtc = $e.LastWriteTimeUtc
                })
            }
        }
    }
    return [pscustomobject]@{ Files = $files; Errors = $errors }
}

function Get-FileListFingerprint {
    <# SHA-256 over (relative path, size, modified time) of every file. Changes when anything is added, removed or edited. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Files)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in $Files) { $lines.Add(('{0}|{1}|{2}' -f $f.RelativePath, $f.Length, $f.LastWriteTimeUtc.Ticks)) }
    $lines.Sort([System.StringComparer]::Ordinal)
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in $lines) { [void]$sb.Append($l).Append("`n") }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))
        return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

# ---------------------------------------------------------------- archives

$script:StoredExtensions = @('.zip', '.7z', '.rar', '.gz', '.tgz', '.bz2', '.xz', '.jpg', '.jpeg', '.png', '.gif',
                             '.webp', '.mp3', '.mp4', '.mov', '.mkv', '.avi', '.webm', '.pdf', '.docx', '.xlsx',
                             '.pptx', '.jar', '.whl', '.nupkg', '.pack')

function New-ProjectArchive {
    <#
      Creates a zip of the given files. Files are opened with sharing allowed so files open in
      editors still back up. Returns @{ Added; Skipped (list of messages) }.
    #>
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][AllowEmptyCollection()]$Files)
    $skipped = New-Object System.Collections.Generic.List[string]
    $added = 0
    $minDate = New-Object DateTime 1980, 1, 2
    $zipStream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in $Files) {
                $src = $null
                try {
                    $src = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                } catch {
                    $skipped.Add("$($f.RelativePath): $($_.Exception.Message)"); continue
                }
                try {
                    $ext = [System.IO.Path]::GetExtension($f.RelativePath).ToLowerInvariant()
                    $level = if ($script:StoredExtensions -contains $ext) { [System.IO.Compression.CompressionLevel]::NoCompression } else { [System.IO.Compression.CompressionLevel]::Optimal }
                    $entry = $zip.CreateEntry($f.RelativePath, $level)
                    $lw = $f.LastWriteTimeUtc.ToLocalTime()
                    if ($lw -lt $minDate) { $lw = $minDate }
                    $entry.LastWriteTime = New-Object DateTimeOffset $lw
                    $dst = $entry.Open()
                    try { $src.CopyTo($dst) } finally { $dst.Dispose() }
                    $added++
                } finally { $src.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $zipStream.Dispose() }
    return [pscustomobject]@{ Added = $added; Skipped = $skipped }
}

function Expand-ProjectArchive {
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw "Destination already exists: $Destination (restore never overwrites)." }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

# ---------------------------------------------------------------- snapshot names / retention

function Get-SnapshotName {
    param([Parameter(Mandatory)][string]$ProjectName, [Parameter(Mandatory)][datetime]$Time, [string]$Label)
    $name = '{0}_{1}' -f $ProjectName, $Time.ToString($script:TimestampFormat, [Globalization.CultureInfo]::InvariantCulture)
    $l = ConvertTo-SafeLabel $Label
    if ($l) { $name += "_$l" }
    return "$name.zip"
}

function ConvertFrom-SnapshotName {
    <# Returns $null for names that aren't snapshots (those are never pruned). #>
    param([Parameter(Mandatory)][string]$Name)
    $m = [regex]::Match($Name, $script:SnapshotPattern)
    if (-not $m.Success) { return $null }
    $t = [datetime]::ParseExact($m.Groups['ts'].Value, $script:TimestampFormat, [Globalization.CultureInfo]::InvariantCulture)
    [pscustomobject]@{
        Name    = $Name
        Project = $m.Groups['project'].Value
        Time    = $t
        Label   = $m.Groups['label'].Value
    }
}

function Select-SnapshotsToPrune {
    <#
      Keeps: the newest keepLast; the newest per day for keepDailyDays; the newest per month for
      keepMonthlyMonths; every labelled snapshot whose label isn't in unprotectedLabels.
      Returns the names of everything else. Never returns the newest snapshot.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names, [Parameter(Mandatory)]$Retention, [datetime]$Now = (Get-Date))
    $snaps = @($Names | ForEach-Object { ConvertFrom-SnapshotName $_ } | Where-Object { $_ } | Sort-Object Time -Descending)
    if ($snaps.Count -eq 0) { return @() }
    $keep = @{}
    for ($i = 0; $i -lt [Math]::Min([int]$Retention.keepLast, $snaps.Count); $i++) { $keep[$snaps[$i].Name] = $true }
    $keep[$snaps[0].Name] = $true

    $dailyCutoff = $Now.Date.AddDays(-[int]$Retention.keepDailyDays)
    $seenDays = @{}
    foreach ($s in $snaps) {
        if ($s.Time -lt $dailyCutoff) { break }
        $k = $s.Time.ToString('yyyy-MM-dd')
        if (-not $seenDays.ContainsKey($k)) { $seenDays[$k] = $true; $keep[$s.Name] = $true }
    }
    $monthlyCutoff = (New-Object DateTime $Now.Year, $Now.Month, 1).AddMonths(-[int]$Retention.keepMonthlyMonths)
    $seenMonths = @{}
    foreach ($s in $snaps) {
        if ($s.Time -lt $monthlyCutoff) { break }
        $k = $s.Time.ToString('yyyy-MM')
        if (-not $seenMonths.ContainsKey($k)) { $seenMonths[$k] = $true; $keep[$s.Name] = $true }
    }
    $unprotected = @($Retention.unprotectedLabels)
    foreach ($s in $snaps) {
        if ($s.Label -and ($unprotected -notcontains $s.Label)) { $keep[$s.Name] = $true }
    }
    return @($snaps | Where-Object { -not $keep.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
}

# ---------------------------------------------------------------- state

function Read-BackupState {
    $path = Join-Path (Get-BackupDataDir) 'state.json'
    $state = @{}
    if (Test-Path -LiteralPath $path) {
        try {
            $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch { Write-BackupLog "state.json unreadable, starting fresh: $($_.Exception.Message)" 'WARN' }
    }
    return $state
}

function Save-BackupState {
    param([Parameter(Mandatory)][hashtable]$State)
    $path = Join-Path (Get-BackupDataDir) 'state.json'
    $tmp = "$path.tmp"
    ([pscustomobject]$State | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Enter-BackupLock {
    <# One backup run at a time (the daily task and a Claude hook might overlap). Returns the open lock stream. #>
    param([int]$TimeoutSeconds = 1800)
    $path = Join-Path (Get-BackupDataDir) 'backup.lock'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        try { return [System.IO.File]::Open($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
        catch {
            if ((Get-Date) -gt $deadline) { throw "Another backup has been running for over $TimeoutSeconds seconds; giving up." }
            Start-Sleep -Seconds 5
        }
    }
}

# ---------------------------------------------------------------- rclone

function Get-RcloneExe {
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "rclone was not found. Install it with:  winget install Rclone.Rclone  (then open a new PowerShell window)." }
    return $cmd.Source
}

function Invoke-Rclone {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exe = Get-RcloneExe
    # Windows PowerShell 5.1 turns native stderr into errors; don't let that abort the run.
    $ErrorActionPreference = 'Continue'
    $out = & $exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { throw "rclone $($Arguments[0]) failed (exit $code): $text" }
    return , @($out | Where-Object { $_ -is [string] })
}

function Get-RemotePath {
    param([Parameter(Mandatory)]$Config, [string]$ProjectName, [string]$FileName)
    $p = '{0}:{1}' -f $Config.remote, $Config.remoteFolder.TrimEnd('/')
    if ($ProjectName) { $p += "/$ProjectName" }
    if ($FileName) { $p += "/$FileName" }
    return $p
}

function Get-RemoteSnapshots {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$ProjectName)
    $remote = Get-RemotePath -Config $Config -ProjectName $ProjectName
    try { $lines = Invoke-Rclone @('lsf', $remote, '--files-only') }
    catch { if ("$_" -match 'directory not found') { return @() } throw }
    return @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

Export-ModuleMember -Function *
