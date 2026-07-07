import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const assetsDir = path.join(root, "assets");
const dataDir = path.join(root, "data");
const codexDataPath = path.join(dataDir, "codex-activity.json");
const githubDataPath = path.join(dataDir, "github-contributions.json");
const svgPath = path.join(assetsDir, "activity-profile.svg");

const login = process.env.GITHUB_LOGIN || "kimsj1686";
const displayName = process.env.PROFILE_NAME || "sungjin";
const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");

fs.mkdirSync(assetsDir, { recursive: true });
fs.mkdirSync(dataDir, { recursive: true });

const today = startOfDay(new Date());
const from = addDays(today, -364);
const codexActivity = loadCodexActivity();
const githubActivity = await loadGithubActivity();

fs.writeFileSync(svgPath, renderSvg(codexActivity, githubActivity), "utf8");

function loadCodexActivity() {
  const sessionsDir = path.join(codexHome, "sessions");
  if (fs.existsSync(sessionsDir)) {
    const activity = collectCodexActivity(sessionsDir);
    fs.writeFileSync(codexDataPath, JSON.stringify(activity, null, 2) + "\n", "utf8");
    return activity;
  }

  if (fs.existsSync(codexDataPath)) {
    return JSON.parse(fs.readFileSync(codexDataPath, "utf8"));
  }

  return {
    generatedAt: new Date().toISOString(),
    days: [],
    totals: {
      sessions: 0,
      totalTokens: 0,
      maxSessionTokens: 0,
      longestSessionMinutes: 0,
      currentStreak: 0,
      longestStreak: 0,
      toolCalls: 0
    },
    topTools: []
  };
}

async function loadGithubActivity() {
  const token = process.env.GITHUB_TOKEN;
  if (token) {
    try {
      const activity = await fetchGithubContributions(token);
      fs.writeFileSync(githubDataPath, JSON.stringify(activity, null, 2) + "\n", "utf8");
      return activity;
    } catch (error) {
      console.warn(`GitHub contribution fetch failed: ${error.message}`);
    }
  }

  if (fs.existsSync(githubDataPath)) {
    return JSON.parse(fs.readFileSync(githubDataPath, "utf8"));
  }

  return {
    generatedAt: new Date().toISOString(),
    totalContributions: 0,
    days: dateRange(from, today).map((date) => ({ date: toDateKey(date), count: 0 }))
  };
}

function collectCodexActivity(sessionsDir) {
  const files = listJsonlFiles(sessionsDir);
  const dayTokens = new Map();
  const sessionDays = new Set();
  const toolCounts = new Map();
  let totalTokens = 0;
  let maxSessionTokens = 0;
  let longestSessionMinutes = 0;
  let toolCalls = 0;

  for (const file of files) {
    const lines = fs.readFileSync(file, "utf8").split(/\r?\n/).filter(Boolean);
    let firstTs = null;
    let lastTs = null;
    let sessionDay = null;
    let sessionMaxTokens = 0;

    for (const line of lines) {
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }

      const timestamp = parseEventDate(event);
      if (timestamp) {
        firstTs = firstTs ? new Date(Math.min(firstTs.getTime(), timestamp.getTime())) : timestamp;
        lastTs = lastTs ? new Date(Math.max(lastTs.getTime(), timestamp.getTime())) : timestamp;
        sessionDay ||= toDateKey(timestamp);
      }

      if (event?.type === "event_msg" && event?.payload?.type === "token_count") {
        const total = event.payload.info?.total_token_usage?.total_tokens || 0;
        sessionMaxTokens = Math.max(sessionMaxTokens, total);
      }

      if (event?.type === "response_item" && event?.payload?.type === "function_call") {
        const name = normalizeToolName(event.payload.name);
        if (name) {
          toolCalls += 1;
          toolCounts.set(name, (toolCounts.get(name) || 0) + 1);
        }
      }

      const nested = event?.payload?.arguments;
      if (typeof nested === "string" && nested.includes("recipient_name")) {
        for (const match of nested.matchAll(/"recipient_name"\s*:\s*"([^"]+)"/g)) {
          const name = normalizeToolName(match[1]);
          if (name) {
            toolCalls += 1;
            toolCounts.set(name, (toolCounts.get(name) || 0) + 1);
          }
        }
      }
    }

    if (sessionDay) {
      sessionDays.add(sessionDay);
      dayTokens.set(sessionDay, (dayTokens.get(sessionDay) || 0) + sessionMaxTokens);
    }

    totalTokens += sessionMaxTokens;
    maxSessionTokens = Math.max(maxSessionTokens, sessionMaxTokens);
    if (firstTs && lastTs) {
      longestSessionMinutes = Math.max(longestSessionMinutes, Math.round((lastTs - firstTs) / 60000));
    }
  }

  const days = dateRange(from, today).map((date) => {
    const key = toDateKey(date);
    return { date: key, tokens: dayTokens.get(key) || 0, active: sessionDays.has(key) };
  });
  const streaks = calculateStreaks(days.map((day) => ({ date: day.date, count: day.active ? 1 : 0 })));

  return {
    generatedAt: new Date().toISOString(),
    days,
    totals: {
      sessions: files.length,
      totalTokens,
      maxSessionTokens,
      longestSessionMinutes,
      currentStreak: streaks.current,
      longestStreak: streaks.longest,
      toolCalls
    },
    topTools: [...toolCounts.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, 5)
      .map(([name, count]) => ({ name, count }))
  };
}

async function fetchGithubContributions(token) {
  const query = `
    query($login: String!, $from: DateTime!, $to: DateTime!) {
      user(login: $login) {
        contributionsCollection(from: $from, to: $to) {
          contributionCalendar {
            totalContributions
            weeks {
              contributionDays {
                date
                contributionCount
              }
            }
          }
        }
      }
    }
  `;
  const response = await fetch("https://api.github.com/graphql", {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      "user-agent": "profile-activity-generator"
    },
    body: JSON.stringify({
      query,
      variables: { login, from: from.toISOString(), to: today.toISOString() }
    })
  });

  if (!response.ok) {
    throw new Error(`${response.status} ${response.statusText}`);
  }

  const body = await response.json();
  if (body.errors?.length) {
    throw new Error(body.errors.map((error) => error.message).join("; "));
  }

  const calendar = body.data?.user?.contributionsCollection?.contributionCalendar;
  const days = calendar?.weeks?.flatMap((week) => week.contributionDays) || [];
  return {
    generatedAt: new Date().toISOString(),
    totalContributions: calendar?.totalContributions || 0,
    days: days.map((day) => ({ date: day.date, count: day.contributionCount }))
  };
}

function renderSvg(codex, github) {
  const width = 1120;
  const height = 910;
  const codexDays = alignDays(codex.days, "tokens");
  const githubDays = alignDays(github.days, "count");
  const codexMax = Math.max(...codexDays.map((day) => day.value), 1);
  const githubMax = Math.max(...githubDays.map((day) => day.value), 1);
  const topTools = codex.topTools?.length ? codex.topTools : [{ name: "No tool data yet", count: 0 }];
  const totals = codex.totals || {};
  const githubStreaks = calculateStreaks(githubDays.map((day) => ({ date: day.date, count: day.value })));
  const generatedAt = new Date(codex.generatedAt || new Date()).toISOString().slice(0, 10);

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" fill="none" xmlns="http://www.w3.org/2000/svg" role="img" aria-labelledby="title desc">
  <title id="title">${escapeXml(displayName)} Codex and GitHub activity</title>
  <desc id="desc">A profile card showing Codex usage, token activity, GitHub contributions, streaks, and top tools.</desc>
  <defs>
    <linearGradient id="panel" x1="88" y1="85" x2="1000" y2="780" gradientUnits="userSpaceOnUse">
      <stop stop-color="#181818"/>
      <stop offset="1" stop-color="#101010"/>
    </linearGradient>
    <filter id="softShadow" x="64" y="66" width="992" height="822" color-interpolation-filters="sRGB" filterUnits="userSpaceOnUse">
      <feDropShadow dx="0" dy="18" stdDeviation="28" flood-color="#000000" flood-opacity="0.45"/>
    </filter>
    <style>
      .title { font: 700 34px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #f5f7fb; }
      .meta { font: 500 16px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #9298a3; }
      .label { font: 700 17px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #f0f2f5; }
      .small { font: 600 14px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #9ba2ad; }
      .value { font: 800 18px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #ffffff; }
      .caption { font: 600 13px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #7f8792; }
    </style>
  </defs>

  <rect width="${width}" height="${height}" rx="0" fill="#0d0f10"/>
  <g filter="url(#softShadow)">
    <rect x="72" y="72" width="976" height="784" rx="20" fill="url(#panel)" stroke="#242628"/>
  </g>

  <circle cx="560" cy="143" r="50" fill="#e77bbe"/>
  <text x="560" y="158" text-anchor="middle" font-size="35" font-family="ui-sans-serif, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-weight="700" fill="#ffffff">SJ</text>
  <text x="560" y="222" text-anchor="middle" class="title">${escapeXml(displayName)}</text>
  <text x="560" y="252" text-anchor="middle" class="meta">@${escapeXml(login)} · Codex + GitHub activity</text>

  ${renderStats([
    [formatCompact(totals.totalTokens || 0), "누적 토큰"],
    [formatCompact(totals.maxSessionTokens || 0), "최대 세션"],
    [formatDuration(totals.longestSessionMinutes || 0), "최장 작업"],
    [`${totals.currentStreak || 0}일`, "Codex 연속"],
    [`${githubStreaks.current}일`, "GitHub 연속"]
  ])}

  <text x="112" y="405" class="label">Codex 토큰 잔디</text>
  <text x="927" y="405" text-anchor="end" class="small">일별</text>
  ${renderHeatmap(codexDays, 112, 426, codexMax, ["#252525", "#203947", "#2e5b78", "#4b8fc8", "#86c5ff"])}
  ${renderMonthLabels(112, 590)}

  <text x="112" y="650" class="label">GitHub 잔디</text>
  <text x="927" y="650" text-anchor="end" class="small">${formatCompact(github.totalContributions || 0)} contributions</text>
  ${renderHeatmap(githubDays, 112, 671, githubMax, ["#252525", "#0e4429", "#006d32", "#26a641", "#39d353"])}
  ${renderMonthLabels(112, 835)}

  <text x="596" y="405" class="label">활동 인사이트</text>
  ${renderInsightRows([
    ["Codex 세션", `${totals.sessions || 0}회`],
    ["툴 호출", `${formatCompact(totals.toolCalls || 0)}회`],
    ["GitHub 기여", `${formatCompact(github.totalContributions || 0)}회`],
    ["마지막 갱신", generatedAt]
  ], 596, 436)}

  <text x="596" y="575" class="label">가장 많이 사용한 툴</text>
  ${renderToolRows(topTools, 596, 606)}
</svg>
`;
}

function renderStats(items) {
  const x = 112;
  const y = 285;
  const w = 916;
  const cell = w / items.length;
  return `
  <rect x="${x}" y="${y}" width="${w}" height="76" rx="16" fill="#131415" stroke="#27292c"/>
  ${items.map(([value, label], index) => {
    const cx = x + cell * index + cell / 2;
    const line = index === 0 ? "" : `<line x1="${x + cell * index}" y1="${y + 16}" x2="${x + cell * index}" y2="${y + 60}" stroke="#25282b"/>`;
    return `${line}
  <text x="${cx}" y="${y + 31}" text-anchor="middle" class="value">${escapeXml(value)}</text>
  <text x="${cx}" y="${y + 55}" text-anchor="middle" class="small">${escapeXml(label)}</text>`;
  }).join("")}`;
}

function renderHeatmap(days, x, y, max, colors) {
  const size = 14;
  const gap = 4;
  return days.map((day, index) => {
    const week = Math.floor(index / 7);
    const weekday = index % 7;
    const level = day.value <= 0 ? 0 : Math.min(4, Math.max(1, Math.ceil((day.value / max) * 4)));
    return `<rect x="${x + week * (size + gap)}" y="${y + weekday * (size + gap)}" width="${size}" height="${size}" rx="3" fill="${colors[level]}"><title>${day.date}: ${formatCompact(day.value)}</title></rect>`;
  }).join("\n  ");
}

function renderMonthLabels(x, y) {
  const months = ["8월", "9월", "10월", "11월", "12월", "1월", "2월", "3월", "4월", "5월", "6월", "7월"];
  return months.map((month, index) => `<text x="${x + index * 78}" y="${y}" class="caption">${month}</text>`).join("\n  ");
}

function renderInsightRows(rows, x, y) {
  return rows.map(([label, value], index) => {
    const yy = y + index * 34;
    return `<text x="${x}" y="${yy}" class="small">${escapeXml(label)}</text><text x="${x + 320}" y="${yy}" text-anchor="end" class="value">${escapeXml(value)}</text>`;
  }).join("\n  ");
}

function renderToolRows(tools, x, y) {
  return tools.slice(0, 5).map((tool, index) => {
    const yy = y + index * 34;
    const color = ["#f7c948", "#54d2d2", "#ff8a4c", "#8bb8ff", "#e77bbe"][index % 5];
    return `<circle cx="${x + 8}" cy="${yy - 5}" r="8" fill="${color}"/><text x="${x + 28}" y="${yy}" class="value">${escapeXml(tool.name)}</text><text x="${x + 430}" y="${yy}" text-anchor="end" class="small">${tool.count}회 실행</text>`;
  }).join("\n  ");
}

function alignDays(days, key) {
  const map = new Map((days || []).map((day) => [day.date, Number(day[key] || 0)]));
  return dateRange(from, today).map((date) => {
    const dateKey = toDateKey(date);
    return { date: dateKey, value: map.get(dateKey) || 0 };
  });
}

function listJsonlFiles(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  return entries.flatMap((entry) => {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) return listJsonlFiles(fullPath);
    return entry.isFile() && entry.name.endsWith(".jsonl") ? [fullPath] : [];
  });
}

function parseEventDate(event) {
  if (typeof event?.timestamp === "string") return new Date(event.timestamp);
  const ts = event?.payload?.timestamp || event?.payload?.ts;
  if (typeof ts === "number") return new Date(ts * 1000);
  return null;
}

function normalizeToolName(name) {
  if (!name) return "";
  return String(name)
    .replace(/^functions\./, "")
    .replace(/^web\./, "")
    .replace(/^image_gen\./, "")
    .replace(/^multi_tool_use\./, "")
    .replace(/_/g, "-")
    .slice(0, 34);
}

function calculateStreaks(days) {
  let longest = 0;
  let run = 0;
  for (const day of days) {
    if (day.count > 0) {
      run += 1;
      longest = Math.max(longest, run);
    } else {
      run = 0;
    }
  }

  let current = 0;
  for (let index = days.length - 1; index >= 0; index -= 1) {
    if (days[index].count > 0) current += 1;
    else break;
  }

  return { current, longest };
}

function dateRange(start, end) {
  const dates = [];
  for (let date = new Date(start); date <= end; date = addDays(date, 1)) {
    dates.push(new Date(date));
  }
  return dates;
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function addDays(date, days) {
  const next = new Date(date);
  next.setDate(next.getDate() + days);
  return next;
}

function toDateKey(date) {
  return date.toISOString().slice(0, 10);
}

function formatCompact(value) {
  const number = Number(value || 0);
  if (number >= 100000000) return `${trim(number / 100000000)}억`;
  if (number >= 10000) return `${trim(number / 10000)}만`;
  return new Intl.NumberFormat("ko-KR").format(number);
}

function formatDuration(minutes) {
  if (minutes >= 60) return `${Math.floor(minutes / 60)}시간 ${minutes % 60}분`;
  return `${minutes}분`;
}

function trim(value) {
  return value.toFixed(1).replace(/\.0$/, "");
}

function escapeXml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
