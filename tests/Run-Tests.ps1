#Requires -Version 5.1
<#
  Self-contained tests (no Pester needed).
    .\tests\Run-Tests.ps1          # unit tests
    .\tests\Run-Tests.ps1 -EndToEnd   # also a full backup/prune/restore run against a local
                                      # folder posing as Google Drive (needs rclone installed)
#>
param([switch]$EndToEnd)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("pb-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$env:LOCALAPPDATA = Join-Path $work 'appdata'     # keep state/logs out of the real profile
Import-Module (Join-Path $repo 'lib/ProjectBackup.psm1') -Force -DisableNameChecking

$script:pass = 0; $script:fail = 0
function Check([string]$Name, [scriptblock]$Test) {
    try {
        $r = & $Test
        if ($r -eq $true) { $script:pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
        else { $script:fail++; Write-Host "  FAIL $Name (got: $r)" -ForegroundColor Red }
    } catch { $script:fail++; Write-Host "  FAIL $Name ($($_.Exception.Message))" -ForegroundColor Red }
}
function New-TestFile([string]$Path, [string]$Content = 'x') {
    $d = Split-Path $Path -Parent
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value $Content
}

try {
    Write-Host 'Exclusions'
    $ex = @('node_modules', '*.log', 'docs/generated', 'bin')
    Check 'excludes folder by name at any depth' { Test-Excluded -Name 'node_modules' -RelativePath 'web/node_modules' -Patterns $ex }
    Check 'excludes by wildcard' { Test-Excluded -Name 'debug.log' -RelativePath 'debug.log' -Patterns $ex }
    Check 'excludes by relative path' { Test-Excluded -Name 'generated' -RelativePath 'docs/generated' -Patterns $ex }
    Check 'path pattern does not match elsewhere' { -not (Test-Excluded -Name 'generated' -RelativePath 'src/generated' -Patterns $ex) }
    Check 'keeps normal files' { -not (Test-Excluded -Name 'main.py' -RelativePath 'src/main.py' -Patterns $ex) }
    Check 'case-insensitive' { Test-Excluded -Name 'Node_Modules' -RelativePath 'Node_Modules' -Patterns $ex }
    Check 'does not exclude .git' { -not (Test-Excluded -Name '.git' -RelativePath '.git' -Patterns (Get-DefaultConfig).exclude) }

    Write-Host 'File scan and fingerprint'
    $proj = Join-Path $work 'projects/MyApp'
    New-TestFile "$proj/src/main.py" 'print(1)'
    New-TestFile "$proj/.git/HEAD" 'ref: refs/heads/main'
    New-TestFile "$proj/node_modules/lib/index.js" 'junk'
    New-TestFile "$proj/app.log" 'log'
    New-TestFile "$proj/secret-data/big.bin" 'big'
    Set-Content -LiteralPath "$proj/.backupignore" -Value "# comment`nsecret-data/"
    $exc = Get-ProjectExcludes -ProjectPath $proj -BaseExcludes (Get-DefaultConfig).exclude
    $scan = Get-ProjectFiles -ProjectPath $proj -Excludes $exc
    $rels = @($scan.Files | ForEach-Object { $_.RelativePath } | Sort-Object)
    Check 'scan includes source, .git and .backupignore only' { ($rels -join ',') -eq '.backupignore,.git/HEAD,src/main.py' }
    $fp1 = Get-FileListFingerprint -Files $scan.Files
    Check 'fingerprint stable' { $fp1 -eq (Get-FileListFingerprint -Files (Get-ProjectFiles -ProjectPath $proj -Excludes $exc).Files) }
    Set-Content -LiteralPath "$proj/src/main.py" -Value 'print(2)  # longer'
    $fp2 = Get-FileListFingerprint -Files (Get-ProjectFiles -ProjectPath $proj -Excludes $exc).Files
    Check 'fingerprint changes when a file changes' { $fp1 -ne $fp2 }
    Remove-Item "$proj/src/main.py"
    $fp3 = Get-FileListFingerprint -Files (Get-ProjectFiles -ProjectPath $proj -Excludes $exc).Files
    Check 'fingerprint changes when a file is deleted' { $fp3 -ne $fp2 }
    New-TestFile "$proj/src/main.py" 'print(1)'
    Check 'empty file list fingerprint works' { (Get-FileListFingerprint -Files @()).Length -eq 64 }

    Write-Host 'Snapshot names'
    $t = Get-Date '2026-11-08 21:05:09'
    Check 'name format' { (Get-SnapshotName -ProjectName 'My_App' -Time $t -Label 'before refactor!') -eq 'My_App_2026-11-08_210509_before-refactor.zip' }
    $p = ConvertFrom-SnapshotName 'My_App_2026-11-08_210509_before-refactor.zip'
    Check 'parse project with underscore' { $p.Project -eq 'My_App' }
    Check 'parse label' { $p.Label -eq 'before-refactor' }
    Check 'parse time' { $p.Time -eq $t }
    Check 'parse unlabelled' { (ConvertFrom-SnapshotName 'x_2026-11-08_210509.zip').Label -eq '' }
    Check 'non-snapshot names ignored' { $null -eq (ConvertFrom-SnapshotName 'notes.txt') }

    Write-Host 'Retention'
    $ret = [pscustomobject]@{ keepLast = 3; keepDailyDays = 5; keepMonthlyMonths = 2; unprotectedLabels = @('pre-claude') }
    $now = Get-Date '2026-11-08 22:00:00'
    $names = @()
    # four snapshots a day for the last 10 days, plus one per month going back 6 months
    for ($d = 0; $d -lt 10; $d++) { foreach ($h in 9, 12, 15, 18) { $names += Get-SnapshotName -ProjectName 'A' -Time $now.Date.AddDays(-$d).AddHours($h) -Label 'pre-claude' } }
    for ($m = 1; $m -le 6; $m++) { $names += Get-SnapshotName -ProjectName 'A' -Time $now.Date.AddMonths(-$m).AddDays(-15) }
    $milestone = Get-SnapshotName -ProjectName 'A' -Time $now.AddYears(-2) -Label 'v1-working'
    $names += $milestone
    $names += 'README.txt'
    $prune = @(Select-SnapshotsToPrune -Names $names -Retention $ret -Now $now)
    $kept = @($names | Where-Object { $prune -notcontains $_ })
    Check 'never prunes milestone labels' { $prune -notcontains $milestone }
    Check 'never prunes non-snapshot files' { $prune -notcontains 'README.txt' }
    Check 'keeps newest 3' { @($names | Sort-Object -Descending | Select-Object -First 3 | Where-Object { $prune -contains $_ }).Count -eq 0 }
    $keptDays = @($kept | ForEach-Object { ConvertFrom-SnapshotName $_ } | Where-Object { $_ -and $_.Time -ge $now.Date.AddDays(-5) } | ForEach-Object { $_.Time.Date } | Sort-Object -Unique)
    Check 'one per day for the daily window' { $keptDays.Count -eq 6 }
    Check 'old daily extras are pruned' { @($prune | Where-Object { $_ -like 'A_2026-10-30_*' }).Count -ge 3 }
    Check 'monthly kept within window' { $kept -contains (Get-SnapshotName -ProjectName 'A' -Time $now.Date.AddMonths(-1).AddDays(-15)) }
    Check 'monthly pruned outside window' { $prune -contains (Get-SnapshotName -ProjectName 'A' -Time $now.Date.AddMonths(-6).AddDays(-15)) }
    Check 'single snapshot never pruned' { @(Select-SnapshotsToPrune -Names @('A_2020-01-01_000000.zip') -Retention $ret -Now $now).Count -eq 0 }
    Check 'empty list ok' { @(Select-SnapshotsToPrune -Names @() -Retention $ret -Now $now).Count -eq 0 }

    Write-Host 'Project discovery'
    New-TestFile (Join-Path $work 'projects/Other/readme.md')
    New-TestFile (Join-Path $work 'projects/Skipped/.nobackup')
    New-TestFile (Join-Path $work 'more/MyApp/readme.md')
    $cfg = Get-DefaultConfig
    $cfg.projectRoots = @((Join-Path $work 'projects'))
    $cfg.projects = @((Join-Path $work 'more/MyApp'))
    $found = @(Get-ConfiguredProjects -Config $cfg)
    Check '.nobackup skipped' { @($found | Where-Object { $_.Path -like '*Skipped' }).Count -eq 0 }
    Check 'duplicate folder names get parent prefix' { (@($found.Name | Sort-Object) -join ',') -eq 'more-MyApp,Other,projects-MyApp' }
    Check 'subfolder resolves to its project' { (Resolve-ProjectForPath -Path "$proj/src" -Config $cfg).Path -eq (Get-NormalizedPath $proj) }
    Check 'refuses home folder' { try { Resolve-ProjectForPath -Path $HOME -Config $cfg | Out-Null; $false } catch { $true } }

    Write-Host 'Archive round trip'
    $zip = Join-Path $work 'test.zip'
    $files = (Get-ProjectFiles -ProjectPath $proj -Excludes $exc).Files
    $r = New-ProjectArchive -ZipPath $zip -Files $files
    Check 'all files added' { $r.Added -eq $files.Count -and $r.Skipped.Count -eq 0 }
    $out = Join-Path $work 'restored'
    Expand-ProjectArchive -ZipPath $zip -Destination $out
    Check 'restored content matches' { (Get-Content "$out/src/main.py") -eq 'print(1)' -and (Test-Path "$out/.git/HEAD") }
    Check 'restore refuses to overwrite' { try { Expand-ProjectArchive -ZipPath $zip -Destination $out; $false } catch { $true } }

    if ($EndToEnd) {
        Write-Host 'End to end (local folder as the remote)'
        $remoteDir = (Join-Path $work 'fake-drive').Replace('\', '/')
        $e2eCfg = Get-Content (Join-Path $repo 'config.example.json') -Raw | ConvertFrom-Json
        $e2eCfg.projectRoots = @((Join-Path $work 'projects'))
        $e2eCfg.remote = ':local'
        $e2eCfg.remoteFolder = "$remoteDir/ProjectBackups"
        $e2eCfg.retention.keepLast = 2; $e2eCfg.retention.keepDailyDays = 0; $e2eCfg.retention.keepMonthlyMonths = 0
        $cfgPath = Join-Path $work 'config.json'
        $e2eCfg | ConvertTo-Json -Depth 10 | Set-Content $cfgPath
        $backup = Join-Path $repo 'Backup-Projects.ps1'
        $shell = (Get-Process -Id $PID).Path
        $remoteProj = "$remoteDir/ProjectBackups/MyApp"

        & $shell -NoProfile -File $backup -ConfigPath $cfgPath -Quiet; $c1 = $LASTEXITCODE
        Check 'first run backs up all projects' { $c1 -eq 0 -and @(Get-ChildItem "$remoteDir/ProjectBackups" -Directory).Count -eq 2 }
        & $shell -NoProfile -File $backup -ConfigPath $cfgPath -IfChanged -Quiet
        Check '-IfChanged skips unchanged projects' { @(Get-ChildItem $remoteProj -Filter *.zip).Count -eq 1 }
        Start-Sleep -Seconds 1
        & $shell -NoProfile -File $backup -ConfigPath $cfgPath -Project $proj -Label 'milestone' -Quiet
        Start-Sleep -Seconds 1
        for ($i = 0; $i -lt 3; $i++) {
            Add-Content "$proj/src/main.py" "# change $i"
            & $shell -NoProfile -File $backup -ConfigPath $cfgPath -Project "$proj/src" -Label 'pre-claude' -IfChanged -Quiet
            Start-Sleep -Seconds 1
        }
        $zips = @(Get-ChildItem $remoteProj -Filter *.zip | ForEach-Object Name)
        Check 'pruning keeps newest 2 plus the milestone' { $zips.Count -eq 3 -and @($zips | Where-Object { $_ -like '*_milestone.zip' }).Count -eq 1 }

        # Simulate disaster: wipe the project, then restore.
        Remove-Item $proj -Recurse -Force
        & $shell -NoProfile -File $backup -ConfigPath $cfgPath -IfChanged -Quiet
        Check 'deleted project does not remove its backups' { @(Get-ChildItem $remoteProj -Filter *.zip).Count -eq 3 }
        Push-Location $work
        try { & $shell -NoProfile -File (Join-Path $repo 'Restore-Project.ps1') -ConfigPath $cfgPath -Project MyApp -Latest -Destination $work | Out-Null } finally { Pop-Location }
        $restored = @(Get-ChildItem $work -Directory -Filter 'MyApp_restored_*')
        Check 'restore brings the latest version back' { $restored.Count -eq 1 -and ((Get-Content (Join-Path $restored[0].FullName 'src/main.py')) -join "`n") -like '*change 2*' }
    }
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor ($(if ($script:fail) { 'Red' } else { 'Green' }))
if ($script:fail) { exit 1 }
