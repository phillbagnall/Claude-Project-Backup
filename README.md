# Claude Project Backup

Versioned backups of your Windows project folders to Google Drive. They protect you from
accidental deletions, whether by an AI coding agent, a bad `git` command or a slip of the mouse.

- **Snapshots, not a mirror.** Each backup is a new timestamped zip in Drive. Deleting or wiping a
  project on your PC never deletes its backups. (A synced folder or `rclone sync` *would* copy the
  deletion to Drive. These scripts never do that.)
- **Includes `.git`**, so unpushed commits, local branches and stashes are covered for GitHub
  projects too.
- **Leaves out rebuildable folders** (`node_modules`, `.venv`, `bin`, `obj`, `dist`, `build`, ...),
  which keeps the zips small.
- **Three triggers:** the `backup` command whenever you reach a milestone, automatically when a
  Claude Code session starts, and once a day for anything that changed.
- **Restores into a new folder** and never overwrites your live project.
- **Limited Drive access:** rclone uses the `drive.file` scope, so it can only see files it
  created. The rest of your Drive is off-limits.

## Setup (one time, about 10 minutes)

1. **Install rclone:** open PowerShell and run `winget install Rclone.Rclone`, then open a *new*
   PowerShell window.
2. **Get this repo onto your PC**, for example:
   ```powershell
   cd $HOME
   git clone https://github.com/phillbagnall/Claude-Project-Backup.git
   cd Claude-Project-Backup
   ```
   Put it outside your projects folder, so it doesn't back itself up.
3. **Run the installer:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install.ps1
   ```
   It asks before each step. It will:
   - create the `gdrive` rclone remote (your browser opens to sign in to Google)
   - ask which folder(s) contain your projects (e.g. `C:\Users\Phill\Projects`) and write
     `config.json`
   - register the daily backup task in Task Scheduler (21:00; if the PC is off then, it runs
     at your next login)
   - add the `backup` and `restore-backup` commands to your PowerShell profile
   - add the Claude Code hook to `%USERPROFILE%\.claude\settings.json` (it saves a copy of your
     existing file first)
4. **Open a new PowerShell window** and check everything:
   ```powershell
   backup -All -DryRun        # which projects, how many files, how big; uploads nothing
   backup -All -Label first   # the first full backup
   restore-backup             # list what's in Drive
   ```
   Your backups are in Google Drive under **ProjectBackups/<project name>/**.

## Everyday use

| You want to... | Run |
|---|---|
| Snapshot the project you're in, at a milestone | `backup -Label "login-working"` |
| Snapshot it with no label | `backup` |
| Back up every project now | `backup -All` (add `-IfChanged` to skip unchanged ones) |
| See when each project was last backed up | `backup -Status` |
| See what would happen, without uploading | `backup -All -DryRun` |

The hook and the daily task run on their own. Logs are kept in
`%LOCALAPPDATA%\ProjectBackup\logs\`.

**Tip:** run `backup -Label before-<thing>` before asking Claude for a big or risky change
(a refactor, a migration, a dependency upgrade).

## Restoring

```powershell
restore-backup                                 # list projects that have backups
restore-backup -Project MyApp                  # list MyApp's snapshots, newest first
restore-backup -Project MyApp -Latest          # restore the newest into .\MyApp_restored_<time>
restore-backup -Project MyApp -Snapshot MyApp_2026-11-08_210000_before-refactor.zip -Destination D:\Restores
```

Restores always go into a new folder. Compare it with your project, then copy back what you
need. You can also download any zip straight from Google Drive in the browser.

## What is kept (retention)

For each project, after each successful backup:

- the **20 most recent** snapshots
- the newest snapshot of each day, for **30 days**
- the newest snapshot of each month, for **12 months**
- **every snapshot with a label you chose** (e.g. `first`, `v1-working`), forever

The automatic labels `pre-claude` and `daily` don't count as your labels, so those snapshots
are pruned normally. Pruned zips go to the Google Drive **trash**, where they can still be
recovered for 30 days. Unchanged projects are skipped, so idle projects use no extra space.
Change these numbers under `retention` in `config.json`.

## Configuration (`config.json`)

| Setting | Meaning |
|---|---|
| `projectRoots` | Folders whose subfolders are each a project |
| `projects` | Extra individual project folders that live somewhere else |
| `exclude` | Names or wildcards to skip at any depth (`node_modules`, `*.log`), or paths from the project root (`docs/generated`) |
| `maxProjectSizeMB` | A project bigger than this is skipped with an error, so a stray dataset doesn't fill your Drive (default 10 GB) |
| `remote` / `remoteFolder` | The rclone remote name and the Drive folder |
| `dailyTime` | When the daily task runs (to change it, run `Install.ps1 -Uninstall`, then `Install.ps1`) |

Per-project settings:

- **`.backupignore`** in a project: extra exclusions for that project, one pattern per line
  (`#` starts a comment).
- **`.nobackup`** (an empty file) in a project: skip that project entirely.

If two projects have the same folder name, the parent folder is added to the name in Drive
(e.g. `work-api` and `personal-api`).

## Good to know

- **Secrets:** files like `.env` are included, so you can get a working project back. Your
  Drive is private, but you can add `.env` to `exclude` if you'd rather not upload them.
- **Open files** (e.g. files open in your editor) are backed up as they are. A file that another
  program has locked exclusively is skipped, and a warning is written to the log.
- **Links:** symlinks and junctions are not followed.
- **Claude Code's `/rewind`** only undoes Claude's own file edits, not deletions made with
  shell commands. These backups cover everything.
- **Uninstall:** `.\Install.ps1 -Uninstall` removes the scheduled task, the profile commands and
  the hook. Your backups in Drive and your `config.json` are left alone.

## Development

```powershell
.\tests\Run-Tests.ps1              # unit tests
.\tests\Run-Tests.ps1 -EndToEnd    # plus a full backup → prune → wipe → restore run against a local folder (needs rclone)
```
