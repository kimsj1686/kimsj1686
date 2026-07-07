import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const assetsDir = path.join(root, "assets");
const dataDir = path.join(root, "data");
const codexDataPath = path.join(dataDir, "codex-activity.json");
const svgPath = path.join(assetsDir, "activity-profile.svg");

const login = process.env.GITHUB_LOGIN || "kimsj1686";
const displayName = process.env.PROFILE_NAME || "sungjin";
const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const timezoneLabel = process.env.TZ || Intl.DateTimeFormat().resolvedOptions().timeZone || "local time";

fs.mkdirSync(assetsDir, { recursive: true });
fs.mkdirSync(dataDir, { recursive: true });

const today = startOfDay(new Date());
const from = addDays(today, -364);
const codexActivity = loadCodexActivity();

fs.writeFileSync(svgPath, renderSvg(codexActivity), "utf8");

function loadCodexActivity() {
  const sessionsDir = path.join(codexHome, "sessions");
  const stateDb = path.join(codexHome, "state_5.sqlite");

  if (fs.existsSync(sessionsDir)) {
    const activity = collectCodexActivity(sessionsDir, stateDb);
    fs.writeFileSync(codexDataPath, JSON.stringify(activity, null, 2) + "\n", "utf8");
    return activity;
  }

  if (fs.existsSync(codexDataPath)) {
    return JSON.parse(fs.readFileSync(codexDataPath, "utf8"));
  }

  return {
    generatedAt: new Date().toISOString(),
    source: "no local Codex data found",
    days: emptyDays(),
    totals: emptyTotals(),
    topTools: []
  };
}

function collectCodexActivity(sessionsDir, stateDb) {
  const sessionFiles = listJsonlFiles(sessionsDir);
  const bySession = parseSessionFiles(sessionFiles);
  const stateRows = readThreadState(stateDb);

  const dayTokens = new Map();
  const activeDays = new Set();
  let totalTokens = 0;
  let maxSessionTokens = 0;
  let longestSessionMinutes = 0;

  if (stateRows.length) {
    for (const row of stateRows) {
      const created = new Date(Number(row.created_at || 0) * 1000);
      if (!Number.isFinite(created.getTime())) continue;
      const key = toDateKey(created);
      const tokens = Number(row.tokens_used || 0);
      activeDays.add(key);
      dayTokens.set(key, (dayTokens.get(key) || 0) + tokens);
      totalTokens += tokens;
      maxSessionTokens = Math.max(maxSessionTokens, tokens);

      const started = Number(row.created_at || 0);
      const ended = Number(row.updated_at || 0);
      if (started && ended) {
        longestSessionMinutes = Math.max(longestSessionMinutes, Math.round((ended - started) / 60));
      }
    }
  } else {
    for (const session of bySession.values()) {
      if (!session.day) continue;
      activeDays.add(session.day);
      dayTokens.set(session.day, (dayTokens.get(session.day) || 0) + session.tokens);
      totalTokens += session.tokens;
      maxSessionTokens = Math.max(maxSessionTokens, session.tokens);
      longestSessionMinutes = Math.max(longestSessionMinutes, session.durationMinutes);
    }
  }

  const days = dateRange(from, today).map((date) => {
    const key = toDateKey(date);
    return { date: key, tokens: dayTokens.get(key) || 0, active: activeDays.has(key) };
  });
  const streaks = calculateStreaks(days.map((day) => ({ date: day.date, count: day.active ? 1 : 0 })));

  const toolCounts = new Map();
  for (const session of bySession.values()) {
    for (const [name, count] of session.tools.entries()) {
      toolCounts.set(name, (toolCounts.get(name) || 0) + count);
    }
  }

  return {
    generatedAt: new Date().toISOString(),
    source: stateRows.length ? "Codex local SQLite threads table" : "Codex local session JSONL files",
    days,
    totals: {
      sessions: stateRows.length || bySession.size,
      totalTokens,
      maxSessionTokens,
      longestSessionMinutes,
      currentStreak: streaks.current,
      longestStreak: streaks.longest,
      toolCalls: [...toolCounts.values()].reduce((sum, count) => sum + count, 0)
    },
    topTools: [...toolCounts.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, 5)
      .map(([name, count]) => ({ name, count }))
  };
}

function parseSessionFiles(files) {
  const sessions = new Map();

  for (const file of files) {
    const lines = fs.readFileSync(file, "utf8").split(/\r?\n/).filter(Boolean);
    const session = {
      day: null,
      firstTs: null,
      lastTs: null,
      tokens: 0,
      tools: new Map()
    };

    for (const line of lines) {
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }

      const timestamp = parseEventDate(event);
      if (timestamp && Number.isFinite(timestamp.getTime())) {
        session.firstTs = session.firstTs ? new Date(Math.min(session.firstTs.getTime(), timestamp.getTime())) : timestamp;
        session.lastTs = session.lastTs ? new Date(Math.max(session.lastTs.getTime(), timestamp.getTime())) : timestamp;
        session.day ||= toDateKey(timestamp);
      }

      if (event?.type === "event_msg" && event?.payload?.type === "token_count") {
        const total = event.payload.info?.total_token_usage?.total_tokens || 0;
        session.tokens = Math.max(session.tokens, total);
      }

      if (event?.type === "response_item" && event?.payload?.type === "function_call") {
        addTool(session.tools, event.payload.name);
      }

      const nested = event?.payload?.arguments;
      if (typeof nested === "string" && nested.includes("recipient_name")) {
        for (const match of nested.matchAll(/"recipient_name"\s*:\s*"([^"]+)"/g)) {
          addTool(session.tools, match[1]);
        }
      }
    }

    session.durationMinutes =
      session.firstTs && session.lastTs ? Math.max(1, Math.round((session.lastTs - session.firstTs) / 60000)) : 0;
    sessions.set(file, session);
  }

  return sessions;
}

function readThreadState(dbPath) {
  if (!fs.existsSync(dbPath)) return [];
  try {
    const output = execFileSync(
      "sqlite3",
      [
        "-json",
        dbPath,
        "select id, created_at, updated_at, tokens_used from threads where tokens_used > 0 order by created_at asc;"
      ],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
    );
    return JSON.parse(output || "[]");
  } catch {
    return [];
  }
}

function renderSvg(codex) {
  const width = 1120;
  const height = 760;
  const codexDays = alignDays(codex.days, "tokens");
  const codexMax = Math.max(...codexDays.map((day) => day.value), 1);
  const topTools = codex.topTools?.length ? codex.topTools : [{ name: "No tool data yet", count: 0 }];
  const totals = codex.totals || emptyTotals();
  const generatedAt = toDateKey(new Date(codex.generatedAt || new Date()));
  const sourceLabel = codex.source?.includes("SQLite") ? "local Codex DB" : "local Codex sessions";

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" fill="none" xmlns="http://www.w3.org/2000/svg" role="img" aria-labelledby="title desc">
  <title id="title">${escapeXml(displayName)} Codex activity</title>
  <desc id="desc">A profile card showing local Codex token activity, session streaks, and top tools.</desc>
  <defs>
    <linearGradient id="panel" x1="72" y1="64" x2="1048" y2="696" gradientUnits="userSpaceOnUse">
      <stop stop-color="#191919"/>
      <stop offset="1" stop-color="#101112"/>
    </linearGradient>
    <filter id="softShadow" x="45" y="42" width="1030" height="690" color-interpolation-filters="sRGB" filterUnits="userSpaceOnUse">
      <feDropShadow dx="0" dy="18" stdDeviation="28" flood-color="#000000" flood-opacity="0.38"/>
    </filter>
    <style>
      .title { font: 800 38px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #f7f8fb; }
      .meta { font: 600 16px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #9ba6b8; }
      .label { font: 800 19px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #f3f6fb; }
      .small { font: 650 14px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #9ba6b8; }
      .value { font: 850 20px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #ffffff; }
      .caption { font: 650 13px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #8290a4; }
      .tool { font: 800 18px ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; fill: #f7f8fb; }
    </style>
  </defs>

  <rect width="${width}" height="${height}" fill="#0b0f12"/>
  <g filter="url(#softShadow)">
    <rect x="56" y="56" width="1008" height="648" rx="22" fill="url(#panel)" stroke="#2a2d31"/>
  </g>

  <circle cx="560" cy="130" r="52" fill="#de72bd"/>
  <text x="560" y="148" text-anchor="middle" font-size="36" font-family="ui-sans-serif, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" font-weight="850" fill="#ffffff">SJ</text>
  <text x="560" y="214" text-anchor="middle" class="title">${escapeXml(displayName)}</text>
  <text x="560" y="244" text-anchor="middle" class="meta">@${escapeXml(login)} · local Codex CLI activity · ${escapeXml(sourceLabel)}</text>

  ${renderStats([
    [formatCompact(totals.totalTokens || 0), "누적 토큰"],
    [formatCompact(totals.maxSessionTokens || 0), "최대 세션"],
    [`${totals.sessions || 0}회`, "Codex 세션"],
    [`${totals.currentStreak || 0}일`, "현재 연속"],
    [`${totals.longestStreak || 0}일`, "최장 연속"]
  ])}

  <text x="104" y="395" class="label">로컬 Codex 토큰 활동</text>
  <text x="1016" y="395" text-anchor="end" class="small">최근 365일 · ${escapeXml(timezoneLabel)} · 갱신 ${escapeXml(generatedAt)}</text>
  ${renderHeatmap(codexDays, 104, 418, codexMax, ["#252627", "#213745", "#2f5b75", "#478bc2", "#8ccbff"])}
  ${renderMonthLabels(104, 580)}

  <g transform="translate(104 626)">
    ${renderInsightPills([
      ["툴 호출", `${formatCompact(totals.toolCalls || 0)}회`],
      ["최고 일간 토큰", formatCompact(codexMax)],
      ["로컬 기준", generatedAt]
    ])}
  </g>

  <text x="654" y="627" class="label">가장 많이 사용한 툴</text>
  ${renderToolRows(topTools, 654, 659)}
</svg>
`;
}

function renderStats(items) {
  const x = 104;
  const y = 278;
  const w = 912;
  const cell = w / items.length;
  return `
  <rect x="${x}" y="${y}" width="${w}" height="80" rx="16" fill="#131516" stroke="#2b2f34"/>
  ${items.map(([value, label], index) => {
    const cx = x + cell * index + cell / 2;
    const line = index === 0 ? "" : `<line x1="${x + cell * index}" y1="${y + 16}" x2="${x + cell * index}" y2="${y + 64}" stroke="#2a2d31"/>`;
    return `${line}
  <text x="${cx}" y="${y + 34}" text-anchor="middle" class="value">${escapeXml(value)}</text>
  <text x="${cx}" y="${y + 59}" text-anchor="middle" class="small">${escapeXml(label)}</text>`;
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

function renderInsightPills(rows) {
  return rows.map(([label, value], index) => {
    const x = index * 164;
    return `<rect x="${x}" y="0" width="144" height="48" rx="12" fill="#15181b" stroke="#2b2f34"/>
    <text x="${x + 16}" y="20" class="caption">${escapeXml(label)}</text>
    <text x="${x + 16}" y="38" class="value">${escapeXml(value)}</text>`;
  }).join("\n  ");
}

function renderToolRows(tools, x, y) {
  return tools.slice(0, 3).map((tool, index) => {
    const yy = y + index * 31;
    const color = ["#ffd158", "#59d5dc", "#ff9564"][index % 3];
    return `<circle cx="${x + 8}" cy="${yy - 6}" r="8" fill="${color}"/><text x="${x + 28}" y="${yy}" class="tool">${escapeXml(tool.name)}</text><text x="1016" y="${yy}" text-anchor="end" class="small">${tool.count}회 실행</text>`;
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

function addTool(map, name) {
  const normalized = normalizeToolName(name);
  if (normalized) map.set(normalized, (map.get(normalized) || 0) + 1);
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

function emptyDays() {
  return dateRange(from, today).map((date) => ({ date: toDateKey(date), tokens: 0, active: false }));
}

function emptyTotals() {
  return {
    sessions: 0,
    totalTokens: 0,
    maxSessionTokens: 0,
    longestSessionMinutes: 0,
    currentStreak: 0,
    longestStreak: 0,
    toolCalls: 0
  };
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
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
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
