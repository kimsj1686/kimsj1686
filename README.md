## Codex Activity

![Codex Activity](assets/codex-activity.svg)

Manual update:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-codex-activity.ps1
git add README.md assets\codex-activity.svg scripts\update-codex-activity.ps1
git commit -m "Update Codex activity"
git push
```

Only aggregated activity is published. Raw Codex logs stay local.
