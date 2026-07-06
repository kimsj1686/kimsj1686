## Codex 사용 현황

![Codex 사용 현황](assets/codex-activity.svg)

수동 업데이트:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-codex-activity.ps1
git add README.md assets\codex-activity.svg scripts\update-codex-activity.ps1
git commit -m "Update Codex activity"
git push
```

잔디 상단 숫자를 바꿀 때:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-codex-activity.ps1 -Lifetime "5.91B" -Peak "353M" -Streak "2d" -BestStreak "49d" -LongestTask "5h 12m"
```

공개되는 것은 집계된 사용 현황뿐입니다. 원본 Codex 로그는 로컬에만 보관합니다.
