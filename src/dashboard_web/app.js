"use strict";

const byId = (id) => document.getElementById(id);
const list = (value) => Array.isArray(value) ? value : [];
const numbers = new Intl.NumberFormat();
const dates = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
const shortDays = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", timeZone: "UTC" });
const repoPattern = /^[a-z0-9_.-]+\/[a-z0-9_.-]+$/i;
const views = new Set(["queue", "history", "followups", "usage"]);
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
  preview: "Preview",
  success: "Finished",
  interrupted: "Interrupted",
  timed_out: "Timed out",
  rate_limited: "Rate limited",
  no_material_change: "No material change",
  repeated_finding: "Finding already reported",
  already_published: "Already published",
  ready_to_publish: "Publication pending",
  repository_policy: "Repository publishing policy",
  own_pr: "Self approval excluded",
  unknown_author: "PR author could not be verified",
  insufficient_evidence: "Insufficient evidence",
};

let view = "queue";
let snapshot = null;
let stateUnavailable = false;
let stateRequest = null;
let metricsRequest = null;
let metricsSnapshot = null;
let detailSelection = null;
let detailRequest = null;
let displayChart = "calls";
let chartObserver = null;
let pollTimer = null;
let refreshIndicatorTimer = null;
let tooltipAnchor = null;
let tooltipTimer = null;
let tooltipClock = null;
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
  if (tooltipAnchor && container.contains(tooltipAnchor)) hideTooltip();
  const focus = document.activeElement;
  const key = container.contains(focus) ? focus?.dataset?.reviewKey : null;
  const opened = new Set([...container.querySelectorAll("details[data-detail-id][open]")].map((item) => item.dataset.detailId));
  for (const item of content.querySelectorAll("details[data-detail-id]")) item.open = opened.has(item.dataset.detailId);
  container.replaceChildren(content);
  if (key) {
    const next = Array.from(container.querySelectorAll("[data-review-key]")).find((node) => node.dataset.reviewKey === key);
    next?.focus({ preventScroll: true });
  }
}

function hideTooltip() {
  clearTimeout(tooltipTimer);
  clearInterval(tooltipClock);
  tooltipAnchor?.removeAttribute("aria-describedby");
  tooltipAnchor = null;
  byId("dashboard-tooltip").hidden = true;
}

function revealTooltip(anchor, title, rows, point = null) {
  hideTooltip();
  const tip = byId("dashboard-tooltip");
  tip.classList.toggle("progress-tooltip", anchor.classList.contains("job-progress"));
  const grid = element("dl");
  const liveRows = [];
  const now = Date.now();
  for (const [name, value] of rows) {
    const live = typeof value === "function";
    const text = live ? value(now) : value;
    if (!text) continue;
    const detail = element("dd", null, text);
    grid.append(element("dt", null, name), detail);
    if (live) liveRows.push([detail, value]);
  }
  tip.replaceChildren(element("strong", null, title), grid);
  tip.hidden = false;
  const position = () => {
    const rect = anchor.getBoundingClientRect();
    const edge = 8;
    const left = Math.max(edge, Math.min(point?.x ?? rect.left, document.documentElement.clientWidth - tip.offsetWidth - edge));
    const below = (point?.y ?? rect.bottom) + edge;
    const top = below + tip.offsetHeight <= window.innerHeight - edge ? below : (point?.y ?? rect.top) - tip.offsetHeight - edge;
    tip.style.left = `${left}px`;
    tip.style.top = `${Math.max(edge, top)}px`;
  };
  position();
  tooltipAnchor = anchor;
  anchor.setAttribute("aria-describedby", tip.id);
  if (liveRows.length) tooltipClock = setInterval(() => {
    if (document.hidden) return;
    const tick = Date.now();
    for (const [detail, value] of liveRows) detail.textContent = value(tick);
    position();
  }, 1000);
}

function delayTooltipHide(anchor) {
  clearTimeout(tooltipTimer);
  tooltipTimer = setTimeout(() => {
    if (tooltipAnchor === anchor) hideTooltip();
  }, 130);
}

function tooltipFor(anchor, title, rows) {
  anchor.tabIndex = 0;
  const show = () => revealTooltip(anchor, title, rows);
  anchor.addEventListener("pointerenter", show);
  anchor.addEventListener("focus", show);
  anchor.addEventListener("pointerleave", () => delayTooltipHide(anchor));
  anchor.addEventListener("blur", () => delayTooltipHide(anchor));
  return anchor;
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

function syncRefreshIndicator() {
  clearTimeout(refreshIndicatorTimer);
  const indicator = byId("sync-state");
  if (stateRequest || metricsRequest) indicator.dataset.refreshing = "true";
  else refreshIndicatorTimer = setTimeout(() => { delete indicator.dataset.refreshing; }, 360);
}

function publicationStatus(verdict) {
  const transport = verdict?.publication;
  if (transport === "verified") return { key: "published", label: "Published", tone: "good" };
  if (transport === "pending") return { key: "pending", label: "Checking publication", tone: "warning" };
  if (transport !== "local") return { key: transport, label: humanize(transport) };
  const disposition = verdict.disposition || (verdict.complete === false ? "insufficient_evidence" : null);
  const reason = humanize(disposition) || "Original decision unavailable";
  if (!disposition || ["insufficient_evidence", "unknown_author"].includes(disposition)) {
    return { key: "local", label: "Local only", reason, tone: "warning" };
  }
  return { key: "skipped", label: "Decided not to publish", reason };
}

function chooseStage(job, now) {
  const active = list(job.active_providers);
  const stage = humanize(job.stage);
  const verdict = job.verdict;
  if (job.phase === "baseline") return { title: "Baselined" };
  if (job.phase === "complete") {
    const status = publicationStatus({ ...verdict, complete: verdict?.coverage_complete });
    return { title: status.label || "Review finished", tone: status.tone,
      detail: status.reason || phrase([status.key === "published" && humanize(verdict.event),
        verdict?.coverage_complete === false && "Limited coverage"]) };
  }
  if (job.phase === "failed") return { title: "Failed", tone: "error", detail: humanize(job.last_error) };
  if (active.length) {
    const shared = [...new Set(active.map((provider) => humanize(provider.stage)).filter(Boolean))];
    return { title: "Running", tone: "active", detail: shared.length === 1 ? shared[0] : "Multiple passes" };
  }
  if (job.wait === "stack_publication") {
    return { title: "Waiting to publish", detail: job.blocked_by ? `Depends on #${job.blocked_by}` : "Pinned heads changed" };
  }
  if (job.blocked_by) return { title: "Waiting for stack", detail: `Depends on #${job.blocked_by}` };
  if (job.wait === "stack") return { title: "Waiting for stack", detail: "Pinned heads changed" };
  if (job.wait === "receipt_exhausted") {
    return { title: "Publication unconfirmed", tone: "warning", detail: "Retries exhausted" };
  }
  if (job.wait === "paused" || stage === "Paused" || snapshot?.repos?.some((repo) => sameRepo(repo.name, job.repo) && repo.paused)) {
    return { title: "Paused", tone: "warning" };
  }
  const eligible = job.eligible_at ?? job.next_at;
  if (job.phase === "uncertain") {
    return { title: "Checking publication", tone: "warning", detail: eligible > now ? `Next check ${date(eligible)}` : "" };
  }
  if (job.wait === "more_providers") return { title: "Needs another provider", tone: "warning" };
  if (job.wait === "unavailable") return { title: "Waiting for reviewer", tone: "warning" };
  if (eligible > now) {
    const delay = job.wait === "github_cooldown" ? "GitHub cooldown" :
      job.wait === "provider_cooldown" ? "Reviewer cooldown" : job.attempts > 0 ? "Retry scheduled" : "Scheduled";
    return { title: delay, tone: "warning", detail: date(eligible) };
  }
  return { title: stage && stage !== "Pending" ? stage : "Queued", detail: job.attempts > 0 ? humanize(job.last_error) : "" };
}

function phaseLabel(status) {
  const output = element("div");
  const main = element("span", "phase-text", status.title);
  main.dataset.tone = status.tone || "";
  output.append(main);
  if (status.detail) output.append(element("span", "phase-note", status.detail));
  return output;
}

function progressLabel(job, inspect = true) {
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
    const track = element("div", "progress-track");
    const bar = element("progress");
    bar.value = percent;
    bar.max = 100;
    bar.setAttribute("aria-label", `Planned diff sections reviewed for #${job.number}`);
    track.append(bar);
    if (percent > 0 && percent < 100 && list(job.active_providers).length > 0) {
      const shimmer = element("span", "progress-shimmer");
      shimmer.setAttribute("aria-hidden", "true");
      shimmer.style.width = `${percent}%`;
      track.append(shimmer);
    }
    wrap.append(track);
  }
  const active = list(job.active_providers);
  const recent = job.last_pass;
  if (inspect && (active.length || recent)) {
    const stage = (item) => phrase([item.section != null && `Section ${item.section}`, humanize(item.stage)]);
    wrap.dataset.reviewKey = `${keyOf(job.repo, job.number)}:${job.head}:progress`;
    return tooltipFor(wrap, `PR #${job.number}`, active.length ? active.map((item) => {
      const label = stage(item);
      return [
        item.model || humanize(item.engine),
        item.at > 0 ? (now) => phrase([label, `${duration(Math.max(0, now - item.at * 1000))} elapsed`]) : label,
      ];
    }) : [[
      `Last pass · ${recent.model || humanize(recent.engine)}`,
      phrase([stage(recent), Number.isFinite(recent.duration_ms) && duration(recent.duration_ms), humanize(recent.outcome)]),
    ]]);
  }
  return wrap;
}

const providerMarks = new Set(["codex", "claude", "kimi"]);

function providerLabel(engine, model, calls = 1, compact = false) {
  const hasIcon = providerMarks.has(engine);
  const name = humanize(engine);
  const label = element("span", compact ? "provider-label provider-compact" : "provider-label");
  if (hasIcon) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    const mark = document.createElementNS(svg.namespaceURI, "use");
    svg.setAttribute("class", "provider-icon");
    svg.setAttribute("aria-hidden", "true");
    mark.setAttribute("href", `/providers.svg#${engine}`);
    svg.append(mark);
    label.append(svg);
  }
  const quantity = calls > 1 ? ` ×${calls}` : "";
  const text = element("span", "provider-name");
  if (compact) label.title = phrase([name, model]);
  if (compact && hasIcon && model) {
    text.append(element("span", "sr-only", `${name} `), document.createTextNode(`${model}${quantity}`));
  } else {
    text.textContent = name + quantity;
    if (model) text.append(element("span", "provider-model", ` · ${model}`));
  }
  label.append(text);
  return label;
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
  for (const item of names.values()) group.append(providerLabel(item.engine, item.model, item.count, true));
  return group;
}

function reviewKey(item, head = null, showDetails = true, stack = null) {
  const wrap = element("div", "review-key");
  const label = element("button", "review-link", `#${item.number}`);
  label.type = "button";
  label.setAttribute("aria-label", `Review details for ${item.repo} #${item.number}`);
  label.dataset.reviewKey = phrase([keyOf(item.repo, item.number), head, item.at]);
  label.addEventListener("click", () => openReview(item.repo, item.number, head, item.at ?? null, item.review_id ?? null, item.review_key ?? null));
  if (showDetails && item.title) {
    const line = element("div", "review-keyline");
    line.append(label, element("span", "review-title", item.title));
    wrap.append(line);
  } else wrap.append(label);
  if (showDetails) {
    const metadata = element("span", "review-repo", phrase([item.repo, item.draft && "Draft"]));
    if (stack) {
      const label = element("span", "stack-label", ` · ${stack.label}`);
      if (stack.position) {
        const badge = element("span", "stack-position", `${stack.position}/${stack.total}`);
        badge.title = `PR ${stack.position} of ${stack.total}, bottom to top`;
        badge.setAttribute("aria-hidden", "true");
        label.append(badge, element("span", "sr-only", `, ${badge.title}`));
      }
      metadata.append(label);
    }
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
    const members = list(stack.members);
    for (const [index, member] of members.entries()) {
      memberships.set(keyOf(stack.repo, member.number), { label, accent, position: index + 1, total: members.length });
    }
  }
  const active = jobs.filter((job) => !["baseline", "complete"].includes(job.phase));
  const running = active.filter((job) => list(job.active_providers).length > 0);
  const attention = active.filter((job) => job.phase === "failed" || ["receipt_exhausted", "more_providers"].includes(job.wait)).length;
  const pending = active.length - running.length - attention;
  const totals = [["Running", running.length], ["Waiting", pending], ["Attention", attention]];
  if (snapshot) update("queue-summary", totals, () => {
    byId("queue-summary").replaceChildren(...totals.map(([label, amount]) => {
      const field = element("span", "queue-stat");
      if (amount > 0) field.dataset.tone = label.toLowerCase();
      field.append(element("strong", "mono", count(amount)), element("span", null, label));
      return field;
    }));
  });
  const rows = byId("queue-filter").value === "active" ? active : jobs;
  const selected = filterRows(rows, byId("queue-search").value);
  const now = snapshot?.at || 0;
  const rank = (job) => {
    if (list(job.active_providers).length) return 0;
    if (job.phase === "pending") return job.blocked_by ? 3 : (job.eligible_at ?? job.next_at) > now ? 2 : 1;
    return { uncertain: 2, failed: 4, complete: 5, baseline: 6 }[job.phase] ?? 7;
  };
  const ordered = [...selected].sort((first, second) => rank(first) - rank(second) ||
    first.repo.localeCompare(second.repo) || second.number - first.number);
  const statuses = ordered.map((job) => [job, chooseStage(job, now), memberships.get(keyOf(job.repo, job.number)) ||
    (job.stack ? { label: `Stack #${job.stack}`, accent: stackAccent(job.repo, job.stack) } : null)]);
  const empty = snapshot ? (rows.length ? "No matching reviews." : "The review queue is empty.") :
    stateUnavailable ? "Queue unavailable. Retrying…" : "Loading queue…";
  update("queue", statuses.length ? statuses : [empty], () => {
    replace(byId("queue-results"), renderTable(["Pull request", "State", "Progress", "Reviewers"], statuses.map(([job, status, stack]) => [
      reviewKey(job, null, true, stack), phaseLabel(status), progressLabel(job), providersLabel(list(job.active_providers), job.all_models),
    ]), empty, statuses.map(([, , stack]) => stack ? `linked-row ${stack.accent}` : "")));
  });

  const activeKeys = new Set(active.map((job) => keyOf(job.repo, job.number)));
  const stackJobs = new Map(jobs.filter((job) => job.phase !== "uncertain").map((job) => [keyOf(job.repo, job.number), job]));
  const stacks = list(snapshot?.stacks).filter((stack) => list(stack.members).some((member) => activeKeys.has(keyOf(stack.repo, member.number))));
  byId("stacks-panel").hidden = !stacks.length;
  update("stacks", stacks.map((stack) => [stack, list(stack.members).map((member) => {
    const job = stackJobs.get(keyOf(stack.repo, member.number));
    return [job?.blocked_by, job?.publication_blocked_by, job?.wait];
  })]), () => {
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
        const job = stackJobs.get(keyOf(stack.repo, member.number));
        const state = phrase([humanize(member.phase), member.draft && "Draft",
          job?.publication_blocked_by && (!job.blocked_by || job.wait === "stack_publication") ?
            `Publish after #${job.publication_blocked_by}` :
            member.blocked_by && `Depends on #${member.blocked_by}`]);
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
  const rows = repos.map((repo) => ({ ...repo, label: repo.paused ? "Paused" : repo.scan_error === "GitHubIdentityFailed" ?
    "GitHub error" : repo.scan_attempts > 0 ? "Scan delayed" : repo.last_scan_at > 0 ?
    age(repo.last_scan_at, snapshot.at) : "Awaiting first scan" }));
  update("repos", rows, () => {
    const nodes = document.createDocumentFragment();
    for (const repo of rows) {
      const description = element("span", "repo-status", repo.label);
      if (repo.paused || repo.scan_attempts > 0) description.dataset.tone = "warning";
      description.title = phrase([
        repo.last_scan_at > 0 && `Last scan ${date(repo.last_scan_at)}`,
        repo.scan_error && humanize(repo.scan_error),
        repo.scan_attempts > 0 && repo.next_scan_at > 0 && `Next scan ${date(repo.next_scan_at)}`,
      ]);
      const item = element("li");
      const name = element("span", "repo-name", repo.name.split("/").at(-1));
      name.title = repo.name;
      item.append(name, description);
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
  const status = publicationStatus(row);
  return phrase([status.label || "Saved", status.key === "published" && humanize(row.event)]);
}

function historyVerdict(row) {
  const status = publicationStatus(row);
  const verdict = phaseLabel({ title: historyStatus(row), detail: status.reason, tone: status.tone });
  verdict.classList.add("inspectable");
  verdict.dataset.reviewKey = `${keyOf(row.repo, row.number)}:${row.head}:${row.at}:verdict`;
  return tooltipFor(verdict, `Verdict for #${row.number}`, [
    ["Head", row.head?.slice(0, 12)], ["Depth", humanize(row.route)],
    ["Coverage", row.complete === true ? "Complete" : row.complete === false ? "Limited" : "Unknown"],
    ["GitHub review", row.review_id ? `#${row.review_id}` : ""], ["Saved", date(row.at)],
  ]);
}

function renderHistory() {
  const history = list(historySnapshot);
  const desired = byId("history-filter").value;
  const filtered = filterRows(history, byId("history-search").value).filter((item) =>
    desired === "" || publicationStatus(item).key === desired);
  const ordered = [...filtered].sort((first, second) => second.at - first.at || second.number - first.number);
  byId("history-summary").textContent = history.length ?
    `${historyTruncated ? "Latest " : ""}${plural(history.length, "saved verdict")}` : "Saved verdicts";
  const empty = historySnapshot ? "No matching saved verdicts." :
    stateUnavailable ? "History unavailable. Retrying…" : "Loading saved verdicts…";
  update("history", ordered.length ? ordered : [empty], () => {
    replace(byId("history-results"), renderTable(["Pull request", "Verdict", "Depth", "Coverage", ["Saved", "time-cell"]], ordered.map((item) => [
      reviewKey(item, item.head), historyVerdict(item), humanize(item.route) || "—",
      item.complete === true ? "Complete" : item.complete === false ? "Limited" : "—", date(item.at),
    ]), empty));
  });
}

function renderFollowups() {
  const rows = list(snapshot?.followups);
  const empty = snapshot ? "No tracked follow-ups." : stateUnavailable ? "Follow-ups unavailable. Retrying…" : "Loading follow-ups…";
  update("followups", rows.length ? rows : [empty], () => {
    replace(byId("followup-results"), renderTable(["Source", "Follow-up PR", "State"], rows.map((row) => {
      const source = element("a", null, `${row.repo} #${row.source_pr}`);
      source.href = row.source_url;
      source.target = "_blank";
      source.rel = "noopener";
      return [source, row.draft ? gitHubLink(row.repo, row.draft) : "—",
        phaseLabel({ title: row.paused ? "Paused" : humanize(row.stage), detail: row.note })];
    }), empty));
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
  return { left, step, top, bottom };
}

function renderMetrics() {
  const metrics = metricsSnapshot;
  if (!metrics) return;
  const { through, ledger, ...display } = metrics;
  update("metrics", display, () => {
    chartObserver?.disconnect();
    const content = document.createDocumentFragment();
    const totals = element("div", "metric-grid");
    const observations = `${count(metrics.reported ?? 0)} of ${count(metrics.attempts ?? 0)} calls with token counts`;
    totals.append(
      metric("Model calls", metrics.attempts, observations),
      metric("Reported tokens", batchAmount(metrics.input_tokens, metrics.output_tokens),
        metrics.reported > 0 ? `${count(metrics.input_tokens)} input · ${count(metrics.output_tokens)} output` : "No provider counts in this period"),
      metric("Saved verdicts", metrics.review_count,
        Number.isFinite(metrics.review_published) ? `${count(metrics.review_published)} published` : "Local and published"),
      metric("Reviewed heads", metrics.reviewed_heads, metrics.coverage ?
        phrase([`${count(metrics.coverage.complete)} complete`, `${count(metrics.coverage.limited)} limited`,
          metrics.coverage.unknown > 0 && `${count(metrics.coverage.unknown)} unknown`]) : "")
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
    chart.tabIndex = 0;
    chart.dataset.reviewKey = "usage-chart";
    let geometry = null;
    let activeDay = -1;
    const showDay = (index) => {
      const point = series[index];
      if (!point || !geometry) return;
      const rect = chart.getBoundingClientRect();
      activeDay = index;
      revealTooltip(chart, `${chartDay(point.day)} UTC`, [
        ["Model calls", count(point.attempts)], ["Token reports", `${count(point.reported)} / ${count(point.attempts)}`],
        ["Input tokens", count(point.input_tokens)], ["Output tokens", count(point.output_tokens)],
      ], { x: rect.left + geometry.left + geometry.step * (index + .5), y: rect.top + geometry.top });
    };
    chart.addEventListener("pointermove", (event) => {
      if (!geometry) return;
      const rect = chart.getBoundingClientRect();
      const index = Math.floor((event.clientX - rect.left - geometry.left) / geometry.step);
      const y = event.clientY - rect.top;
      if (index < 0 || index >= series.length || y < geometry.top || y > geometry.bottom) {
        if (tooltipAnchor === chart) hideTooltip();
        return;
      }
      if (index !== activeDay || tooltipAnchor !== chart) showDay(index);
    });
    chart.addEventListener("pointerleave", () => delayTooltipHide(chart));
    chart.addEventListener("focus", () => showDay(activeDay < 0 ? series.length - 1 : activeDay));
    chart.addEventListener("blur", () => delayTooltipHide(chart));
    chart.addEventListener("keydown", (event) => {
      const steps = { ArrowLeft: -1, ArrowRight: 1 };
      if (!Object.hasOwn(steps, event.key)) return;
      event.preventDefault();
      showDay(Math.max(0, Math.min(series.length - 1, activeDay + steps[event.key])));
    });
    const explanation = element("p", "chart-guide");
    const refreshChart = () => {
      const tokens = displayChart === "tokens";
      const empty = tokens ? !series.some((point) => point.input_tokens > 0 || point.output_tokens > 0) : !series.some((point) => point.attempts > 0);
      chart.setAttribute("aria-label", `${tokens ? "Reported input and output tokens" : "Model calls and token reports"} by UTC day. Use the arrow keys to inspect days.`);
      explanation.textContent = empty ? (tokens ? "No reported token totals in this period." : "No model calls in this period.") :
        tokens ? "Light bars show input tokens. Dark sections show output tokens. Days are UTC." :
          "Bars show calls. Light sections show calls with token counts. Days are UTC.";
      chart.hidden = empty;
      geometry = empty ? null : drawChart(chart, series);
      if (document.activeElement === chart) showDay(activeDay < 0 ? series.length - 1 : activeDay);
    };
    chooser.addEventListener("change", () => {
      displayChart = chooser.value;
      refreshChart();
    });
    daily.append(chart, explanation);
    if (series.length) {
      const details = element("details");
      details.dataset.detailId = "daily-totals";
      const summary = element("summary", null, "View daily totals");
      summary.dataset.reviewKey = "daily-totals-summary";
      details.append(summary);
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
      ["Input tokens", "numeric"], ["Output tokens", "numeric"], ["Median / p95", "numeric"],
    ], list(metrics.providers).map((item) => [
      providerLabel(item.engine, item.model), count(item.attempts), count(item.failures),
      `${count(item.reported)} / ${count(item.attempts)}`,
      count(item.input_tokens), count(item.output_tokens), item.measured > 0 ?
        `${duration(item.p50_duration_ms)} / ${duration(item.p95_duration_ms)}` : "—",
    ]), "Provider calls will appear here as they finish.")));
    providers.append(element("p", "chart-guide", "Latency uses calls with recorded durations. Failures include rate limits, timeouts, and interrupted calls."));
    content.append(providers);

    const modelUsage = list(metrics.models);
    if (modelUsage.length) {
      const models = element("section", "subsection");
      const heading = element("header", "section-heading");
      heading.append(element("h2", null, "Reported model usage"));
      models.append(heading, tableBox(renderTable([
        "Provider / model", ["Calls involving model", "numeric"], ["Input tokens", "numeric"], ["Output tokens", "numeric"],
      ], modelUsage.map((model) => [
        providerLabel(model.engine, model.model), count(model.participations), count(model.input_tokens), count(model.output_tokens),
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
      { label: "CLI call outcomes", list: list(metrics.outcomes), name: "outcome", value: "attempts" },
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
    replace(byId("metrics-results"), content);
    refreshChart();
    chartObserver = new ResizeObserver(refreshChart);
    chartObserver.observe(chart);
  });
}

function reviewVerdict(result, target) {
  if (!result || !target.head) return result;
  const all = [result, ...list(result.history)];
  if (target.reviewId != null) {
    return all.find((candidate) => candidate.commit_id === target.head && candidate.explanation?.github_review_id === target.reviewId) || null;
  }
  return all.find((candidate) => candidate.commit_id === target.head &&
    (target.reviewKey == null || candidate.explanation?.followup_id === target.reviewKey) &&
    (target.at == null || candidate.explanation?.at === target.at || (candidate === result && !candidate.explanation))) || null;
}

function planSummary(plan) {
  return phrase([
    plan.scope === "discussion" && "Discussion follow-up",
    plan.scope === "publication" && "Ready for review",
    plan.required_source_units > 0 && plan.scope === "full" &&
      `${count(plan.planned_source_units)} of ${count(plan.required_source_units)} diff entries planned`,
    plan.reused_source_units > 0 && `${count(plan.reused_source_units)} reused`,
    plan.open_human_threads > 0 && plural(plan.open_human_threads, "open human thread"),
    plan.missing_changed_files > 0 && plural(plan.missing_changed_files, "changed file missing from the diff", "changed files missing from the diff"),
  ]);
}

function renderCoverage(coverage, blockers) {
  const section = element("section", "detail-section");
  section.append(element("h3", null, coverage.complete ? "Coverage complete" : "Coverage limited"));
  if (coverage.coverage_plan) {
    const summary = planSummary(coverage.coverage_plan);
    if (summary) section.append(element("p", "detail-meta", summary));
  }
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
  const link = gitHubLink(target.repo, target.number, result?.explanation?.github_review_id ?? target.reviewId);
  top.append(jobsLabel);
  if (link) top.append(link);
  holder.append(top);

  if (job) {
    const details = element("div", "detail-meta");
    details.append(element("span", "mono", job.head?.slice(0, 10) || "—"));
    if (job.draft) details.append(element("span", null, "Draft"));
    if (job.stack) details.append(element("span", null, `Stack #${job.stack}`));
    if (job.all_models) details.append(element("span", null, "All models"));
    if (job.route) details.append(element("span", null, humanize(job.route)));
    if (job.attempts > 0) details.append(element("span", null, plural(job.attempts, "retry", "retries")));
    holder.append(details);
    if (job.last_error && (job.phase === "failed" || job.attempts > 0)) {
      holder.append(element("p", "detail-note", phrase([humanize(job.last_error),
        job.last_error_at > 0 && date(job.last_error_at)])));
    }
    if (job.coverage_plan && !result?.explanation?.coverage?.coverage_plan) {
      const summary = planSummary(job.coverage_plan);
      if (summary) holder.append(element("p", "detail-note", summary));
    }
    if (job.publication_blocked_by && !job.blocked_by) {
      holder.append(element("p", "detail-note", `Publication waits on stack PR #${job.publication_blocked_by}.`));
    }
    if (Number.isFinite(job.percent) || job.total_sections > 0) holder.append(progressLabel(job, false));
    const active = list(job.active_providers);
    if (active.length) holder.append(providersLabel(active, job.all_models));
  }

  if (result) {
    const section = element("section", "detail-section");
    const explanation = result.explanation;
    const status = historyStatus({ ...result, publication: explanation?.publication,
      disposition: explanation?.disposition, complete: explanation?.coverage?.complete });
    const older = job?.head && (job.head !== result.commit_id ||
      (job.review_key || "") !== (result.explanation?.followup_id || ""));
    section.append(element("h3", null, older ? "Previous saved verdict" : "Saved verdict"));
    section.append(element("p", "detail-meta", phrase([
      status, result.commit_id?.slice(0, 10), humanize(explanation?.route), explanation?.at && date(explanation.at),
      explanation?.disposition !== "posted" && humanize(explanation?.disposition),
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
    section.append(element("h3", null, "Saved verdict"));
    const retained = target.head ? null : job?.verdict;
    if (retained) {
      section.append(element("p", "detail-meta", phrase([
        historyStatus(retained), retained.at && date(retained.at), humanize(retained.disposition),
      ])));
    } else {
      section.append(element("p", "minor", target.head ? "No retained verdict for this selection." : "No saved verdict yet."));
    }
    holder.append(section);
  }

  const groups = list(data.review_usage);
  const attempts = list(data.attempts);
  if (data.usage?.attempts > 0 || groups.length || attempts.length) {
    const exactHead = target.head || job?.head || result?.commit_id;
    const exactKey = target.head ?
      target.reviewKey ?? result?.explanation?.followup_id ?? "" :
      job?.review_key ?? result?.explanation?.followup_id ?? "";
    const headUsage = groups.filter((group) => group.head === exactHead);
    const current = headUsage.find((group) => (group.review_key || "") === exactKey && group.mode === "scheduled");
    const section = element("section", "detail-section");
    section.append(element("h3", null, "Reviewer usage"));
    if (data.activity_truncated) section.append(element("p", "chart-guide", "Showing the newest recorded activity."));
    if (data.usage?.attempts > 0) section.append(element("p", "detail-meta", `All heads · ${usagePhrase(data.usage)}`));
    if (current) section.append(element("p", "detail-meta", `Selected review · ${usagePhrase(current.totals)}`));
    if (groups.length > 1 || (!current && groups.length)) {
      const revisions = element("details", "detail-section");
      revisions.dataset.detailId = "runs";
      const summary = element("summary", null, "Review runs");
      summary.dataset.reviewKey = "review-run-summary";
      revisions.append(summary);
      revisions.append(tableBox(renderTable(["Head / mode", ["Calls", "numeric"], ["Token reports", "numeric"], ["Reported tokens", "numeric"]], groups.map((group) => [
        phrase([group.head?.slice(0, 10), humanize(group.mode), date(group.at)]), count(group.totals?.attempts),
        count(group.totals?.reported), count(batchAmount(group.totals?.input_tokens, group.totals?.output_tokens)),
      ]), "No recorded runs.")));
      section.append(revisions);
    }

    const relevant = attempts.filter((item) =>
      item.head === exactHead && (item.review_key || "") === exactKey && item.mode === "scheduled");
    if (relevant.length > 0) {
      const table = tableBox(renderTable(["Provider / stage", "Outcome", ["Started", "time-cell"], ["Duration", "numeric"], ["Input", "numeric"], ["Output", "numeric"]], relevant.map((item) => {
        const info = element("div");
        info.append(providerLabel(item.engine, item.model));
        info.append(element("span", "phase-note", phrase([humanize(item.stage), item.section != null && `Section ${item.section}`])));
        const outcome = phaseLabel({
          title: humanize(item.outcome),
          detail: item.error_name && humanize(item.error_name),
          tone: item.outcome === "running" ? "active" : item.outcome === "success" ? "" : "warning",
        });
        const models = list(item.model_usage);
        if (models.length > 1 || (models.length === 1 && models[0].model !== item.model)) {
          for (const model of models) {
            const tokens = model.tokens;
            const usage = Number.isFinite(tokens?.input) || Number.isFinite(tokens?.output) ?
              `${count(tokens.input)} in / ${count(tokens.output)} out` : "";
            info.append(element("span", "phase-note", phrase([model.model, usage])));
          }
        }
        return [info, outcome, date(item.at), duration(item.duration_ms), count(item.tokens?.input), count(item.tokens?.output)];
      }), "No model calls for this review."));
      table.classList.add("detail-section");
      section.append(table);
    }
    holder.append(section);
  }
  const container = byId("detail-body");
  const scroll = container.scrollTop;
  replace(container, holder);
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

function openReview(repo, number, head = null, at = null, reviewId = null, reviewKey = null) {
  if (!repoPattern.test(repo) || !validNumber(number)) return;
  detailSelection = { repo, number, head, at, reviewId, reviewKey };
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
  const modes = new FormData(form).getAll("mode");
  if (modes.length) payload.modes = modes;
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
let historyTruncated = false;

function refreshState() {
  const wantsHistory = view === "history";
  if (stateRequest?.history === wantsHistory) return stateRequest.promise;
  const flight = { history: wantsHistory, promise: null };
  stateRequest = flight;
  syncRefreshIndicator();
  const path = wantsHistory ? "/api/state?history=1" : "/api/state";
  flight.promise = request(path).then((data) => {
    if (stateRequest !== flight) return;
    snapshot = data;
    stateUnavailable = false;
    if (wantsHistory) {
      historySnapshot = list(data.history);
      historyTruncated = data.history_truncated === true;
    }
    setConnection(true);
    if (view === "queue") {
      renderQueue();
      renderRepos();
    }
    if (view === "history") renderHistory();
    if (view === "followups") renderFollowups();
  }).catch(() => {
    if (stateRequest !== flight) return;
    stateUnavailable = true;
    setConnection(false, snapshot ? "Connection lost. Showing the last saved dashboard state." : "Talos could not be reached. Retrying shortly.");
    if (view === "queue" && !snapshot) renderQueue();
    if (view === "history" && !historySnapshot) renderHistory();
    if (view === "followups" && !snapshot) renderFollowups();
  }).finally(() => {
    if (stateRequest === flight) {
      stateRequest = null;
      syncRefreshIndicator();
    }
  });
  return flight.promise;
}

function refreshMetrics() {
  const days = Number(byId("metrics-range").value);
  if (metricsRequest?.days === days) return;
  const flight = { days };
  metricsRequest = flight;
  syncRefreshIndicator();
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
    if (metricsRequest === flight) {
      metricsRequest = null;
      syncRefreshIndicator();
    }
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
  if (tooltipAnchor) hideTooltip();
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
  } else if (view === "followups") {
    renderFollowups();
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
byId("queue-focuses").addEventListener("change", ({ target, currentTarget }) => {
  if (!target.checked) return;
  for (const checked of currentTarget.querySelectorAll("input:checked")) {
    if (checked !== target && (checked.value === "general" || target.value === "general")) checked.checked = false;
  }
});
byId("history-search").addEventListener("input", renderHistory);
byId("history-filter").addEventListener("change", renderHistory);
byId("metrics-range").addEventListener("change", refreshMetrics);
byId("review-dialog").addEventListener("close", () => {
  detailSelection = null;
  renderKeys.delete("detail");
});
window.addEventListener("hashchange", navigate);
window.addEventListener("scroll", () => { if (tooltipAnchor) hideTooltip(); }, true);
window.addEventListener("resize", () => { if (tooltipAnchor) hideTooltip(); });
document.addEventListener("keydown", (event) => { if (event.key === "Escape" && tooltipAnchor) hideTooltip(); });
byId("dashboard-tooltip").addEventListener("pointerenter", () => clearTimeout(tooltipTimer));
byId("dashboard-tooltip").addEventListener("pointerleave", hideTooltip);
document.addEventListener("visibilitychange", poll);
navigate();
