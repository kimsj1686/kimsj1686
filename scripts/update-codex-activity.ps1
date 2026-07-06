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

$cell = 11
$gap = 15
$left = 60
$top = 185
$width = 1416
$height = 358
$inactive = "#5f6368"
$colors = @("#0b0d0e", "#f3d98f", "#f7df9b", "#ffe9ae", "#fff0c2")

$svg = New-Object System.Collections.Generic.List[string]
$svg.Add("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`" role=`"img`" aria-labelledby=`"title desc`">")
$svg.Add("  <title id=`"title`">Codex usage daily</title>")
$svg.Add("  <desc id=`"desc`">Terminal-style daily Codex activity for the last 12 months, generated from local session counts.</desc>")
$svg.Add("  <style>")
$svg.Add("    .term { font-family: ui-monospace,SFMono-Regular,Consolas,Liberation Mono,Menlo,monospace; }")
$svg.Add("    .cmd { font: 700 20px ui-monospace,SFMono-Regular,Consolas,Liberation Mono,Menlo,monospace; fill: #b026d9; }")
$svg.Add("    .label { font: 700 22px ui-monospace,SFMono-Regular,Consolas,Liberation Mono,Menlo,monospace; fill: #f4f4f4; }")
$svg.Add("    .muted { fill: #a3a8bf; }")
$svg.Add("    .accent { fill: #ffb17a; }")
$svg.Add("    .month, .dow { font: 20px ui-monospace,SFMono-Regular,Consolas,Liberation Mono,Menlo,monospace; fill: #a3a8bf; }")
$svg.Add("    .day { shape-rendering: crispEdges; }")
$svg.Add("  </style>")
$svg.Add("  <rect width=`"100%`" height=`"100%`" fill=`"#0b0d0e`"/>")
$svg.Add("  <text class=`"cmd`" x=`"8`" y=`"43`">/usage daily</text>")
$svg.Add("  <text class=`"label`" x=`"21`" y=`"93`">Token activity <tspan class=`"muted`" font-weight=`"400`" dx=`"26`">last 12 months</tspan></text>")
$svg.Add("  <text class=`"label muted`" x=`"21`" y=`"119`" font-weight=`"400`">Lifetime <tspan class=`"accent`" font-weight=`"700`">$(Escape-Xml $Lifetime)</tspan> - Peak <tspan class=`"accent`" font-weight=`"700`">$(Escape-Xml $Peak)</tspan> - Streak <tspan class=`"accent`" font-weight=`"700`">$(Escape-Xml $Streak) (best $(Escape-Xml $BestStreak))</tspan> - Longest task <tspan class=`"accent`" font-weight=`"700`">$(Escape-Xml $LongestTask)</tspan></text>")

$monthCursor = [datetime]::new($start.Year, $start.Month, 1).AddMonths(2)
$lastMonth = [datetime]::new($today.Year, $today.Month, 1).AddMonths(-1)
while ($monthCursor -le $lastMonth) {
    $week = [math]::Floor(($monthCursor.Date - $start).TotalDays / 7)
    if ($week -ge 0 -and $week -lt 53) {
        $x = $left + ($week * ($cell + $gap))
        $monthName = $monthCursor.ToString("MMM", [System.Globalization.CultureInfo]::InvariantCulture)
        $svg.Add("  <text class=`"month`" x=`"$x`" y=`"168`">$monthName</text>")
    }
    $monthCursor = $monthCursor.AddMonths(1)
}

$days = @("Su", "Mo", "Tu", "We", "Th", "Fr", "Sa")
for ($day = 0; $day -lt 7; $day++) {
    $y = $top + ($day * ($cell + $gap)) + 8
    $svg.Add("  <text class=`"dow`" x=`"21`" y=`"$y`">$($days[$day])</text>")
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
            $svg.Add("  <rect class=`"day`" x=`"$x`" y=`"$y`" width=`"$cell`" height=`"$cell`" fill=`"none`" stroke=`"$inactive`" stroke-width=`"1.5`"><title>$label</title></rect>")
        }
        else {
            $svg.Add("  <rect class=`"day`" x=`"$x`" y=`"$y`" width=`"$cell`" height=`"$cell`" fill=`"$color`"><title>$label</title></rect>")
        }
    }
}

$svg.Add("</svg>")

$resolvedOutput = Join-Path (Get-Location) $OutputPath
$outputDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$svg -join [Environment]::NewLine | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8

Write-Host "Updated $OutputPath"
