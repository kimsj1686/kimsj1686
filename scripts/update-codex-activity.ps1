param(
    [string]$CodexSessionsPath = "$HOME\.codex\sessions",
    [string]$StateDbPath = "$HOME\.codex\state_5.sqlite",
    [string]$OutputPath = "assets\codex-activity.svg",
    [string]$Lifetime = "",
    [string]$Peak = "",
    [string]$Streak = "",
    [string]$BestStreak = "",
    [string]$LongestTask = ""
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

function Get-Level([Int64]$Count, [Int64]$MaxCount) {
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

function Format-CompactNumber([Int64]$Value) {
    if ($Value -ge 1000000000) {
        return ("{0:N2}B" -f ($Value / 1000000000.0)).TrimEnd("0").TrimEnd(".")
    }
    if ($Value -ge 1000000) {
        return ("{0:N1}M" -f ($Value / 1000000.0)).TrimEnd("0").TrimEnd(".")
    }
    if ($Value -ge 1000) {
        return ("{0:N1}K" -f ($Value / 1000.0)).TrimEnd("0").TrimEnd(".")
    }

    return "$Value"
}

function Format-Duration([Int64]$Seconds) {
    if ($Seconds -le 0) {
        return "0m"
    }

    $span = [TimeSpan]::FromSeconds($Seconds)
    $hours = [int][math]::Floor($span.TotalHours)
    if ($hours -gt 0) {
        return "${hours}h $($span.Minutes)m"
    }

    return "$($span.Minutes)m"
}

function Get-ActualTokenUsage($StateDbPath, [datetime]$Start, [datetime]$End) {
    if (-not (Test-Path -LiteralPath $StateDbPath)) {
        return $null
    }

    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($null -eq $sqlite) {
        return $null
    }

    try {
        $dailySql = @"
select date(created_at,'unixepoch','localtime') as d,
       coalesce(sum(tokens_used), 0) as tokens,
       count(*) as threads
from threads
where tokens_used > 0
group by d
order by d;
"@
        $dailyRows = @(sqlite3 -separator "|" $StateDbPath $dailySql)
        $summary = (sqlite3 -separator "|" $StateDbPath "select coalesce(sum(tokens_used),0), coalesce(max(tokens_used),0), count(*) from threads where tokens_used > 0;")
        $longestSeconds = [Int64](sqlite3 $StateDbPath "select coalesce(max(updated_at - created_at),0) from threads where updated_at >= created_at;")
    }
    catch {
        return $null
    }

    $counts = @{}
    $threadCounts = @{}
    $activeDates = New-Object System.Collections.Generic.List[datetime]
    $maxDayTokens = [Int64]0

    foreach ($row in $dailyRows) {
        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }

        $parts = $row -split "\|"
        if ($parts.Count -lt 3) {
            continue
        }

        $date = [datetime]::ParseExact($parts[0], "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
        $tokens = [Int64]$parts[1]
        $threads = [int]$parts[2]
        if ($date -lt $Start -or $date -gt $End) {
            continue
        }

        $key = $date.ToString("yyyy-MM-dd")
        $counts[$key] = $tokens
        $threadCounts[$key] = $threads
        $activeDates.Add($date.Date)
        if ($tokens -gt $maxDayTokens) {
            $maxDayTokens = $tokens
        }
    }

    $summaryParts = $summary -split "\|"
    $totalTokens = if ($summaryParts.Count -gt 0) { [Int64]$summaryParts[0] } else { [Int64]0 }
    $maxThreadTokens = if ($summaryParts.Count -gt 1) { [Int64]$summaryParts[1] } else { [Int64]0 }
    $totalThreads = if ($summaryParts.Count -gt 2) { [int]$summaryParts[2] } else { 0 }

    $activeSet = @{}
    foreach ($date in $activeDates) {
        $activeSet[$date.ToString("yyyy-MM-dd")] = $true
    }

    $currentStreak = 0
    if ($activeDates.Count -gt 0) {
        $cursor = ($activeDates | Sort-Object -Descending | Select-Object -First 1).Date
        while ($activeSet.ContainsKey($cursor.ToString("yyyy-MM-dd"))) {
            $currentStreak += 1
            $cursor = $cursor.AddDays(-1)
        }
    }

    $bestStreak = 0
    $running = 0
    $previous = $null
    foreach ($date in ($activeDates | Sort-Object -Unique)) {
        if ($null -ne $previous -and $date -eq $previous.AddDays(1)) {
            $running += 1
        }
        else {
            $running = 1
        }
        if ($running -gt $bestStreak) {
            $bestStreak = $running
        }
        $previous = $date
    }

    return [pscustomobject]@{
        Counts = $counts
        ThreadCounts = $threadCounts
        TotalTokens = $totalTokens
        TotalThreads = $totalThreads
        ActiveDays = $activeSet.Keys.Count
        MaxDayTokens = $maxDayTokens
        MaxThreadTokens = $maxThreadTokens
        CurrentStreak = $currentStreak
        BestStreak = $bestStreak
        LongestSeconds = $longestSeconds
        Source = "state_5.sqlite threads.tokens_used"
    }
}

if (-not (Test-Path -LiteralPath $CodexSessionsPath)) {
    throw "Codex sessions path not found: $CodexSessionsPath"
}

$files = @(Get-ChildItem -LiteralPath $CodexSessionsPath -Recurse -Filter "rollout-*.jsonl" -File)
$today = (Get-Date).Date
$end = $today.AddDays(6 - [int]$today.DayOfWeek)
$start = $end.AddDays(-370)

$usage = Get-ActualTokenUsage $StateDbPath $start $end
$counts = @{}
$threadCounts = @{}
$totalThreads = 0
$activeDays = 0
$lifetimeLabel = $Lifetime
$peakLabel = $Peak
$streakLabel = $Streak
$bestStreakLabel = $BestStreak
$longestTaskLabel = $LongestTask
$activityUnit = "tokens"

if ($null -ne $usage -and $usage.TotalTokens -gt 0) {
    $counts = $usage.Counts
    $threadCounts = $usage.ThreadCounts
    $totalThreads = $usage.TotalThreads
    $activeDays = $usage.ActiveDays
    if ([string]::IsNullOrWhiteSpace($lifetimeLabel)) { $lifetimeLabel = Format-CompactNumber $usage.TotalTokens }
    if ([string]::IsNullOrWhiteSpace($peakLabel)) { $peakLabel = Format-CompactNumber $usage.MaxDayTokens }
    if ([string]::IsNullOrWhiteSpace($streakLabel)) { $streakLabel = "$($usage.CurrentStreak)d" }
    if ([string]::IsNullOrWhiteSpace($bestStreakLabel)) { $bestStreakLabel = "$($usage.BestStreak)d" }
    if ([string]::IsNullOrWhiteSpace($longestTaskLabel)) { $longestTaskLabel = Format-Duration $usage.LongestSeconds }
}
else {
    $activityUnit = "sessions"
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

    $totalThreads = $files.Count
    $activeDays = $counts.Keys.Count
    if ([string]::IsNullOrWhiteSpace($lifetimeLabel)) { $lifetimeLabel = "$totalThreads" }
    if ([string]::IsNullOrWhiteSpace($peakLabel)) { $peakLabel = "$(($counts.Values | Measure-Object -Maximum).Maximum)" }
    if ([string]::IsNullOrWhiteSpace($streakLabel)) { $streakLabel = "n/a" }
    if ([string]::IsNullOrWhiteSpace($bestStreakLabel)) { $bestStreakLabel = "n/a" }
    if ([string]::IsNullOrWhiteSpace($longestTaskLabel)) { $longestTaskLabel = "n/a" }
}

$maxCount = [Int64]0
foreach ($value in $counts.Values) {
    if ($value -gt $maxCount) {
        $maxCount = $value
    }
}

$cell = 9
$gap = 3
$left = 205
$top = 256
$width = 1000
$height = 382
$inactive = "#1a2230"
$colors = @("#0e1117", "#17345f", "#225ea8", "#3b82f6", "#8bbcff")

$svg = New-Object System.Collections.Generic.List[string]
$svg.Add("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`" role=`"img`" aria-labelledby=`"title desc`">")
$svg.Add("  <title id=`"title`">Codex profile activity</title>")
$svg.Add("  <desc id=`"desc`">Codex-style profile activity card generated from local token usage.</desc>")
$svg.Add("  <defs>")
$svg.Add("    <linearGradient id=`"avatar`" x1=`"0`" y1=`"0`" x2=`"1`" y2=`"1`">")
$svg.Add("      <stop offset=`"0%`" stop-color=`"#60a5fa`"/>")
$svg.Add("      <stop offset=`"100%`" stop-color=`"#a78bfa`"/>")
$svg.Add("    </linearGradient>")
$svg.Add("  </defs>")
$svg.Add("  <style>")
$svg.Add("    .ui { font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif; }")
$svg.Add("    .mono { font-family: ui-monospace, SFMono-Regular, Consolas, Liberation Mono, Menlo, monospace; }")
$svg.Add("    .title { font: 600 18px Inter, ui-sans-serif, system-ui, sans-serif; fill: #f8fafc; }")
$svg.Add("    .small { font: 500 11px Inter, ui-sans-serif, system-ui, sans-serif; fill: #778196; }")
$svg.Add("    .metric { font: 700 15px Inter, ui-sans-serif, system-ui, sans-serif; fill: #e8edf7; }")
$svg.Add("    .label { font: 600 11px Inter, ui-sans-serif, system-ui, sans-serif; fill: #6f7a8e; }")
$svg.Add("    .tab { font: 600 11px Inter, ui-sans-serif, system-ui, sans-serif; fill: #6f7a8e; }")
$svg.Add("    .activeTab { fill: #dbeafe; }")
$svg.Add("    .month { font: 500 10px Inter, ui-sans-serif, system-ui, sans-serif; fill: #586274; }")
$svg.Add("    .day { shape-rendering: geometricPrecision; }")
$svg.Add("  </style>")
$svg.Add("  <rect width=`"100%`" height=`"100%`" fill=`"#0b0d0f`"/>")
$svg.Add("  <text class=`"small ui`" x=`"28`" y=`"31`">Profile</text>")
$svg.Add("  <text class=`"small ui`" x=`"852`" y=`"31`">Private</text>")
$svg.Add("  <text class=`"small ui`" x=`"914`" y=`"31`">Edit</text>")
$svg.Add("  <circle cx=`"500`" cy=`"83`" r=`"25`" fill=`"url(#avatar)`"/>")
$svg.Add("  <text class=`"title ui`" x=`"500`" y=`"131`" text-anchor=`"middle`">kimsj1686</text>")
$svg.Add("  <text class=`"small ui`" x=`"500`" y=`"151`" text-anchor=`"middle`">@kimsj1686 - Codex</text>")

$metricY = 187
$labelY = 204
$metricXs = @(294, 397, 500, 603, 706)
$metricValues = @($lifetimeLabel, $peakLabel, $longestTaskLabel, $streakLabel, $bestStreakLabel)
$metricLabels = @("Lifetime tokens", "Peak tokens", "Longest task", "Current streak", "Longest streak")
for ($i = 0; $i -lt $metricXs.Count; $i++) {
    if ($i -gt 0) {
        $lineX = $metricXs[$i] - 52
        $svg.Add("  <line x1=`"$lineX`" y1=`"172`" x2=`"$lineX`" y2=`"207`" stroke=`"#151c28`" stroke-width=`"1`"/>")
    }
    $svg.Add("  <text class=`"metric ui`" x=`"$($metricXs[$i])`" y=`"$metricY`" text-anchor=`"middle`">$(Escape-Xml $metricValues[$i])</text>")
    $svg.Add("  <text class=`"label ui`" x=`"$($metricXs[$i])`" y=`"$labelY`" text-anchor=`"middle`">$(Escape-Xml $metricLabels[$i])</text>")
}

$svg.Add("  <text class=`"label ui`" x=`"205`" y=`"245`" fill=`"#dbeafe`">Token activity</text>")
$svg.Add("  <text class=`"tab activeTab ui`" x=`"690`" y=`"245`">Daily</text>")
$svg.Add("  <text class=`"tab ui`" x=`"737`" y=`"245`">Weekly</text>")
$svg.Add("  <text class=`"tab ui`" x=`"793`" y=`"245`">Cumulative</text>")

$monthCursor = [datetime]::new($start.Year, $start.Month, 1).AddMonths(2)
$lastMonth = [datetime]::new($today.Year, $today.Month, 1).AddMonths(-1)
while ($monthCursor -le $lastMonth) {
    $week = [math]::Floor(($monthCursor.Date - $start).TotalDays / 7)
    if ($week -ge 0 -and $week -lt 53) {
        $x = $left + ($week * ($cell + $gap))
        $monthName = $monthCursor.ToString("MMM", [System.Globalization.CultureInfo]::InvariantCulture)
        $svg.Add("  <text class=`"month ui`" x=`"$x`" y=`"360`">$monthName</text>")
    }
    $monthCursor = $monthCursor.AddMonths(1)
}

for ($week = 0; $week -lt 53; $week++) {
    for ($day = 0; $day -lt 7; $day++) {
        $date = $start.AddDays(($week * 7) + $day)
        $key = $date.ToString("yyyy-MM-dd")
        $count = if ($counts.ContainsKey($key)) { [int]$counts[$key] } else { 0 }
        $level = Get-Level $count $maxCount
        $x = $left + ($week * ($cell + $gap))
        $y = $top + ($day * ($cell + $gap))
        $color = $colors[$level]
        $displayCount = if ($activityUnit -eq "tokens") { Format-CompactNumber $count } else { "$count" }
        $threadCount = if ($threadCounts.ContainsKey($key)) { [int]$threadCounts[$key] } else { 0 }
        $label = if ($activityUnit -eq "tokens") {
            Escape-Xml "${key}: $displayCount tokens across $threadCount threads"
        }
        else {
            Escape-Xml "${key}: $count Codex sessions"
        }
        if ($level -eq 0) {
            $svg.Add("  <rect class=`"day`" x=`"$x`" y=`"$y`" width=`"$cell`" height=`"$cell`" rx=`"2`" fill=`"$inactive`" opacity=`"0.72`"><title>$label</title></rect>")
        }
        else {
            $svg.Add("  <rect class=`"day`" x=`"$x`" y=`"$y`" width=`"$cell`" height=`"$cell`" rx=`"2`" fill=`"$color`"><title>$label</title></rect>")
        }
    }
}

$svg.Add("</svg>")

$resolvedOutput = Join-Path (Get-Location) $OutputPath
$outputDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$svg -join [Environment]::NewLine | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8

Write-Host "Updated $OutputPath"
