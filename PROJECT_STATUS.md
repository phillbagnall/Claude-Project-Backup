---
name: Claude Project Backup
phase: Testing
priority: high
updated: 2026-11-08
blocked: false
links: [https://github.com/phillbagnall/Claude-Project-Backup]
---
## Summary
A PowerShell toolkit that backs up all my projects (GitHub and PC-only) to Google Drive. Each backup is a new timestamped zip, so a deleted project can never wipe its backups. It runs at milestones, before every Claude Code session and daily. It's built and tested in a cloud session (39 tests passing) but hasn't been run on the Windows PC yet.

## Next steps
- [ ] Install rclone: `winget install Rclone.Rclone`, then open a NEW PowerShell window
- [ ] Clone this repo outside the projects folder: `cd $HOME` then `git clone https://github.com/phillbagnall/Claude-Project-Backup.git` then `cd Claude-Project-Backup`
- [ ] Run the installer: `powershell -ExecutionPolicy Bypass -File .\Install.ps1`. It asks before each step: sign in to Google in the browser, enter the projects folder(s), daily task, `backup` command, Claude hook
- [ ] In a new PowerShell window, run `backup -All -DryRun` and check the project list and sizes. Add any big folders to `exclude` in config.json or to a project's `.backupignore`
- [ ] First full backup: `backup -All -Label first`, then check for **ProjectBackups/** in Google Drive
- [ ] Test a restore: `restore-backup -Project <name> -Latest`, then open the restored folder
- [ ] Start a Claude Code session in a project, then check `backup -Status` shows a new `pre-claude` snapshot
- [ ] The day after: check the daily backup ran (`backup -Status`, or the log in `%LOCALAPPDATA%\ProjectBackup\logs`)
- [ ] Optional: decide whether to exclude `.env` files (add `.env` to `exclude` in config.json)
- [ ] Optional: rename the branch `claude/project-backup-google-drive-761nb7` to `main` (GitHub → Settings → Branches)

## Key info
- Milestone snapshot of the current project: `backup -Label "what-works-now"` (labelled snapshots are kept forever)
- Other commands: `backup` (current project), `backup -All`, `backup -Status`, `backup -All -DryRun`
- Restore: `restore-backup` (list projects), `restore-backup -Project X` (list snapshots), `restore-backup -Project X -Latest`. It always restores into a new `X_restored_<time>` folder
- Backups in Google Drive: `ProjectBackups/<project>/<project>_<date>_<time>[_label].zip`
- Settings: `config.json` in the repo folder (project folders, exclusions, retention, size limit 10 GB)
- Per project: `.backupignore` (extra exclusions), `.nobackup` (skip the project)
- Logs and state: `%LOCALAPPDATA%\ProjectBackup\`
- Retention: last 20, one a day for 30 days, one a month for 12 months, labelled forever. Pruned zips go to the Drive trash (30 days)
- Uninstall: `.\Install.ps1 -Uninstall` (backups and config.json are kept)
- Full guide: README.md

## Notes

## Decisions
- 2026-11-08: Add-only snapshots, not a mirror, so a local deletion can never spread to Drive
- 2026-11-08: rclone with the `drive.file` scope, so it can't see or touch anything else in Drive
- 2026-11-08: Windows only, in PowerShell 5.1 (built in), so nothing else needs installing besides rclone
- 2026-11-08: Include `.git` so unpushed commits and branches are covered; skip rebuildable folders to keep zips small
- 2026-11-08: Zips made with .NET (not tar.exe): it handles unusual file names and files open in the editor
- 2026-11-08: Snapshots with my own labels are never pruned; automatic `pre-claude`/`daily` ones are

## Log
- 2026-11-08: Planned, built and tested (39 unit and end-to-end tests) in a cloud session; added to the project dashboard
