## Project status file (dashboard)

This project is tracked on a personal dashboard that reads `PROJECT_STATUS.md` in the repo root.
Keep it accurate — it's how progress is seen without scrolling back through chats.

- If `PROJECT_STATUS.md` doesn't exist, create it from the format below and tell the user to add
  this repo to `projects.json` in their tracker data repo.
- Update it when a milestone is reached, a decision is made, or new next steps emerge — and always
  before you finish a session or hand back to the user.
- **Pull/fetch first** and re-read the file before editing: checkboxes may have been ticked on the
  dashboard since you last looked. Never untick a box you didn't work on.
- Keep `## Summary` current (rewrite it, don't append). 2–4 sentences.
- `## Next steps`: tick (`- [x]`) what's done, add new concrete, actionable steps. Keep it short;
  move long-finished items out once there are more than ~5 done.
- `## Key info`: facts the user would otherwise hunt for (URLs, service names, where secrets live —
  never the secrets themselves).
- `## Notes`: notes from the user, added on the dashboard or by asking you. Read them (they may
  hold instructions or context). When the user asks you to add a note, append it to the end of
  this section as `- YYYY-MM-DD: text` (extra lines as indented `  - ` sub-points). Never edit,
  reorder or delete existing notes unless the user explicitly asks you to.
- `## Decisions`: one dated line per significant decision, with the reason.
- `## Log`: append one dated line per session.
- Keep `name:` as it is unless the user asks you to change it; they may rename projects on the
  dashboard.
- Bump `updated:` to today (YYYY-MM-DD). Set `phase:` (Idea | Planning | Building | Testing | Shipped
  | Paused), `priority:` (high | medium | low) and `blocked: true` when waiting on someone/something
  (say what in the Summary).
- Commit it alongside your other changes (or on its own: `status: <short note>`).

Format:

```markdown
---
name: Project name
phase: Building
priority: high
updated: 2026-01-01
blocked: false
links: [https://github.com/owner/repo]
---
## Summary
## Next steps
- [ ] …
## Key info
## Notes
## Decisions
## Log
```
