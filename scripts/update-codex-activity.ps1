param(
    [string]$CodexSessionsPath = "$HOME\.codex\sessions",
    [string]$OutputPath = "assets\codex-activity.svg",
    [string]$HeadlineUsage = ""
)

$ErrorActionPreference = "Stop"

function Escape-Xml([string]$Value) {
    if ($null -eq $Value) {
        return ""
    }

    return [System.Security.SecurityElement]::Escape($Value)
}

function Get-SessionDate($File) {
    $fullName = $File.FullName
    $match = [regex]::Match($fullName, "\\sessions\\(?<year>\d{4})\\(?<month>\d{2})\\(?<day>\d{2})\\")
    if ($match.Success) {
        return [datetime]::new(
            [int]$match.Groups["year"].Value,
            [int]$match.Groups["month"].Value,
            [int]$match.Groups["day"].Value
        ).Date
    }

    return $File.LastWriteTime.Date
}

function Get-LatestRateLimit($Files) {
    foreach ($file in ($Files | Sort-Object LastWriteTime -Descending)) {
        try {
            $reader = [System.IO.StreamReader]::new($file.FullName)
        }
        catch {
            continue
        }

        try {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($line -notmatch '"rate_limits"') {
                    continue
                }

                try {
                    $record = $line | ConvertFrom-Json
                    $rateLimits = $record.payload.rate_limits
                    if ($null -eq $rateLimits) {
                        continue
                    }

                    $primary = $rateLimits.primary.used_percent
                    $secondary = $rateLimits.secondary.used_percent
                    if ($null -ne $primary -and $null -ne $secondary) {
                        return "Codex usage: 5h $primary% / 7d $secondary%"
                    }
                }
                catch {
                    continue
                }
            }
        }
        finally {
            $reader.Dispose()
        }
    }

    return "Codex usage: local sessions"
}

function Get-Level([int]$Count, [int]$MaxCount) {
    if ($Count -le 0) {
        return 0
    }

    if ($MaxCount -le 1) {
        return 1
    }

    $ratio = $Count / $MaxCount
    if ($ratio -le 0.25) {
        return 1
    }
    if ($ratio -le 0.50) {
        return 2
    }
    if ($ratio -le 0.75) {
        return 3
    }

    return 4
}

if (-not (Test-Path -LiteralPath $CodexSessionsPath)) {
    throw "Codex sessions path not found: $CodexSessionsPath"
}

$files = @(Get-ChildItem -LiteralPath $CodexSessionsPath -Recurse -Filter "rollout-*.jsonl" -File)
$today = (Get-Date).Date
$start = $today.AddDays(-371)
$start = $start.AddDays(-1 * [int]$start.DayOfWeek)
$end = $start.AddDays((53 * 7) - 1)

$counts = @{}
foreach ($file in $files) {
    $date = Get-SessionDate $file
    if ($date -lt $start -or $date -gt $end) {
        continue
    }

    $key = $date.ToString("yyyy-MM-dd")
    if (-not $counts.ContainsKey($key)) {
        $counts[$key] = 0
    }
    $counts[$key] += 1
}

$maxCount = 0
foreach ($value in $counts.Values) {
    if ($value -gt $maxCount) {
        $maxCount = $value
    }
}

$totalSessions = $files.Count
$activeDays = $counts.Keys.Count
$latestUsage = if ([string]::IsNullOrWhiteSpace($HeadlineUsage)) {
    Get-LatestRateLimit $files
}
else {
    $HeadlineUsage
}

$cell = 11
$gap = 3
$left = 26
$top = 72
$width = $left + (53 * ($cell + $gap)) + 24
$height = 182
$colors = @("#ebedf0", "#9be9a8", "#40c463", "#30a14e", "#216e39")

$svg = New-Object System.Collections.Generic.List[string]
$svg.Add("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`" role=`"img`" aria-labelledby=`"title desc`">")
$svg.Add("  <title id=`"title`">Codex activity</title>")
$svg.Add("  <desc id=`"desc`">Daily Codex session activity generated from local session counts.</desc>")
$svg.Add("  <style>")
$svg.Add("    .title { font: 600 16px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif; fill: #24292f; }")
$svg.Add("    .meta { font: 12px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif; fill: #57606a; }")
$svg.Add("    .day { shape-rendering: geometricPrecision; }")
$svg.Add("  </style>")
$svg.Add("  <rect width=`"100%`" height=`"100%`" rx=`"8`" fill=`"#ffffff`"/>")
$svg.Add("  <text class=`"title`" x=`"20`" y=`"28`">Codex Activity</text>")
$svg.Add("  <text class=`"meta`" x=`"20`" y=`"48`">$(Escape-Xml "$totalSessions sessions - $activeDays active days - $latestUsage")</text>")

for ($week = 0; $week -lt 53; $week++) {
    for ($day = 0; $day -lt 7; $day++) {
        $date = $start.AddDays(($week * 7) + $day)
        $key = $date.ToString("yyyy-MM-dd")
        $count = if ($counts.ContainsKey($key)) { [int]$counts[$key] } else { 0 }
        $level = Get-Level $count $maxCount
        $x = $left + ($week * ($cell + $gap))
        $y = $top + ($day * ($cell + $gap))
        $color = $colors[$level]
        $label = Escape-Xml "${key}: $count Codex sessions"
        $svg.Add("  <rect class=`"day`" x=`"$x`" y=`"$y`" width=`"$cell`" height=`"$cell`" rx=`"2`" fill=`"$color`"><title>$label</title></rect>")
    }
}

$legendY = $top + (7 * ($cell + $gap)) + 16
$svg.Add("  <text class=`"meta`" x=`"20`" y=`"$legendY`">Less</text>")
for ($i = 0; $i -lt $colors.Count; $i++) {
    $x = 56 + ($i * ($cell + $gap))
    $svg.Add("  <rect x=`"$x`" y=`"$($legendY - 10)`" width=`"$cell`" height=`"$cell`" rx=`"2`" fill=`"$($colors[$i])`"/>")
}
$svg.Add("  <text class=`"meta`" x=`"132`" y=`"$legendY`">More</text>")
$svg.Add("  <text class=`"meta`" x=`"$($width - 190)`" y=`"$legendY`">Updated $(Get-Date -Format 'yyyy-MM-dd HH:mm')</text>")
$svg.Add("</svg>")

$resolvedOutput = Join-Path (Get-Location) $OutputPath
$outputDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$svg -join [Environment]::NewLine | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8

Write-Host "Updated $OutputPath"
