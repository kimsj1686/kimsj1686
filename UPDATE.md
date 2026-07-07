# Profile update

GitHub contribution activity updates automatically once a day through GitHub Actions.

Codex usage is local to this PC, so refresh it from this repository:

```powershell
cd C:\Users\tjdwl\kimsj1686
.\scripts\update-profile.ps1
```

That command regenerates:

- `data/codex-activity.json`
- `data/github-contributions.json`
- `assets/activity-profile.svg`

It then commits and pushes the changed generated files.

Raw Codex session logs are never committed. Only daily totals, total token counts, streak counts, and tool-call counts are stored.
