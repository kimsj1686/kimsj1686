param(
  [string]$Message = "chore: refresh profile activity"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$env:GITHUB_LOGIN = if ($env:GITHUB_LOGIN) { $env:GITHUB_LOGIN } else { "kimsj1686" }

npm run update:profile

git add assets/activity-profile.svg data/codex-activity.json

$changes = git diff --cached --name-only
if (-not $changes) {
  Write-Host "No profile activity changes to commit."
  exit 0
}

git commit -m $Message
git push
