"use strict";

const byId = (id) => document.getElementById(id);
const list = (value) => Array.isArray(value) ? value : [];
const numbers = new Intl.NumberFormat();
const dates = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
const shortDays = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", timeZone: "UTC" });
const repoPattern = /^[a-z0-9_.-]+\/[a-z0-9_.-]+$/i;
const views = new Set(["queue", "history", "usage"]);
const labelNames = {
  all_models: "All models",
  approve: "Approval",
  baseline: "Baselined",
  claude: "Claude",
  codex: "Codex",
  comment: "Comment",
  complete: "Complete",
  completion: "Evidence pass",
  evidence: "Evidence pass",
  failed: "Failed",
  focused: "Focused",
  kimi: "Kimi",
  local: "Local only",
  multi: "Multi-model",
  pending: "Pending",
  published: "Published",
  screen: "Screening",
  screening: "Screening",
  synthesis: "Synthesis",
  uncertain: "Checking publication",
  verified: "Published",
};

let view = "queue";
let snapshot = null;
let stateRequest = null;
let metricsRequest = null;
let metricsSnapshot = null;
let detailSelection = null;
let detailRequest = null;
let displayChart = "calls";
let chartObserver = null;
let pollTimer = null;
let queueLookup = null;
let queueSending = null;
const renderKeys = new Map();
const openStacks = new Set();

function element(tag, classes, value) {
  const node = document.createElement(tag);
  if (classes) node.className = classes;
  if (value != null) node.textContent = String(value);
  return node;
}

function humanize(value) {
  if (!value) return "";
  const lower = String(value).toLowerCase();
  if (Object.hasOwn(labelNames, lower)) return labelNames[lower];
  return String(value).replaceAll(/([a-z])([A-Z])/g, "$1 $2").replaceAll(/[_-]/g, " ").replace(/^./, (char) => char.toUpperCase());
}

function count(value) {
  return Number.isFinite(value) ? numbers.format(value) : "—";
}

function batchAmount(first, second) {
  if (!Number.isFinite(first) && !Number.isFinite(second)) return null;
  return (first ?? 0) + (second ?? 0);
}

function date(seconds) {
  return seconds > 0 ? dates.format(seconds * 1000) : "—";
}

function age(seconds, now = Math.floor(Date.now() / 1000)) {
  const span = Math.max(0, now - seconds);
  if (span < 60) return "just now";
  if (span < 3600) return `${Math.floor(span / 60)}m ago`;
  if (span < 86400) return `${Math.floor(span / 3600)}h ago`;
  return `${Math.floor(span / 86400)}d ago`;
}

function duration(ms) {
  if (!Number.isFinite(ms)) return "—";
  if (ms < 1000) return `${count(ms)} ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(ms < 10000 ? 1 : 0)} s`;
  const whole = Math.round(ms / 1000);
  return `${Math.floor(whole / 60)}m ${whole % 60}s`;
}

function phrase(parts) {
  return parts.filter(Boolean).join(" · ");
}

function plural(value, unit, pluralUnit = `${unit}s`) {
  return `${count(value)} ${value === 1 ? unit : pluralUnit}`;
}

function validNumber(value) {
  return Number.isInteger(value) && value > 0 && value <= 2147483647;
}

function parseTarget(value, fallback = "") {
  const text = value.trim();
  const bareLink = /^github\.com\//i.test(text);
  if (bareLink || /^https?:\/\//i.test(text)) {
    try {
      const url = new URL(bareLink ? `https://${text}` : text);
      if (url.origin !== "https://github.com" || url.username || url.password) return null;
      const parts = url.pathname.replace(/\/$/, "").split("/").slice(1);
      const [owner, repository, type, id, detail] = parts;
      const repo = `${owner}/${repository}`;
      const kind = type === "pull" ? "pr" : ["stack", "stacks"].includes(type) ? "stack" : "";
      const number = Number(id);
      const validPath = parts.length === 4 ||
        (kind === "pr" && parts.length === 5 && ["files", "commits", "checks", "changes"].includes(detail));
      if (validPath && repoPattern.test(repo) && kind && /^\d+$/.test(id) && validNumber(number)) {
        return { repo, number, kind };
      }
    } catch {
      return null;
    }
    return null;
  }
  const named = /^([a-z0-9_.-]+\/[a-z0-9_.-]+)(?:\s*#\s*|\s+)(\d+)$/i.exec(text);
  const unqualified = /^#?(\d+)$/.exec(text);
  const number = Number(named?.[2] || unqualified?.[1]);
  if (!validNumber(number)) return null;
  return { repo: named?.[1] || fallback, number, kind: null };
}

function sameRepo(first, second) {
  return String(first).toLowerCase() === String(second).toLowerCase();
}

function keyOf(repo, number) {
  return `${repo}#${number}`;
}

function stackAccent(repo, identity) {
  let hash = 0;
  for (const char of `${repo.toLowerCase()}#${identity}`) {
    hash = (Math.imul(31, hash) + char.charCodeAt(0)) >>> 0;
  }
  return `stack-color-${hash % 8}`;
}

function gitHubLink(repo, number, reviewId = null) {
  if (!repoPattern.test(repo) || !validNumber(number)) return null;
  const path = repo.split("/").map(encodeURIComponent).join("/");
  const fragment = Number.isSafeInteger(reviewId) && reviewId > 0 ? `#pullrequestreview-${reviewId}` : "";
  const link = element("a", null, fragment ? "Open GitHub review" : "Open pull request");
  link.href = `https://github.com/${path}/pull/${number}${fragment}`;
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  return link;
}

const errorLabels = {
  AlreadyRunning: "Talos is busy updating the queue. Try again in a moment.",
  UnknownRepository: "This repository is not registered with Talos.",
  PullRequestNotReady: "That pull request is not open.",
  NoOpenStackMembers: "The stack has no open pull requests.",
  InvalidRequest: "Check the repository and pull request or stack number.",
  Forbidden: "The dashboard rejected the request origin.",
};

async function request(path, options = {}) {
  const response = await fetch(path, { cache: "no-store", credentials: "same-origin", ...options });
  const data = await response.json().catch(() => null);
  if (!response.ok || !data) {
    const code = data?.error;
    const message = typeof code === "string" ?
      (Object.hasOwn(errorLabels, code) ? errorLabels[code] : humanize(code)) : `Request failed (${response.status}).`;
    throw Object.assign(new Error(message), { status: response.status });
  }
  return data;
}

function update(key, value, render) {
  const encoded = JSON.stringify(value);
  if (renderKeys.get(key) === encoded) return;
  renderKeys.set(key, encoded);
  render();
}

function replace(container, content) {
  const focus = document.activeElement;
  const key = container.contains(focus) ? focus?.dataset?.reviewKey : null;
  container.replaceChildren(content);
  if (key) {
    const next = Array.from(container.querySelectorAll("[data-review-key]")).find((node) => node.dataset.reviewKey === key);
    next?.focus({ preventScroll: true });
  }
}

function note(container, message, tone = "") {
  if (container.textContent !== message) container.textContent = message;
  container.hidden = !message;
  container.dataset.tone = tone;
}

function setConnection(connected, message) {
  const indicator = byId("sync-state");
  const text = connected ? "Local connection" : "Disconnected";
  if (indicator.textContent !== text) indicator.textContent = text;
  indicator.dataset.tone = connected ? "online" : "offline";
  note(byId("connection-error"), message || "");
}

function chooseStage(job, now) {
  const active = list(job.active_providers);
  const stage = humanize(job.stage);
  if (job.phase === "complete" || job.phase === "baseline") {
    return { title: job.phase === "baseline" ? "Baselined" : "Complete", tone: job.phase === "complete" ? "good" : "" };
  }
  if (job.phase === "failed") return { title: "Failed", tone: "error", detail: humanize(job.last_error) };
  if (job.phase === "uncertain") return { title: "Checking publication", tone: "warning" };
  if (active.length) {
    const shared = [...new Set(active.map((provider) => humanize(provider.stage)).filter(Boolean))];
    return { title: "Running", tone: "active", detail: shared.length === 1 ? shared[0] : (stage === "Reviewing" ? "" : stage) };
  }
  if (job.blocked_by) return { title: "Waiting for stack", detail: `Depends on #${job.blocked_by}` };
  if (stage === "Paused" || snapshot?.repos?.some((repo) => sameRepo(repo.name, job.repo) && repo.paused)) {
    return { title: "Paused", tone: "warning" };
  }
  if (job.next_at > now) {
    return { title: job.attempts > 0 ? "Retry scheduled" : "Scheduled", tone: "warning", detail: date(job.next_at) };
  }
  return { title: stage && stage !== "Pending" ? stage : "Queued", detail: job.last_error ? humanize(job.last_error) : "" };
}

function phaseLabel(status) {
  const output = element("div");
  const main = element("span", "phase-text", status.title);
  main.dataset.tone = status.tone || "";
  output.append(main);
  if (status.detail) output.append(element("span", "phase-note", status.detail));
  return output;
}

function progressLabel(job) {
  const wrap = element("div", "job-progress");
  const percent = Number.isFinite(job.percent) ? Math.max(0, Math.min(100, Math.round(job.percent))) : null;
  const completed = job.completed_sections || 0;
  const sectionCount = job.total_sections > 0 ? `${completed}/${job.total_sections} sections` : "";
  const labels = element("div", "progress-meta");
  if (sectionCount) labels.append(element("span", null, sectionCount));
  if (percent != null) labels.append(element("span", "mono", `${percent}%`));
  if (percent == null && !sectionCount) labels.append(element("span", "minor", "—"));
  wrap.append(labels);
  if (percent != null) {
    const bar = element("progress");
    bar.value = percent;
    bar.max = 100;
    bar.setAttribute("aria-label", `Review progress for #${job.number}`);
    wrap.append(bar);
  }
  return wrap;
}

function providersLabel(values, allModels) {
  if (!values.length) return element("span", "minor", allModels ? "All models" : "—");
  const group = element("div", "providers");
  const names = new Map();
  for (const item of values) {
    const key = `${item.engine}:${item.model || ""}`;
    if (names.has(key)) names.get(key).count += 1;
    else names.set(key, { ...item, count: 1 });
  }
  for (const item of names.values()) {
    const text = item.count > 1 ? `${humanize(item.engine)} ×${item.count}` : humanize(item.engine);
    const line = element("div");
    line.append(element("span", "provider-name", text));
    if (item.model) line.append(element("span", "provider-model", ` · ${item.model}`));
    group.append(line);
  }
  return group;
}

function reviewKey(item, head = null, showDetails = true, stack = null) {
  const wrap = element("div", "review-key");
  const label = element("button", "review-link", `#${item.number}`);
  label.type = "button";
  label.setAttribute("aria-label", `Review details for ${item.repo} #${item.number}`);
  label.dataset.reviewKey = phrase([keyOf(item.repo, item.number), head, item.at]);
  label.addEventListener("click", () => openReview(item.repo, item.number, head, item.at ?? null, item.review_id ?? null));
  wrap.append(label);
  if (showDetails && item.title) wrap.append(element("span", "review-title", item.title));
  if (showDetails) {
    const metadata = element("span", "review-repo", phrase([item.repo, item.draft && "Draft"]));
    if (stack) metadata.append(element("span", "stack-label", ` · ${stack.label}`));
    wrap.append(metadata);
  }
  return wrap;
}

function renderTable(headers, rows, emptyMessage, rowClasses = []) {
  if (!rows.length) return element("p", "empty", emptyMessage);
  const table = element("table");
  const header = element("thead");
  const headRow = element("tr");
  for (const col of headers) {
    const label = typeof col === "string" ? col : col[0];
    const th = element("th", typeof col === "string" ? "" : col[1], label);
    th.scope = "col";
    headRow.append(th);
  }
  header.append(headRow);
  const body = element("tbody");
  for (const [rowIndex, row] of rows.entries()) {
    const tr = element("tr", rowClasses[rowIndex]);
    for (const [index, cell] of row.entries()) {
      const col = headers[index];
      const td = element("td", typeof col === "string" ? "" : col[1]);
      if (cell instanceof Node) td.append(cell);
      else td.textContent = cell == null ? "—" : String(cell);
      tr.append(td);
    }
    body.append(tr);
  }
  table.append(header, body);
  return table;
}

function filterRows(rows, query) {
  if (!query.trim()) return rows;
  const target = parseTarget(query);
  if (target && target.kind !== "stack") {
    return rows.filter((row) => row.number === target.number && (!target.repo || sameRepo(row.repo, target.repo)));
  }
  const words = query.toLowerCase().trim().split(/\s+/);
  return rows.filter((row) => {
    const searchable = `${row.repo} ${row.title || ""} #${row.number} ${row.head || ""} ${row.phase || ""}`.toLowerCase();
    return words.every((word) => searchable.includes(word));
  });
}

function renderQueue() {
  const jobs = list(snapshot?.jobs);
  const memberships = new Map();
  for (const stack of list(snapshot?.stacks)) {
    const label = stack.number ? `Stack #${stack.number}` : `Stack ${stack.name}`;
    const accent = stackAccent(stack.repo, stack.number || stack.name);
    for (const member of list(stack.members)) memberships.set(keyOf(stack.repo, member.number), { label, accent });
  }
  const active = jobs.filter((job) => !["baseline", "complete"].includes(job.phase));
  const running = active.filter((job) => list(job.active_providers).length > 0);
  const pending = active.filter((job) => job.phase === "pending" && !list(job.active_providers).length).length;
  byId("queue-summary").textContent = phrase([
    plural(running.length, "running", "running"), plural(pending, "queued", "queued"),
    plural(active.filter((job) => job.phase === "failed").length, "failed", "failed"),
  ]);
  const rows = byId("queue-filter").value === "active" ? active : jobs;
  const selected = filterRows(rows, byId("queue-search").value);
  const now = snapshot?.at || 0;
  const rank = (job) => {
    if (list(job.active_providers).length) return 0;
    if (job.phase === "pending") return job.blocked_by ? 3 : job.next_at > now ? 2 : 1;
    return { uncertain: 2, failed: 4, complete: 5, baseline: 6 }[job.phase] ?? 7;
  };
  const ordered = [...selected].sort((first, second) => rank(first) - rank(second) ||
    first.repo.localeCompare(second.repo) || second.number - first.number);
  const statuses = ordered.map((job) => [job, chooseStage(job, now), memberships.get(keyOf(job.repo, job.number)) ||
    (job.stack ? { label: `Stack #${job.stack}`, accent: stackAccent(job.repo, job.stack) } : null)]);
  update("queue", statuses, () => {
    replace(byId("queue-results"), renderTable(["Pull request", "State", "Progress", "Reviewers"], statuses.map(([job, status, stack]) => [
      reviewKey(job, null, true, stack), phaseLabel(status), progressLabel(job), providersLabel(list(job.active_providers), job.all_models),
    ]), snapshot ? "No matching reviews." : "Loading queue…", statuses.map(([, , stack]) => stack ? `linked-row ${stack.accent}` : "")));
  });

  const activeKeys = new Set(active.map((job) => keyOf(job.repo, job.number)));
  const stacks = list(snapshot?.stacks).filter((stack) => list(stack.members).some((member) => activeKeys.has(keyOf(stack.repo, member.number))));
  byId("stacks-panel").hidden = !stacks.length;
  update("stacks", stacks, () => {
    const group = element("div", "stack-items");
    for (const stack of stacks) {
      const details = element("details", `stack ${stackAccent(stack.repo, stack.number || stack.name)}`);
      const stackKey = phrase([stack.repo, stack.number || stack.name]);
      details.open = openStacks.has(stackKey);
      details.addEventListener("toggle", () => {
        if (details.open) openStacks.add(stackKey);
        else openStacks.delete(stackKey);
      });
      const title = element("summary", null, stack.number ? `Stack #${stack.number}` : stack.name);
      title.append(element("span", "minor", ` ${stack.repo}`));
      const members = element("ol", "stack-list");
      for (const member of list(stack.members)) {
        const row = element("li", null);
        const state = phrase([humanize(member.phase), member.draft && "Draft", member.blocked_by && `Depends on #${member.blocked_by}`]);
        row.append(reviewKey({ ...member, repo: stack.repo }, null, false), element("span", "phase-note", state));
        members.append(row);
      }
      details.append(title, members);
      group.append(details);
    }
    replace(byId("stacks"), group);
  });
}

function renderRepos() {
  const repos = list(snapshot?.repos);
  byId("repo-count").textContent = count(repos.length);
  const rows = repos.map((repo) => ({ ...repo, label: repo.paused ? "Paused" : repo.last_scan_at > 0 ?
    `Scanned ${age(repo.last_scan_at, snapshot.at)}` : "Awaiting first scan" }));
  update("repos", rows, () => {
    const nodes = document.createDocumentFragment();
    for (const repo of rows) {
      const description = element("span", "repo-status", repo.label);
      if (repo.paused) description.dataset.tone = "warning";
      if (repo.last_scan_at > 0) description.title = date(repo.last_scan_at);
      const item = element("li");
      item.append(element("span", "repo-name", repo.name), description);
      nodes.append(item);
    }
    if (rows.length === 0) nodes.append(element("li", "repo-status", "No registered repositories"));
    byId("repositories").replaceChildren(nodes);
  });
  update("repo-options", repos.map((repo) => repo.name), () => {
    const select = byId("queue-repo");
    const prior = select.value;
    const placeholder = element("option", null, "Select a repository");
    placeholder.value = "";
    select.replaceChildren(placeholder, ...repos.map((repo) => {
      const option = element("option", null, repo.name);
      option.value = repo.name;
      return option;
    }));
    const selected = repos.find((repo) => sameRepo(repo.name, prior));
    if (selected) select.value = selected.name;
    else if (repos.length === 1) select.value = repos[0].name;
    syncTarget();
  });
}

function historyStatus(row) {
  const publication = humanize(row.publication);
  const result = humanize(row.event);
  if (!result) return publication || "Saved";
  return phrase([result, publication]);
}

function renderHistory() {
  const history = list(historySnapshot);
  const desired = byId("history-filter").value;
  const filtered = filterRows(history, byId("history-search").value).filter((item) => {
    const published = item.publication === "verified" || item.publication === "published";
    return desired === "" || (desired === "published" ? published : !published);
  });
  const ordered = [...filtered].sort((first, second) => second.at - first.at || second.number - first.number);
  byId("history-summary").textContent = history.length ? plural(history.length, "saved verdict") : "Saved verdicts";
  update("history", ordered, () => {
    replace(byId("history-results"), renderTable(["Pull request", "Verdict", "Depth", "Coverage", ["Saved", "time-cell"]], ordered.map((item) => [
      reviewKey(item, item.head), historyStatus(item), humanize(item.route) || "—",
      item.complete === true ? "Complete" : item.complete === false ? "Limited" : "—", date(item.at),
    ]), historySnapshot ? "No matching saved verdicts." : "Loading saved verdicts…"));
  });
}

function metric(label, value, description) {
  const group = element("dl", "panel metric");
  group.append(element("dt", null, label), element("dd", "primary-value", count(value)));
  if (description) group.append(element("dd", "metric-detail", description));
  return group;
}

function tableBox(table) {
  const container = element("div", "table-wrap");
  container.append(table);
  return container;
}

function chartDay(value) {
  const milliseconds = Date.parse(`${value}T00:00:00Z`);
  return Number.isFinite(milliseconds) ? shortDays.format(milliseconds) : String(value || "");
}

function drawChart(canvas, series) {
  if (!canvas.isConnected || !series.length) return;
  const context = canvas.getContext("2d");
  if (!context) return;
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  if (width < 90 || height < 70) return;
  const scale = Math.min(2, window.devicePixelRatio || 1);
  const colors = getComputedStyle(canvas);
  const color = (name) => colors.getPropertyValue(`--${name}`).trim();
  canvas.width = Math.round(width * scale);
  canvas.height = Math.round(height * scale);
  context.scale(scale, scale);
  const axes = { top: 12, right: 8, bottom: 25 };
  const tokenMode = displayChart === "tokens";
  const totals = series.map((point) => tokenMode ? batchAmount(point.input_tokens, point.output_tokens) : point.attempts);
  const max = Math.max(1, ...totals.map((n) => Number.isFinite(n) ? n : 0));
  const ticks = [...new Set([0, Math.round(max / 2), max])];
  const compact = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  context.font = "12px ui-monospace, Menlo, monospace";
  const labelWidth = Math.max(...ticks.map((tick) => context.measureText(compact.format(tick)).width));
  const left = Math.ceil(labelWidth + 11);
  const top = axes.top;
  const bottom = height - axes.bottom;
  const plot = width - left - axes.right;
  const step = plot / series.length;
  const thickness = Math.max(1, Math.min(18, step * .72));
  const y = (n) => bottom - (bottom - top) * n / max;

  context.textBaseline = "middle";
  for (const tick of ticks) {
    const level = y(tick);
    context.fillStyle = color("muted");
    context.textAlign = "right";
    context.fillText(compact.format(tick), left - 7, level);
    context.strokeStyle = color("line");
    context.beginPath();
    context.moveTo(left, level + .5);
    context.lineTo(width - axes.right, level + .5);
    context.stroke();
  }
  for (const [index, point] of series.entries()) {
    const total = totals[index];
    if (!(total > 0)) continue;
    const x = left + step * (index + .5) - thickness / 2;
    const first = tokenMode ? Math.min(total, point.input_tokens ?? 0) : Math.min(total, point.reported ?? 0);
    context.fillStyle = color("chart-secondary");
    context.fillRect(x, y(total), thickness, bottom - y(total));
    if (first) {
      context.fillStyle = color("accent");
      context.fillRect(x, y(first), thickness, bottom - y(first));
    }
  }
  context.fillStyle = color("muted");
  context.textBaseline = "bottom";
  context.textAlign = "left";
  context.fillText(chartDay(series[0].day), left, height - 3);
  if (series.length > 1) {
    context.textAlign = "right";
    context.fillText(chartDay(series.at(-1).day), width - axes.right, height - 3);
  }
  if (width >= 530 && series.length > 3) {
    context.textAlign = "center";
    context.fillText(chartDay(series[Math.floor(series.length / 2)].day), left + plot / 2, height - 3);
  }
}

function renderMetrics() {
  const metrics = metricsSnapshot;
  if (!metrics) return;
  update("metrics", metrics, () => {
    chartObserver?.disconnect();
    const content = document.createDocumentFragment();
    const totals = element("div", "metric-grid");
    const observations = `${count(metrics.reported ?? 0)} of ${count(metrics.attempts ?? 0)} calls with token counts`;
    totals.append(
      metric("Model calls", metrics.attempts, observations),
      metric("Reported tokens", batchAmount(metrics.input_tokens, metrics.output_tokens),
        metrics.reported > 0 ? `${count(metrics.input_tokens)} input · ${count(metrics.output_tokens)} output` : "No provider counts in this period"),
      metric("Saved reviews", metrics.review_count, "Local and published verdicts")
    );
    content.append(totals);

    const series = list(metrics.series);
    const daily = element("section", "panel chart-panel");
    const title = element("header", "section-heading");
    title.append(element("h2", null, "Daily activity"));
    const chooser = element("select");
    chooser.setAttribute("aria-label", "Daily activity metric");
    for (const [value, label] of [["calls", "Model calls"], ["tokens", "Reported tokens"]]) {
      const option = element("option", null, label);
      option.value = value;
      chooser.append(option);
    }
    chooser.value = displayChart;
    title.append(chooser);
    daily.append(title);
    const chart = element("canvas", "chart-canvas");
    chart.setAttribute("role", "img");
    const explanation = element("p", "chart-guide");
    const refreshChart = () => {
      const tokens = displayChart === "tokens";
      const empty = tokens ? !series.some((point) => point.input_tokens > 0 || point.output_tokens > 0) : !series.some((point) => point.attempts > 0);
      chart.setAttribute("aria-label", tokens ? "Reported input and output tokens by UTC day" : "Model calls and token reports by UTC day");
      explanation.textContent = empty ? (tokens ? "No reported token totals in this period." : "No model calls in this period.") :
        tokens ? "Light bars show input tokens. Dark sections show output tokens. Days are UTC." :
          "Bars show calls. Light sections show calls with token counts. Days are UTC.";
      chart.hidden = empty;
      if (!empty) drawChart(chart, series);
    };
    chooser.addEventListener("change", () => {
      displayChart = chooser.value;
      refreshChart();
    });
    daily.append(chart, explanation);
    if (series.length) {
      const details = element("details");
      details.append(element("summary", null, "View daily totals"));
      details.append(tableBox(renderTable(["UTC day", ["Calls", "numeric"], ["Token reports", "numeric"], ["Input tokens", "numeric"], ["Output tokens", "numeric"]],
        series.map((point) => [chartDay(point.day), count(point.attempts), count(point.reported), count(point.input_tokens), count(point.output_tokens)]),
        "No daily activity.")));
      daily.append(details);
    }
    content.append(daily);

    const providers = element("section");
    const providerTitle = element("header", "section-heading");
    providerTitle.append(element("h2", null, "CLI calls by invocation profile"));
    providers.append(providerTitle, tableBox(renderTable([
      "Provider / model", ["Calls", "numeric"], ["Failures", "numeric"], ["Token reports", "numeric"],
      ["Input tokens", "numeric"], ["Output tokens", "numeric"], ["Mean duration", "numeric"],
    ], list(metrics.providers).map((item) => [
      phrase([humanize(item.engine), item.model]), count(item.attempts), count(item.failures),
      `${count(item.reported)} / ${count(item.attempts)}`,
      count(item.input_tokens), count(item.output_tokens), duration(item.mean_duration_ms),
    ]), "Provider calls will appear here as they finish.")));
    content.append(providers);

    const modelUsage = list(metrics.models);
    if (modelUsage.length) {
      const models = element("section", "subsection");
      const heading = element("header", "section-heading");
      heading.append(element("h2", null, "Reported model usage"));
      models.append(heading, tableBox(renderTable([
        "Provider / model", ["Calls involving model", "numeric"], ["Input tokens", "numeric"], ["Output tokens", "numeric"],
      ], modelUsage.map((model) => [
        phrase([humanize(model.engine), model.model]), count(model.participations), count(model.input_tokens), count(model.output_tokens),
      ]), "No model-specific counts.")));
      models.append(element("p", "chart-guide", "A CLI call can use more than one model."));
      content.append(models);
    }

    const ancillary = [
      ["Cached input", metrics.cached_input_tokens],
      ["Cache write input", metrics.cache_write_input_tokens],
      ["Reasoning output", metrics.reasoning_output_tokens],
    ].filter(([, value]) => Number.isFinite(value));
    if (ancillary.length) {
      content.append(element("p", "chart-guide", phrase(ancillary.map(([name, value]) => `${name} ${count(value)}`))));
    }

    const splits = [
      { label: "Review stages", list: list(metrics.stages), name: "stage", value: "attempts" },
      { label: "Review depth", list: list(metrics.routes), name: "route", value: "count" },
      { label: "Review mode", list: list(metrics.modes), name: "mode", value: "count" },
    ];
    const group = element("div", "metrics-splits");
    for (const split of splits) {
      if (!split.list.length) continue;
      const panel = element("section");
      const header = element("header", "section-heading");
      header.append(element("h2", null, split.label));
      panel.append(header, tableBox(renderTable(["Type", ["Count", "numeric"]], split.list.map((item) => [
        humanize(item[split.name]), count(item[split.value] ?? item.attempts),
      ]), "No matching activity.")));
      group.append(panel);
    }
    if (group.childElementCount) content.append(group);
    byId("metrics-results").replaceChildren(content);
    refreshChart();
    chartObserver = new ResizeObserver(refreshChart);
    chartObserver.observe(chart);
  });
}

function reviewVerdict(result, target) {
  if (!result || !target.head) return result;
  const all = [result, ...list(result.history)];
  if (target.reviewId != null) {
    const exact = all.find((candidate) => candidate.explanation?.github_review_id === target.reviewId);
    if (exact) return exact;
  }
  return all.find((candidate) => candidate.commit_id === target.head && candidate.explanation?.at === target.at) ||
    all.find((candidate) => candidate.commit_id === target.head) || null;
}

function renderCoverage(coverage, blockers) {
  const section = element("section", "detail-section");
  section.append(element("h3", null, coverage.complete ? "Coverage complete" : "Coverage limited"));
  const gaps = [...list(coverage.snapshot_reasons), ...list(coverage.historical_reasons)];
  if (coverage.supplemental_limited) gaps.push("Some requested source excerpts were unavailable or exceeded the evidence budget.");
  if (coverage.truncated_open_threads > 0) gaps.push(plural(coverage.truncated_open_threads, "truncated open thread"));
  if (coverage.unassessed_thread) {
    const thread = coverage.unassessed_thread;
    gaps.push(phrase([humanize(thread.engine), "Unassessed thread", thread.path && `${thread.path}${thread.line ? `:${thread.line}` : ""}`]));
  }
  for (const provider of list(coverage.reviewers)) {
    for (const gap of list(provider.gaps)) gaps.push(phrase([humanize(provider.engine), gap]));
  }
  if (gaps.length) {
    const entries = element("ul", "coverage-list");
    for (const gap of new Set(gaps)) entries.append(element("li", null, gap));
    section.append(entries);
  }
  if (blockers.length) section.append(element("p", "chart-guide", `Approval blockers · ${blockers.map(humanize).join(", ")}`));
  return section;
}

function usagePhrase(data) {
  const total = batchAmount(data?.input_tokens, data?.output_tokens);
  return phrase([
    plural(data?.attempts ?? 0, "call"),
    total != null && `${count(total)} reported tokens`,
    `${count(data?.reported ?? 0)} with token counts`,
  ]);
}

function renderDetail(data, target) {
  const holder = document.createDocumentFragment();
  const job = data.job;
  const result = reviewVerdict(data.result, target);
  const top = element("div", "detail-heading");
  const jobsLabel = job ? phaseLabel(chooseStage(job, snapshot?.at || Math.floor(Date.now() / 1000))) :
    element("span", "minor", data.tracked ? "Tracked" : "No queue entry");
  const link = gitHubLink(target.repo, target.number, result?.explanation?.github_review_id);
  top.append(jobsLabel);
  if (link) top.append(link);
  holder.append(top);

  if (job) {
    const details = element("div", "detail-meta");
    details.append(element("span", "mono", job.head?.slice(0, 10) || "—"));
    if (job.draft) details.append(element("span", null, "Draft"));
    if (job.stack) details.append(element("span", null, `Stack #${job.stack}`));
    if (job.all_models) details.append(element("span", null, "All models"));
    if (job.attempts > 0) details.append(element("span", null, plural(job.attempts, "retry", "retries")));
    holder.append(details);
    if (Number.isFinite(job.percent) || job.total_sections > 0) holder.append(progressLabel(job));
    const active = list(job.active_providers);
    if (active.length) holder.append(providersLabel(active, job.all_models));
  }

  if (result) {
    const section = element("section", "detail-section");
    const explanation = result.explanation;
    const status = historyStatus({ ...result, publication: explanation?.publication });
    const older = job?.head && job.head !== result.commit_id;
    section.append(element("h3", null, older ? "Previous saved verdict" : "Saved verdict"));
    section.append(element("p", "detail-meta", phrase([
      status, result.commit_id?.slice(0, 10), humanize(explanation?.route), explanation?.at && date(explanation.at),
    ])));
    if (result.body) section.append(element("p", "detail-body-text", result.body));
    else if (!Object.hasOwn(result, "body")) section.append(element("p", "chart-guide", "This earlier verdict retains its summary only."));
    for (const comment of list(result.comments)) {
      const item = element("div", "finding");
      item.append(element("p", "finding-location", `${comment.path}${comment.line ? `:${comment.line}` : ""}`));
      item.append(element("p", "detail-body-text", comment.body));
      section.append(item);
    }
    holder.append(section);
    if (explanation?.coverage) holder.append(renderCoverage(explanation.coverage, list(explanation.blockers)));
  } else {
    const section = element("section", "detail-section");
    section.append(element("h3", null, "Saved verdict"),
      element("p", "minor", target.head ? "No retained verdict for this selection." : "No saved verdict yet."));
    holder.append(section);
  }

  const groups = list(data.review_usage);
  const attempts = list(data.attempts);
  if (data.usage?.attempts > 0 || groups.length || attempts.length) {
    const exactHead = target.head || job?.head || result?.commit_id;
    const exactKey = result && result.commit_id === exactHead ? result.explanation?.followup_id : null;
    const headUsage = groups.filter((group) => group.head === exactHead);
    const current = exactKey != null ? headUsage.find((group) => group.review_key === exactKey) :
      headUsage.length === 1 ? headUsage[0] : null;
    const section = element("section", "detail-section");
    section.append(element("h3", null, "Reviewer usage"));
    if (data.usage?.attempts > 0) section.append(element("p", "detail-meta", `All heads · ${usagePhrase(data.usage)}`));
    if (current) section.append(element("p", "detail-meta", `Selected review · ${usagePhrase(current.totals)}`));
    if (groups.length > 1 || (!current && groups.length)) {
      const revisions = element("details", "detail-section");
      revisions.append(element("summary", null, "Review runs"));
      revisions.append(tableBox(renderTable(["Head / mode", ["Calls", "numeric"], ["Token reports", "numeric"], ["Reported tokens", "numeric"]], groups.map((group) => [
        phrase([group.head?.slice(0, 10), humanize(group.mode), date(group.at)]), count(group.totals?.attempts),
        count(group.totals?.reported), count(batchAmount(group.totals?.input_tokens, group.totals?.output_tokens)),
      ]), "No recorded runs.")));
      section.append(revisions);
    }

    const relevant = attempts.filter((item) => {
      if (!target.head || !item.head) return true;
      return item.head === target.head && (exactKey == null || item.review_key === exactKey);
    });
    if (relevant.length > 0) {
      const table = tableBox(renderTable(["Provider / stage", ["Duration", "numeric"], ["Input", "numeric"], ["Output", "numeric"]], relevant.map((item) => {
        const info = element("div");
        info.append(element("span", null, phrase([humanize(item.engine), item.model])));
        info.append(element("span", "phase-note", phrase([humanize(item.stage), item.section != null && `Section ${item.section}`, humanize(item.outcome)])));
        const models = list(item.model_usage);
        if (models.length > 1 || (models.length === 1 && models[0].model !== item.model)) {
          for (const model of models) {
            const tokens = model.tokens;
            const usage = Number.isFinite(tokens?.input) || Number.isFinite(tokens?.output) ?
              `${count(tokens.input)} in / ${count(tokens.output)} out` : "";
            info.append(element("span", "phase-note", phrase([model.model, usage])));
          }
        }
        return [info, duration(item.duration_ms), count(item.tokens?.input), count(item.tokens?.output)];
      }), "No model calls for this review."));
      table.classList.add("detail-section");
      section.append(table);
    }
    holder.append(section);
  }
  const container = byId("detail-body");
  const scroll = container.scrollTop;
  container.replaceChildren(holder);
  container.scrollTop = scroll;
}

function refreshDetail() {
  if (!detailSelection || !byId("review-dialog").open || detailRequest?.selection === detailSelection) return;
  const selection = detailSelection;
  const params = new URLSearchParams({ repo: selection.repo, number: String(selection.number) });
  const flight = { selection };
  detailRequest = flight;
  request(`/api/review?${params}`).then((data) => {
    if (detailSelection !== selection) return;
    update("detail", data, () => renderDetail(data, selection));
  }).catch((error) => {
    if (detailSelection !== selection) return;
    renderKeys.delete("detail");
    byId("detail-body").replaceChildren(element("p", "notice", error.message));
  }).finally(() => {
    if (detailRequest === flight) detailRequest = null;
  });
}

function openReview(repo, number, head = null, at = null, reviewId = null) {
  if (!repoPattern.test(repo) || !validNumber(number)) return;
  detailSelection = { repo, number, head, at, reviewId };
  renderKeys.delete("detail");
  byId("detail-repo").textContent = repo;
  byId("detail-title").textContent = `Pull request #${number}`;
  byId("detail-body").replaceChildren(element("p", "minor", "Loading review…"));
  const dialog = byId("review-dialog");
  if (!dialog.open) dialog.showModal();
  refreshDetail();
}

function queueTarget() {
  const parsed = parseTarget(byId("queue-target").value);
  if (!parsed) return null;
  const fallback = !parsed.repo;
  const repo = parsed.repo || byId("queue-repo").value;
  return { ...parsed, fallback, repo, kind: parsed.kind || (fallback ? byId("queue-form").elements.kind.value : "pr") };
}

function lookupKey(target) {
  return target?.kind === "pr" && repoPattern.test(target.repo) ? keyOf(target.repo.toLowerCase(), target.number) : null;
}

function renderQueueTarget() {
  const target = queueTarget();
  const valid = target && repoPattern.test(target.repo);
  const key = lookupKey(target);
  const matching = key && queueLookup?.key === key ? queueLookup : null;
  const primary = byId("queue-submit");
  const stack = byId("queue-stack-submit");
  const status = byId("queue-target-status");
  const suggestion = validNumber(matching?.stack);
  const soleRepo = list(snapshot?.repos).length === 1 && byId("queue-repo").value;
  byId("queue-repo-field").hidden = !target?.fallback || Boolean(soleRepo);
  byId("queue-kind-field").hidden = !target?.fallback;
  const action = valid ? `Queue ${target.kind === "stack" ? "stack" : "PR"} #${target.number}` : "Queue review";
  primary.textContent = queueSending?.wholeStack === false ? "Queueing…" : action;
  primary.disabled = Boolean(queueSending);
  stack.hidden = !suggestion;
  stack.textContent = queueSending?.wholeStack ? "Queueing…" : suggestion ? `Queue whole stack #${matching.stack}` : "Queue whole stack";
  stack.disabled = Boolean(queueSending);
  if (matching?.state === "waiting") note(status, "Checking stack membership…");
  else if (matching?.state === "unavailable") note(status, "Stack membership unavailable.");
  else note(status, "");
}

function syncTarget(refreshMembership = false) {
  const target = queueTarget();
  const key = lookupKey(target);
  if (!refreshMembership && key === (queueLookup?.key ?? null)) {
    renderQueueTarget();
    return;
  }
  if (queueLookup) {
    clearTimeout(queueLookup.timer);
    queueLookup.controller.abort();
  }
  queueLookup = null;
  if (key) {
    const lookup = { key, state: "waiting", stack: null, controller: new AbortController(), timer: null };
    queueLookup = lookup;
    const query = new URLSearchParams({ repo: target.repo, number: String(target.number) });
    lookup.timer = setTimeout(async () => {
      try {
        const result = await request(`/api/queue-target?${query}`, {
          headers: { "X-Talos-Request": "1" },
          signal: lookup.controller.signal,
        });
        if (queueLookup !== lookup) return;
        lookup.stack = validNumber(result.stack_number) ? result.stack_number : null;
        lookup.state = "done";
      } catch {
        if (queueLookup !== lookup) return;
        lookup.state = "unavailable";
      }
      renderQueueTarget();
    }, 300);
  }
  renderQueueTarget();
}

function queueInputChanged() {
  note(byId("queue-message"), "");
  syncTarget();
}

function queuePayload(target, wholeStack, form) {
  if (!target) return;
  const payload = { repo: target.repo, number: target.number, kind: target.kind, all_models: form.elements.all_models.checked };
  if (form.elements.mode.value) payload.mode = form.elements.mode.value;
  if (wholeStack) {
    const key = lookupKey(target);
    if (!key || queueLookup?.key !== key || !validNumber(queueLookup.stack)) return;
    payload.number = queueLookup.stack;
    payload.kind = "stack";
    payload.member = target.number;
  }
  return payload;
}

function findPull(event) {
  event.preventDefault();
  const target = parseTarget(byId("queue-search").value);
  const holder = byId("find-message");
  if (target?.kind === "stack") {
    note(holder, "Find PR opens a pull request. Active stacks are listed below.");
    return;
  }
  if (target?.repo) {
    note(holder, "");
    openReview(target.repo, target.number);
    return;
  }
  const matches = filterRows(list(snapshot?.jobs), byId("queue-search").value);
  if (matches.length === 1) {
    note(holder, "");
    openReview(matches[0].repo, matches[0].number);
    return;
  }
  if (target && !matches.length && byId("queue-repo").value) {
    note(holder, "");
    openReview(byId("queue-repo").value, target.number);
    return;
  }
  note(holder, "Enter a GitHub PR link or a repository and PR number to open its details.");
}

async function queueReview(event) {
  event.preventDefault();
  const form = byId("queue-form");
  const input = byId("queue-target");
  const message = byId("queue-message");
  if (queueSending) return;
  const target = queueTarget();
  if (!target || !repoPattern.test(target.repo)) {
    note(message, "Enter a GitHub link or select a repository and enter a number.", "error");
    return;
  }
  const wholeStack = event.submitter === byId("queue-stack-submit");
  const payload = queuePayload(target, wholeStack, form);
  if (!payload) {
    note(message, "Select a current stack to queue.", "error");
    syncTarget();
    return;
  }
  queueSending = { wholeStack };
  for (const control of form.elements) control.disabled = true;
  renderQueueTarget();
  note(message, "");
  try {
    const queued = await request("/api/queue", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Talos-Request": "1" },
      body: JSON.stringify(payload),
    });
    const description = payload.kind === "stack" ? `Stack #${payload.number}` : `#${payload.number}`;
    note(message, queued.message || `Queued ${description} in ${payload.repo}.`);
    input.value = "";
    syncTarget();
    await refreshState();
  } catch (error) {
    note(message, error.message, "error");
    if (wholeStack && error.status === 409) syncTarget(true);
  } finally {
    queueSending = null;
    for (const control of form.elements) control.disabled = false;
    renderQueueTarget();
  }
}

let historySnapshot = null;

function refreshState() {
  const wantsHistory = view === "history";
  if (stateRequest?.history === wantsHistory) return stateRequest.promise;
  const flight = { history: wantsHistory, promise: null };
  stateRequest = flight;
  const path = wantsHistory ? "/api/state?history=1" : "/api/state";
  flight.promise = request(path).then((data) => {
    if (stateRequest !== flight) return;
    snapshot = data;
    if (wantsHistory) historySnapshot = list(data.history);
    setConnection(true);
    if (view === "queue") {
      renderQueue();
      renderRepos();
    }
    if (view === "history") renderHistory();
  }).catch(() => {
    if (stateRequest !== flight) return;
    setConnection(false, snapshot ? "Connection lost. Showing the last saved dashboard state." : "Talos could not be reached. Retrying shortly.");
  }).finally(() => {
    if (stateRequest === flight) stateRequest = null;
  });
  return flight.promise;
}

function refreshMetrics() {
  const days = Number(byId("metrics-range").value);
  if (metricsRequest?.days === days) return;
  const flight = { days };
  metricsRequest = flight;
  if (metricsSnapshot?.days !== days) note(byId("metrics-notice"), "Loading usage…");
  request(`/api/metrics?days=${days}`).then((data) => {
    if (metricsRequest !== flight || view !== "usage") return;
    metricsSnapshot = data;
    if (data.truncated) note(byId("metrics-notice"), "This range exceeds the history query limit. Choose a shorter range or use the Talos CLI to query an older period.");
    else note(byId("metrics-notice"), "");
    renderMetrics();
  }).catch((error) => {
    if (metricsRequest !== flight || view !== "usage") return;
    note(byId("metrics-notice"), error.message);
  }).finally(() => {
    if (metricsRequest === flight) metricsRequest = null;
  });
}

function poll() {
  clearTimeout(pollTimer);
  if (document.hidden) return;
  refreshState();
  if (view === "usage") refreshMetrics();
  refreshDetail();
  const interval = view === "usage" ? 20000 : view === "history" ? 12000 : 6000;
  pollTimer = setTimeout(poll, detailSelection ? Math.min(interval, 6000) : interval);
}

function navigate() {
  const hash = window.location.hash.slice(1);
  if (views.has(hash)) view = hash;
  for (const name of views) byId(`${name}-view`).hidden = view !== name;
  for (const link of document.querySelectorAll("[data-view]")) {
    if (link.dataset.view === view) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  if (view === "queue") {
    renderQueue();
    renderRepos();
  } else if (view === "history") {
    renderHistory();
  } else {
    renderMetrics();
  }
  poll();
}

byId("find-form").addEventListener("submit", findPull);
byId("queue-search").addEventListener("input", () => {
  note(byId("find-message"), "");
  renderQueue();
});
byId("queue-filter").addEventListener("change", renderQueue);
byId("queue-form").addEventListener("submit", queueReview);
byId("queue-target").addEventListener("input", queueInputChanged);
byId("queue-repo").addEventListener("change", queueInputChanged);
byId("queue-kind-field").addEventListener("change", queueInputChanged);
byId("history-search").addEventListener("input", renderHistory);
byId("history-filter").addEventListener("change", renderHistory);
byId("metrics-range").addEventListener("change", refreshMetrics);
byId("review-dialog").addEventListener("close", () => {
  detailSelection = null;
  renderKeys.delete("detail");
});
window.addEventListener("hashchange", navigate);
document.addEventListener("visibilitychange", poll);
navigate();
