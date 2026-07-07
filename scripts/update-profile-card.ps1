param(
  [string]$Source = "$env:USERPROFILE\Downloads\codex-profile-card.png"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$target = Join-Path $repoRoot "assets\codex-profile-card.png"

if (-not (Test-Path -LiteralPath $Source)) {
  throw "Codex profile card not found: $Source"
}

Copy-Item -LiteralPath $Source -Destination $target -Force

Push-Location $repoRoot
try {
  git add README.md assets/codex-profile-card.png

  $changes = git diff --cached --name-only
  if (-not $changes) {
    Write-Host "No profile card changes to publish."
    exit 0
  }

  git commit -m "chore: update Codex profile card"
  git push
}
finally {
  Pop-Location
}
