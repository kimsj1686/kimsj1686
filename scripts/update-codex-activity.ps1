param(
    [string]$CodexSessionsPath = "$HOME\.codex\sessions",
    [string]$OutputPath = "assets\codex-activity.svg",
    [string]$Lifetime = "5.91B",
    [string]$Peak = "353M",
    [string]$Streak = "2d",
    [string]$BestStreak = "49d",
    [string]$LongestTask = "5h 12m"
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

$cell = 9
$gap = 3
$left = 205
$top = 256
$width = 1000
$height = 390
$inactive = "#1a2230"
$colors = @("#0e1117", "#17345f", "#225ea8", "#3b82f6", "#8bbcff")

$svg = New-Object System.Collections.Generic.List[string]
$svg.Add("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`" role=`"img`" aria-labelledby=`"title desc`">")
$svg.Add("  <title id=`"title`">Codex profile activity</title>")
$svg.Add("  <desc id=`"desc`">Codex-style profile activity card generated from local session counts.</desc>")
$svg.Add("  <defs>")
$svg.Add("    <linearGradient id=`"shell`" x1=`"0`" y1=`"0`" x2=`"1`" y2=`"1`">")
$svg.Add("      <stop offset=`"0%`" stop-color=`"#3b22d8`"/>")
$svg.Add("      <stop offset=`"45%`" stop-color=`"#1d4ed8`"/>")
$svg.Add("      <stop offset=`"100%`" stop-color=`"#7c3aed`"/>")
$svg.Add("    </linearGradient>")
$svg.Add("    <linearGradient id=`"avatar`" x1=`"0`" y1=`"0`" x2=`"1`" y2=`"1`">")
$svg.Add("      <stop offset=`"0%`" stop-color=`"#60a5fa`"/>")
$svg.Add("      <stop offset=`"100%`" stop-color=`"#a78bfa`"/>")
$svg.Add("    </linearGradient>")
$svg.Add("    <filter id=`"softShadow`" x=`"-20%`" y=`"-20%`" width=`"140%`" height=`"140%`">")
$svg.Add("      <feDropShadow dx=`"0`" dy=`"16`" stdDeviation=`"18`" flood-color=`"#000000`" flood-opacity=`"0.35`"/>")
$svg.Add("    </filter>")
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
$svg.Add("  <rect width=`"100%`" height=`"100%`" rx=`"18`" fill=`"url(#shell)`"/>")
$svg.Add("  <rect x=`"54`" y=`"34`" width=`"892`" height=`"322`" rx=`"12`" fill=`"#0b0d0f`" stroke=`"#243044`" stroke-width=`"1`" filter=`"url(#softShadow)`"/>")
$svg.Add("  <text class=`"small ui`" x=`"78`" y=`"61`">Profile</text>")
$svg.Add("  <text class=`"small ui`" x=`"834`" y=`"61`">Private</text>")
$svg.Add("  <text class=`"small ui`" x=`"896`" y=`"61`">Edit</text>")
$svg.Add("  <circle cx=`"500`" cy=`"83`" r=`"25`" fill=`"url(#avatar)`"/>")
$svg.Add("  <text class=`"title ui`" x=`"500`" y=`"131`" text-anchor=`"middle`">kimsj1686</text>")
$svg.Add("  <text class=`"small ui`" x=`"500`" y=`"151`" text-anchor=`"middle`">@kimsj1686 - Codex</text>")

$metricY = 187
$labelY = 204
$metricXs = @(294, 397, 500, 603, 706)
$metricValues = @($Lifetime, $Peak, $LongestTask, $Streak, $BestStreak)
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
        $label = Escape-Xml "${key}: $count Codex sessions"
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
