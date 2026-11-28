const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");
const queue = @import("queue.zig");
const stack = @import("stack.zig");
const store = @import("store.zig");
const telemetry = @import("telemetry.zig");
const usage = @import("usage.zig");

const A = io.A;
const day_seconds = std.time.s_per_day;
const active_attempt_seconds = 35 * std.time.s_per_min;
const detail_days = 90;
const history_limit = 160;
const legacy_file_limit = 256;

const Attempt = struct {
    id: []const u8,
    engine: core.Engine,
    model: []const u8,
    stage: telemetry.Stage,
    section: ?usize,
    section_count: ?usize,
    at: i64,
    finished_at: ?i64,
    duration_ms: ?u64,
    outcome: []const u8,
    tokens: ?telemetry.Tokens,
    model_usage: []const telemetry.ModelUsage,
    repo: []const u8,
    number: u32,
    head: []const u8,
    review_key: ?[]const u8,
    mode: @FieldType(telemetry.Scope, "mode"),
    effort: core.ReviewEffort,
    error_name: ?[]const u8,
};

fn running(start: telemetry.Event, now: i64) bool {
    if (now -| start.at > active_attempt_seconds) return false;
    const pid = start.pid orelse return false;
    if (pid == 0 or pid > std.math.maxInt(std.posix.pid_t)) return false;
    std.posix.kill(@intCast(pid), 0) catch return false;
    return true;
}

fn pairAttempts(a: A, events: []const telemetry.Event, now: i64) ![]Attempt {
    const Pair = struct { start: ?telemetry.Event = null, finish: ?telemetry.Event = null };
    var pairs: std.StringArrayHashMapUnmanaged(Pair) = .empty;
    defer pairs.deinit(a);
    for (events) |event| {
        const slot = try pairs.getOrPut(a, event.id);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        switch (event.kind) {
            .started => if (slot.value_ptr.start == null) {
                slot.value_ptr.start = event;
            },
            .finished => if (slot.value_ptr.finish == null) {
                slot.value_ptr.finish = event;
            },
        }
    }
    const attempts = try a.alloc(Attempt, pairs.count());
    for (attempts, pairs.values()) |*row, pair| {
        const started = pair.start orelse pair.finish.?;
        const latest = pair.finish orelse started;
        row.* = .{
            .id = latest.id,
            .engine = latest.engine,
            .model = latest.model,
            .stage = latest.scope.stage,
            .section = latest.scope.section,
            .section_count = latest.scope.section_count,
            .at = started.at,
            .finished_at = if (pair.finish) |finish| finish.at else null,
            .duration_ms = latest.duration_ms,
            .outcome = if (latest.outcome) |outcome| @tagName(outcome) else if (pair.start != null and running(started, now)) "running" else "interrupted",
            .tokens = latest.tokens,
            .model_usage = latest.model_usage,
            .repo = latest.scope.repo,
            .number = latest.scope.pr,
            .head = latest.scope.head,
            .review_key = latest.scope.review_id,
            .mode = latest.scope.mode,
            .effort = latest.effort,
            .error_name = latest.error_name,
        };
    }
    std.mem.sort(Attempt, attempts, {}, struct {
        fn newer(_: void, left: Attempt, right: Attempt) bool {
            if (left.at != right.at) return left.at > right.at;
            return std.mem.order(u8, left.id, right.id) == .lt;
        }
    }.newer);
    return attempts;
}

const ActiveProvider = struct { engine: core.Engine, model: []const u8, stage: telemetry.Stage, section: ?usize, at: i64 };
const FinishedPass = struct {
    engine: core.Engine,
    model: []const u8,
    stage: telemetry.Stage,
    section: ?usize,
    finished_at: i64,
    duration_ms: ?u64,
    outcome: []const u8,
};
const JobWait = enum {
    paused,
    stack,
    stack_publication,
    retry,
    github_cooldown,
    provider_cooldown,
    more_providers,
    unavailable,
    receipt_exhausted,
};
const VerdictSummary = struct {
    event: core.Event,
    coverage_complete: ?bool,
    publication: []const u8,
    at: ?i64,
    github_review_id: ?u64,
    disposition: ?core.PublicationDisposition,
    coverage_plan: ?core.CoveragePlan,

    fn fromResult(event: core.Event, detail: ?core.Explanation) VerdictSummary {
        return .{
            .event = event,
            .coverage_complete = if (detail) |d| d.coverage.complete else null,
            .publication = if (detail) |d| @tagName(d.publication) else "local",
            .at = if (detail) |d| d.at else null,
            .github_review_id = if (detail) |d| d.github_review_id else null,
            .disposition = if (detail) |d| d.publicationReason() else null,
            .coverage_plan = if (detail) |d| d.coverage.coverage_plan else null,
        };
    }

    fn fromReceipt(receipt: core.VerdictReceipt) VerdictSummary {
        return .{
            .event = receipt.event,
            .coverage_complete = receipt.complete,
            .publication = @tagName(receipt.publication),
            .at = receipt.at,
            .github_review_id = receipt.github_review_id,
            .disposition = receipt.disposition,
            .coverage_plan = receipt.coverage_plan,
        };
    }
};
const Availability = struct {
    now: i64,
    paused: bool,
    budget: queue.Budget = .{},
    usage: usage.Snapshot = .{},
};
const JobRow = struct {
    repo: []const u8,
    number: u32,
    head: []const u8,
    title: []const u8,
    draft: bool,
    phase: []const u8,
    stage: []const u8,
    percent: ?usize,
    completed_sections: usize,
    total_sections: ?usize,
    active_providers: []const ActiveProvider,
    last_pass: ?FinishedPass,
    next_at: i64,
    eligible_at: ?i64,
    wait: ?JobWait,
    attempts: u8,
    last_error: ?[]const u8,
    last_error_at: ?i64,
    outcome: ?[]const u8,
    verdict: ?VerdictSummary,
    coverage_plan: ?core.CoveragePlan,
    review_key: ?[]const u8,
    route: ?@FieldType(core.Explanation, "route"),
    blocked_by: ?u32,
    publication_blocked_by: ?u32,
    all_models: bool,
    stack: ?u32,
};

fn jobRow(a: A, entry: core.Entry, number: u32, attempts: []const Attempt, availability: Availability, result: ?core.Result) !?JobRow {
    var seen: ?core.Seen = null;
    for (entry.seen) |pull| {
        if (pull.number == number) {
            seen = pull;
            break;
        }
    }
    var job: ?core.Job = null;
    for (entry.jobs) |candidate| {
        if (candidate.number != number) continue;
        if (seen) |pull| {
            if (io.eq(u8, candidate.head, pull.head)) {
                job = candidate;
                break;
            }
        }
        job = candidate;
    }
    if (job == null and seen == null) return null;
    var row = try buildJobRow(a, entry, job, seen, attempts, availability);
    if (row.verdict != null) return row;
    if (result) |saved| {
        const head = row.head;
        const run = row.review_key orelse "";
        // A just-started follow-up can share the head of the previous
        // verdict. Only attach metadata for this specific run.
        if (io.eq(u8, saved.commit_id, head) and io.eq(u8, saved.followupId(), run)) {
            if (saved.explanation == null or saved.explanation.?.publication != .preview) {
                row.verdict = VerdictSummary.fromResult(saved.event, saved.explanation);
            }
        } else {
            for (saved.history) |prior| {
                const detail = prior.explanation orelse continue;
                if (detail.publication == .preview or !io.eq(u8, prior.commit_id, head) or !io.eq(u8, detail.followup_id orelse "", run)) continue;
                row.verdict = VerdictSummary.fromResult(prior.event, detail);
                break;
            }
        }
    }
    return row;
}

fn buildJobRow(a: A, entry: core.Entry, job: ?core.Job, seen_: ?core.Seen, attempts: []const Attempt, availability: Availability) !JobRow {
    const now = availability.now;
    const seen = seen_ orelse core.Seen{ .number = job.?.number, .head = job.?.head };
    const ignored = entry.isIgnored(seen.number);
    const head = if (job) |current| current.head else seen.head;
    const review_key = if (job) |current| try core.followupId(a, current) else null;
    const progress = if (job) |current| current.route_progress else null;
    const report = if (job) |current| current.route_report else null;
    const verdict: ?VerdictSummary = if (job) |current| verdict: {
        if (current.verdict) |receipt| {
            if (io.eq(u8, receipt.head, head)) break :verdict VerdictSummary.fromReceipt(receipt);
        }
        break :verdict null;
    } else null;
    const plan = if (progress) |p|
        if (p.sections.checkpoint) |checkpoint| checkpoint.coverage_plan else null
    else if (verdict) |saved|
        saved.coverage_plan
    else
        null;
    const final_sections = if (report) |completed| completed.diff_sections else 0;
    const complete = if (progress) |p| p.sections.index else final_sections;
    var total: ?usize = null;
    if (final_sections != 0) total = final_sections;
    if (progress) |p| if (p.sections.checkpoint) |checkpoint| {
        total = checkpoint.section_count;
    };
    var active: std.ArrayList(ActiveProvider) = .empty;
    var last_pass: ?FinishedPass = null;
    if (job != null) {
        for (attempts) |attempt| {
            if (attempt.mode != .scheduled or
                !io.eq(u8, attempt.repo, entry.repo.name) or attempt.number != seen.number or !io.eq(u8, attempt.head, head)) continue;
            if (!io.eq(u8, attempt.review_key orelse "", review_key orelse "")) continue;
            if (attempt.finished_at) |finished_at| {
                if (last_pass == null or finished_at > last_pass.?.finished_at) last_pass = .{
                    .engine = attempt.engine,
                    .model = attempt.model,
                    .stage = attempt.stage,
                    .section = attempt.section,
                    .finished_at = finished_at,
                    .duration_ms = attempt.duration_ms,
                    .outcome = attempt.outcome,
                };
                continue;
            }
            if (ignored or job.?.phase != .pending or !io.eq(u8, attempt.outcome, "running")) continue;
            if (total == null) total = attempt.section_count;
            try active.append(a, .{ .engine = attempt.engine, .model = attempt.model, .stage = attempt.stage, .section = attempt.section, .at = attempt.at });
        }
    }
    var publication_blocked: ?u32 = null;
    var stack_number: ?u32 = null;
    if (stack.find(entry.stacks, seen.number)) |position| {
        const item = entry.stacks[position.stack_index];
        if (item.native) |native| stack_number = native.number;
        if (stack.blocker(entry, item, position.member_index)) |block| publication_blocked = block.number;
    }
    const stack_wait = if (job) |current| !ignored and current.phase == .pending and stack.analysisBlocked(entry, current) else false;
    const blocked = if (stack_wait) publication_blocked else null;
    var last_error: ?[]const u8 = null;
    var last_error_at: ?i64 = null;
    var errors = std.mem.reverseIterator(entry.errors);
    while (errors.next()) |entry_error| {
        if (entry_error.number == seen.number) {
            last_error = entry_error.detail;
            last_error_at = entry_error.at;
            break;
        }
    }
    const phase = if (ignored) "ignored" else if (job) |current| @tagName(current.phase) else "baseline";
    const eligible_at: ?i64 = if (job) |current|
        if (!availability.paused and active.items.len == 0) availability.budget.eligibleAt(entry, current, now, 0, availability.usage) else null
    else
        null;
    const wait: ?JobWait = wait: {
        if (ignored) break :wait null;
        const current = job orelse break :wait null;
        if (active.items.len != 0 or (current.phase != .pending and current.phase != .uncertain)) break :wait null;
        if (current.phase == .uncertain and !current.schedulable()) break :wait .receipt_exhausted;
        if (availability.paused) break :wait .paused;
        if (stack_wait) {
            if (current.analysis != null or (progress != null and progress.?.readyToPublish())) break :wait .stack_publication;
            break :wait .stack;
        }
        if (progress) |p| if (p.needsAnotherProvider(entry.repo)) break :wait .more_providers;
        const at = eligible_at orelse break :wait .unavailable;
        if (at <= now) break :wait null;
        if (at == current.next) break :wait .retry;
        if (at == availability.budget.github.until) break :wait .github_cooldown;
        break :wait .provider_cooldown;
    };
    const stage = stage: {
        if (ignored) break :stage "ignored";
        const current = job orelse break :stage "baseline";
        switch (current.phase) {
            .complete => break :stage "complete",
            .uncertain => break :stage "receipt",
            .failed => break :stage "failed",
            .pending => {},
        }
        if (active.items.len != 0) break :stage @tagName(active.items[0].stage);
        if (availability.paused) break :stage "paused";
        if (stack_wait) break :stage "blocked";
        if (current.next > now or (eligible_at != null and eligible_at.? > now)) break :stage "retry";
        if (current.analysis != null) break :stage "publishing";
        if (progress) |p| {
            if (p.readyToPublish()) break :stage "publishing";
            if (p.screen_waiting and p.decision == null) break :stage "screening";
            if (p.completion_requests != null and p.completion_requests.?.len != 0) break :stage "evidence";
            for (p.sections.pending) |task| {
                if (task.progress.completion_requests != null and task.progress.completion_requests.?.len != 0) break :stage "evidence";
            }
            break :stage "review";
        }
        break :stage "queued";
    };
    return .{
        .repo = entry.repo.name,
        .number = seen.number,
        .head = head,
        .title = seen.title,
        .draft = seen.is_draft,
        .phase = phase,
        .stage = stage,
        .percent = if (total) |count| if (count > 0) @intCast(@min(100, @as(u128, complete) * 100 / count)) else null else null,
        .completed_sections = complete,
        .total_sections = total,
        .active_providers = active.items,
        .last_pass = last_pass,
        .next_at = if (job) |current| current.next else 0,
        .eligible_at = eligible_at,
        .wait = wait,
        .attempts = if (job) |current| current.attempts else 0,
        .last_error = last_error,
        .last_error_at = last_error_at,
        .outcome = if (job) |current| current.outcome else null,
        .verdict = verdict,
        .coverage_plan = plan,
        .review_key = review_key,
        .route = if (report) |completed| completed.applied.depth else if (progress) |p| if (p.decision) |d| d.depth else null else null,
        .blocked_by = blocked,
        .publication_blocked_by = if (!ignored and job != null and job.?.phase == .pending) publication_blocked else null,
        .stack = stack_number,
        .all_models = if (job) |current| current.options.all_models or (progress != null and progress.?.all_models) else false,
    };
}

test "queue rows distinguish durable publication, limited coverage and cooldown" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entry: core.Entry = .{ .repo = .{ .name = "example/repo", .login = "reviewer" } };
    var job: core.Job = .{ .number = 7, .head = "a" ** 40 };
    var availability: Availability = .{ .now = 1000, .paused = false };
    availability.budget.noteFailure(990, error.GitHubRateLimited);
    const waiting = try buildJobRow(a, entry, job, null, &.{}, availability);
    try t.expectEqual(@as(?i64, 1050), waiting.eligible_at);
    try t.expectEqual(@as(?JobWait, .github_cooldown), waiting.wait);
    try t.expectEqualStrings("retry", waiting.stage);

    job.phase = .uncertain;
    job.attempts = 100;
    const unconfirmed = try buildJobRow(a, entry, job, null, &.{}, availability);
    try t.expectEqual(@as(?JobWait, .receipt_exhausted), unconfirmed.wait);

    job.phase = .complete;
    job.verdict = .{
        .head = job.head,
        .event = .COMMENT,
        .complete = false,
        .at = 995,
        .publication = .local,
        .disposition = .insufficient_evidence,
    };
    const saved = try buildJobRow(a, entry, job, null, &.{}, availability);
    try t.expectEqual(@as(?bool, false), saved.verdict.?.coverage_complete);
    try t.expectEqualStrings("local", saved.verdict.?.publication);
    try t.expectEqual(@as(?core.PublicationDisposition, .insufficient_evidence), saved.verdict.?.disposition);
    try t.expectEqual(@as(?usize, null), saved.percent);
    job.head = "b" ** 40;
    try t.expect((try buildJobRow(a, entry, job, null, &.{}, availability)).verdict == null);
}

const HistoryRow = struct {
    repo: []const u8,
    number: u32,
    head: []const u8,
    at: i64,
    event: core.Event,
    publication: []const u8,
    review_id: ?u64,
    route: ?@FieldType(core.Explanation, "route"),
    complete: ?bool,
    review_key: ?[]const u8,
    disposition: ?core.PublicationDisposition,
};

const HistoryKey = struct { repo: []const u8, number: u32, head: []const u8, run: []const u8, at: i64 = 0 };
const HistoryIndex = std.HashMapUnmanaged(HistoryKey, usize, struct {
    pub fn hash(_: @This(), key: HistoryKey) u64 {
        var digest = std.hash.Wyhash.init(key.number);
        digest.update(key.repo);
        digest.update(&.{0});
        digest.update(key.head);
        digest.update(&.{0});
        digest.update(key.run);
        digest.update(std.mem.asBytes(&key.at));
        return digest.final();
    }
    pub fn eql(_: @This(), left: HistoryKey, right: HistoryKey) bool {
        return left.number == right.number and left.at == right.at and io.eq(u8, left.repo, right.repo) and io.eq(u8, left.head, right.head) and io.eq(u8, left.run, right.run);
    }
}, std.hash_map.default_max_load_percentage);

fn historyKey(row: HistoryRow) HistoryKey {
    return .{ .repo = row.repo, .number = row.number, .head = row.head, .run = row.review_key orelse "", .at = row.at };
}

fn legacyHistory(a: A, db: store.Store, since: i64, rows: *std.ArrayList(HistoryRow), index: *HistoryIndex) !bool {
    const files = try db.listResults(since, legacy_file_limit + 1);
    for (files[0..@min(files.len, legacy_file_limit)]) |file| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var local = db;
        local.a = arena.allocator();
        const raw = local.readResult(file.repo, file.number) catch continue;
        const result = io.parse(local.a, core.Result, raw) catch continue;
        try addLegacy(a, rows, index, file, result.commit_id, result.event, result.explanation, since, file.changed_at);
        for (result.history) |prior| try addLegacy(a, rows, index, file, prior.commit_id, prior.event, prior.explanation, since, 0);
    }
    return files.len > legacy_file_limit;
}

fn addLegacy(a: A, rows: *std.ArrayList(HistoryRow), index: *HistoryIndex, file: store.ResultFile, head: []const u8, event: core.Event, detail: ?core.Explanation, since: i64, fallback: i64) !void {
    const at = if (detail) |explanation| explanation.at else fallback;
    if (at < since) return;
    const key = if (detail) |explanation| explanation.followup_id else null;
    const disposition = if (detail) |explanation| explanation.publicationReason() else null;
    if (index.get(.{ .repo = file.repo, .number = file.number, .head = head, .run = key orelse "", .at = at })) |position| {
        if (rows.items[position].disposition == null) rows.items[position].disposition = disposition;
        return;
    }
    const row: HistoryRow = .{
        .repo = file.repo,
        .number = file.number,
        .head = try a.dupe(u8, head),
        .at = at,
        .event = event,
        .publication = if (detail) |explanation| @tagName(explanation.publication) else "local",
        .review_id = if (detail) |explanation| explanation.github_review_id else null,
        .route = if (detail) |explanation| explanation.route else null,
        .complete = if (detail) |explanation| explanation.coverage.complete else null,
        .review_key = if (key) |value| try a.dupe(u8, value) else null,
        .disposition = disposition,
    };
    try index.put(a, historyKey(row), rows.items.len);
    try rows.append(a, row);
}

const History = struct { rows: []const HistoryRow = &.{}, truncated: bool = false };

fn getHistory(a: A, db: store.Store, since: i64, now: i64) !History {
    var rows: std.ArrayList(HistoryRow) = .empty;
    var index: HistoryIndex = .empty;
    defer index.deinit(a);
    const verdicts = try telemetry.readVerdicts(a, db.dir, .{ .since = since, .limit = telemetry.max_query_events, .now = now });
    for (verdicts) |verdict| {
        const row: HistoryRow = .{
            .repo = verdict.repo,
            .number = verdict.pr,
            .head = verdict.head,
            .at = verdict.at,
            .event = verdict.event,
            .publication = @tagName(verdict.publication),
            .review_id = verdict.github_review_id,
            .route = verdict.route,
            .complete = verdict.complete,
            .review_key = verdict.review_id,
            .disposition = verdict.disposition,
        };
        const slot = try index.getOrPut(a, historyKey(row));
        if (!slot.found_existing) {
            slot.value_ptr.* = rows.items.len;
            try rows.append(a, row);
        }
    }
    const limited = try legacyHistory(a, db, since, &rows, &index);
    std.mem.sort(HistoryRow, rows.items, {}, struct {
        fn newer(_: void, left: HistoryRow, right: HistoryRow) bool {
            return left.at > right.at;
        }
    }.newer);
    return .{ .rows = rows.items, .truncated = limited or verdicts.len >= telemetry.max_query_events };
}

const RepoRow = struct {
    name: []const u8,
    paused: bool,
    last_scan_at: i64,
    next_scan_at: i64,
    scan_attempts: u8,
    scan_error: ?[]const u8,
};
const StackMemberRow = struct { number: u32, draft: bool, phase: []const u8, blocked_by: ?u32 };
const StackRow = struct { repo: []const u8, number: ?u32, name: []const u8, members: []const StackMemberRow };
const FollowupRow = struct {
    repo: []const u8,
    source_pr: u32,
    source_url: []const u8,
    draft: ?u32,
    stage: []const u8,
    note: []const u8,
    paused: bool,
};

pub fn stateJson(a: A, db: store.Store, include_history: bool, now: i64) ![]const u8 {
    const state = try db.load();
    const ledger = try usage.load(a, db.dir, now);
    const attempts = try pairAttempts(a, try telemetry.read(a, db.dir, .{ .since = now - active_attempt_seconds, .limit = 2048, .now = now }), now);
    var repos: std.ArrayList(RepoRow) = .empty;
    var jobs: std.ArrayList(JobRow) = .empty;
    var stacks: std.ArrayList(StackRow) = .empty;
    for (state.entries) |entry| {
        const paused = try db.paused(entry.repo.name);
        const availability: Availability = .{ .now = now, .paused = paused, .budget = state.queue_budget, .usage = ledger };
        var scan_error: ?[]const u8 = null;
        if (entry.scan_attempts > 0) {
            var errors = std.mem.reverseIterator(entry.errors);
            while (errors.next()) |issue| {
                if (issue.at < entry.last_scan) break;
                if (issue.number != null) continue;
                scan_error = issue.detail;
                break;
            }
        }
        try repos.append(a, .{
            .name = entry.repo.name,
            .paused = paused,
            .last_scan_at = entry.last_scan,
            .next_scan_at = entry.next_scan,
            .scan_attempts = entry.scan_attempts,
            .scan_error = scan_error,
        });
        for (entry.jobs) |job| {
            var seen: ?core.Seen = null;
            for (entry.seen) |pull| {
                if (pull.number == job.number and io.eq(u8, pull.head, job.head)) {
                    seen = pull;
                    break;
                }
            }
            try jobs.append(a, try buildJobRow(a, entry, job, seen, attempts, availability));
        }
        for (entry.seen) |pull| {
            if (!entry.isIgnored(pull.number)) continue;
            for (entry.jobs) |job| {
                if (job.number == pull.number and io.eq(u8, job.head, pull.head)) break;
            } else try jobs.append(a, try buildJobRow(a, entry, null, pull, attempts, availability));
        }
        for (try stack.statuses(a, entry)) |item| {
            const members = try a.alloc(StackMemberRow, item.members.len);
            for (members, item.members) |*member, status| member.* = .{
                .number = status.number,
                .draft = status.is_draft,
                .phase = status.review,
                .blocked_by = if (status.blocked_by) |block| block.number else null,
            };
            try stacks.append(a, .{ .repo = entry.repo.name, .number = item.native_number, .name = item.name, .members = members });
        }
    }
    const history = if (include_history) try getHistory(a, db, now - detail_days * day_seconds, now) else History{};
    const followups = try a.alloc(FollowupRow, state.followups.len);
    for (followups, state.followups) |*row, job| row.* = .{
        .repo = job.source.repo,
        .source_pr = job.source.pr,
        .source_url = try job.source.url(a),
        .draft = job.pr,
        .stage = @tagName(job.stage),
        .note = job.note,
        .paused = job.paused,
    };
    return io.json(a, .{
        .at = now,
        .repos = repos.items,
        .jobs = jobs.items,
        .stacks = stacks.items,
        .followups = followups,
        .history = history.rows[0..@min(history.rows.len, history_limit)],
        .history_truncated = history.truncated or history.rows.len > history_limit,
    });
}

const Totals = struct {
    attempts: usize = 0,
    reported: usize = 0,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cached_input_tokens: ?u64 = null,
    cache_write_input_tokens: ?u64 = null,
    reasoning_output_tokens: ?u64 = null,

    fn add(self: *Totals, attempt: Attempt) void {
        self.attempts += 1;
        const tokens = attempt.tokens orelse return;
        if (!tokens.known()) return;
        self.reported += 1;
        if (tokens.input) |value| self.input_tokens = (self.input_tokens orelse 0) +| value;
        if (tokens.output) |value| self.output_tokens = (self.output_tokens orelse 0) +| value;
        if (tokens.cached_input) |value| self.cached_input_tokens = (self.cached_input_tokens orelse 0) +| value;
        if (tokens.cache_write_input) |value| self.cache_write_input_tokens = (self.cache_write_input_tokens orelse 0) +| value;
        if (tokens.reasoning_output) |value| self.reasoning_output_tokens = (self.reasoning_output_tokens orelse 0) +| value;
    }
};

const Bucket = struct {
    engine: core.Engine,
    model: []const u8,
    totals: Totals = .{},
    failures: usize = 0,
    durations: std.ArrayList(u64) = .empty,
    duration_ms: u64 = 0,
};
const ProviderRow = struct {
    engine: core.Engine,
    model: []const u8,
    attempts: usize,
    reported: usize,
    failures: usize,
    input_tokens: ?u64,
    output_tokens: ?u64,
    mean_duration_ms: ?u64,
    measured: usize,
    p50_duration_ms: ?u64,
    p95_duration_ms: ?u64,
};
const InvocationOutcome = enum { success, failed, timed_out, rate_limited, interrupted, running };

fn percentile(sorted: []const u64, percent: usize) ?u64 {
    if (sorted.len == 0) return null;
    const rank = std.math.divCeil(usize, sorted.len * percent, 100) catch unreachable;
    return sorted[rank - 1];
}

const ReviewCoverage = struct { complete: usize = 0, limited: usize = 0, unknown: usize = 0 };
const DayRow = struct { day: []const u8, attempts: usize, reported: usize, input_tokens: ?u64, output_tokens: ?u64 };
const ModelRow = struct { engine: core.Engine, model: []const u8, participations: usize = 0, input_tokens: ?u64 = null, output_tokens: ?u64 = null };

fn addModel(a: A, models: *std.ArrayList(ModelRow), engine: core.Engine, model: []const u8, tokens: telemetry.Tokens) !void {
    if (!tokens.known()) return;
    const row = for (models.items) |*value| {
        if (value.engine == engine and io.eq(u8, value.model, model)) break value;
    } else added: {
        const value = try models.addOne(a);
        value.* = .{ .engine = engine, .model = model };
        break :added value;
    };
    row.participations += 1;
    if (tokens.input) |value| row.input_tokens = (row.input_tokens orelse 0) +| value;
    if (tokens.output) |value| row.output_tokens = (row.output_tokens orelse 0) +| value;
}

fn isoDay(a: A, timestamp: i64) ![]const u8 {
    const day = (std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) }).getEpochDay();
    const year = day.calculateYearDay();
    const month = year.calculateMonthDay();
    return io.fmt(a, "{d}-{d:0>2}-{d:0>2}", .{ year.year, month.month.numeric(), month.day_index + 1 });
}

pub fn metricsJson(a: A, db: store.Store, days: u32, offset: u32, now: i64) ![]const u8 {
    const last_day = @divFloor(now, day_seconds) - offset;
    if (last_day < 0) return error.InvalidMetricsOffset;
    const end = if (offset == 0) now else (last_day + 1) * day_seconds - 1;
    const first_day = @max(0, last_day - days + 1);
    const first = first_day * day_seconds;
    const day_count: usize = @intCast(last_day - first_day + 1);
    // Include neighboring starts and finishes so a call spanning midnight
    // belongs only to the window containing its start.
    const events = try telemetry.read(a, db.dir, .{
        .since = @max(0, first - active_attempt_seconds),
        .limit = telemetry.max_query_events,
        .now = @min(now, end + active_attempt_seconds),
    });
    const attempts = try pairAttempts(a, events, now);
    const per_day = try a.alloc(Totals, day_count);
    @memset(per_day, .{});
    var totals: Totals = .{};
    var buckets: std.ArrayList(Bucket) = .empty;
    var models: std.ArrayList(ModelRow) = .empty;
    var stages: std.EnumArray(telemetry.Stage, usize) = .initFill(0);
    const Mode = @FieldType(telemetry.Scope, "mode");
    var modes: std.EnumArray(Mode, usize) = .initFill(0);
    var outcomes: std.EnumArray(InvocationOutcome, usize) = .initFill(0);
    for (attempts) |attempt| {
        if (attempt.at < first or attempt.at > end) continue;
        totals.add(attempt);
        per_day[@intCast(@divFloor(attempt.at - first, day_seconds))].add(attempt);
        stages.getPtr(attempt.stage).* += 1;
        modes.getPtr(attempt.mode).* += 1;
        if (attempt.model_usage.len != 0) {
            for (attempt.model_usage) |model| try addModel(a, &models, attempt.engine, model.model, model.tokens);
        } else if (attempt.tokens) |tokens| {
            try addModel(a, &models, attempt.engine, attempt.model, tokens);
        }
        const bucket = for (buckets.items) |*item| {
            if (item.engine == attempt.engine and io.eq(u8, item.model, attempt.model)) break item;
        } else added: {
            const item = try buckets.addOne(a);
            item.* = .{ .engine = attempt.engine, .model = attempt.model };
            break :added item;
        };
        bucket.totals.add(attempt);
        const outcome = std.meta.stringToEnum(InvocationOutcome, attempt.outcome) orelse .failed;
        outcomes.getPtr(outcome).* += 1;
        if (outcome != .success and outcome != .running) bucket.failures += 1;
        if (attempt.duration_ms) |duration| {
            try bucket.durations.append(a, duration);
            bucket.duration_ms +|= duration;
        }
    }
    const series = try a.alloc(DayRow, day_count);
    for (series, per_day, 0..) |*row, day_totals, index| row.* = .{
        .day = try isoDay(a, first + @as(i64, @intCast(index)) * day_seconds),
        .attempts = day_totals.attempts,
        .reported = day_totals.reported,
        .input_tokens = day_totals.input_tokens,
        .output_tokens = day_totals.output_tokens,
    };
    const providers = try a.alloc(ProviderRow, buckets.items.len);
    for (providers, buckets.items) |*provider, *bucket| {
        const measured = bucket.durations.items;
        std.mem.sort(u64, measured, {}, std.sort.asc(u64));
        provider.* = .{
            .engine = bucket.engine,
            .model = bucket.model,
            .attempts = bucket.totals.attempts,
            .reported = bucket.totals.reported,
            .failures = bucket.failures,
            .input_tokens = bucket.totals.input_tokens,
            .output_tokens = bucket.totals.output_tokens,
            .mean_duration_ms = if (measured.len == 0) null else bucket.duration_ms / measured.len,
            .measured = measured.len,
            .p50_duration_ms = percentile(measured, 50),
            .p95_duration_ms = percentile(measured, 95),
        };
        bucket.durations.deinit(a);
    }
    std.mem.sort(ProviderRow, providers, {}, struct {
        fn most(_: void, left: ProviderRow, right: ProviderRow) bool {
            return left.attempts > right.attempts;
        }
    }.most);
    std.mem.sort(ModelRow, models.items, {}, struct {
        fn most(_: void, left: ModelRow, right: ModelRow) bool {
            return left.participations > right.participations;
        }
    }.most);
    const StageCount = struct { stage: telemetry.Stage, attempts: usize };
    var stage_rows: std.ArrayList(StageCount) = .empty;
    for (std.meta.tags(telemetry.Stage)) |stage| {
        const count = stages.get(stage);
        if (count != 0) try stage_rows.append(a, .{ .stage = stage, .attempts = count });
    }
    const ModeCount = struct { mode: Mode, attempts: usize };
    var mode_rows: std.ArrayList(ModeCount) = .empty;
    for (std.meta.tags(Mode)) |mode| {
        const count = modes.get(mode);
        if (count != 0) try mode_rows.append(a, .{ .mode = mode, .attempts = count });
    }
    const OutcomeCount = struct { outcome: InvocationOutcome, attempts: usize };
    var outcome_rows: std.ArrayList(OutcomeCount) = .empty;
    for (std.meta.tags(InvocationOutcome)) |outcome| {
        const count = outcomes.get(outcome);
        if (count != 0) try outcome_rows.append(a, .{ .outcome = outcome, .attempts = count });
    }
    const history = try getHistory(a, db, first, end);
    const Depth = @FieldType(core.Explanation, "route");
    var routes: std.EnumArray(Depth, usize) = .initFill(0);
    var verdict_count: usize = 0;
    var published: usize = 0;
    var heads: HistoryIndex = .empty;
    defer heads.deinit(a);
    var coverage: ReviewCoverage = .{};
    for (history.rows) |item| {
        if (item.at > end) continue;
        if (io.eq(u8, item.publication, "pending") or io.eq(u8, item.publication, "preview")) continue;
        verdict_count += 1;
        published += @intFromBool(io.eq(u8, item.publication, "verified"));
        const slot = try heads.getOrPut(a, .{ .repo = item.repo, .number = item.number, .head = item.head, .run = "" });
        if (!slot.found_existing) {
            slot.value_ptr.* = 0;
            if (item.complete) |complete| {
                if (complete) coverage.complete += 1 else coverage.limited += 1;
            } else coverage.unknown += 1;
        }
        if (item.route) |route| {
            routes.getPtr(route).* += 1;
        }
    }
    const DepthCount = struct { route: Depth, count: usize };
    var route_rows: std.ArrayList(DepthCount) = .empty;
    for (std.meta.tags(Depth)) |route| {
        const count = routes.get(route);
        if (count != 0) try route_rows.append(a, .{ .route = route, .count = count });
    }
    return io.json(a, .{
        .days = days,
        .since = first,
        .through = end,
        .attempts = totals.attempts,
        .reported = totals.reported,
        .input_tokens = totals.input_tokens,
        .output_tokens = totals.output_tokens,
        .cached_input_tokens = totals.cached_input_tokens,
        .cache_write_input_tokens = totals.cache_write_input_tokens,
        .reasoning_output_tokens = totals.reasoning_output_tokens,
        .review_count = verdict_count,
        .review_published = published,
        .reviewed_heads = heads.count(),
        .coverage = coverage,
        .outcomes = outcome_rows.items,
        .series = series,
        .providers = providers,
        .models = models.items,
        .stages = stage_rows.items,
        .modes = mode_rows.items,
        .routes = route_rows.items,
        .truncated = events.len >= telemetry.max_query_events or history.truncated,
        .ledger = try usage.load(a, db.dir, now),
    });
}

const ReviewUsage = struct { head: []const u8, review_key: ?[]const u8, mode: @FieldType(telemetry.Scope, "mode"), at: i64, totals: Totals = .{} };

pub fn reviewJson(a: A, db: store.Store, name: []const u8, number: u32, now: i64) ![]const u8 {
    var state = try db.load();
    const entry = state.find(name) orelse return error.UnknownRepository;
    const events = try telemetry.read(a, db.dir, .{
        .repo = entry.repo.name,
        .pr = number,
        .since = now - detail_days * day_seconds,
        .limit = telemetry.max_query_events,
        .now = now,
    });
    const attempts = try pairAttempts(a, events, now);
    const result: ?core.Result = result: {
        const raw = db.readResult(entry.repo.name, number) catch |err| switch (err) {
            error.NoLocalReview => break :result null,
            else => return err,
        };
        var saved = try io.parse(a, core.Result, raw);
        if (saved.explanation) |*detail| detail.disposition = detail.publicationReason();
        const history = try a.dupe(core.PastResult, saved.history);
        for (history) |*prior| {
            if (prior.explanation) |*detail| detail.disposition = detail.publicationReason();
        }
        saved.history = history;
        break :result saved;
    };
    const job = try jobRow(a, entry.*, number, attempts, .{
        .now = now,
        .paused = try db.paused(entry.repo.name),
        .budget = state.queue_budget,
        .usage = try usage.load(a, db.dir, now),
    }, result);
    var groups: std.ArrayList(ReviewUsage) = .empty;
    var totals: Totals = .{};
    for (attempts) |attempt| {
        totals.add(attempt);
        const group = for (groups.items) |*group| {
            if (group.mode == attempt.mode and io.eq(u8, group.head, attempt.head) and io.eq(u8, group.review_key orelse "", attempt.review_key orelse "")) break group;
        } else added: {
            const group = try groups.addOne(a);
            group.* = .{ .head = attempt.head, .review_key = attempt.review_key, .mode = attempt.mode, .at = attempt.at };
            break :added group;
        };
        group.totals.add(attempt);
    }
    return io.json(a, .{
        .job = job,
        .result = result,
        .tracked = job != null,
        .attempts = attempts[0..@min(attempts.len, 180)],
        .usage = totals,
        .review_usage = groups.items[0..@min(groups.items.len, 40)],
        .activity_truncated = events.len >= telemetry.max_query_events or attempts.len > 180 or groups.items.len > 40,
    });
}

test "pending rows surface the most recently finished pass for the current scheduled head" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo: core.Repo = .{ .name = "example/repo", .login = "reviewer" };
    const job: core.Job = .{ .number = 42, .head = "b" ** 40 };
    const entry: core.Entry = .{ .repo = repo };
    const slow: telemetry.Event = .{
        .id = "slow",
        .at = 900,
        .kind = .started,
        .scope = .{ .repo = repo.name, .pr = job.number, .head = job.head, .section = 4, .stage = .completion },
        .engine = .codex,
        .model = "example-model",
        .effort = .high,
    };
    var fast = slow;
    fast.id = "fast";
    fast.at = 940;
    fast.scope.section = 3;
    var fast_finished = fast;
    fast_finished.kind = .finished;
    fast_finished.at = 980;
    fast_finished.outcome = .success;
    var slow_finished = slow;
    slow_finished.kind = .finished;
    slow_finished.at = 990;
    slow_finished.duration_ms = 90_000;
    slow_finished.outcome = .timed_out;
    var preview = slow_finished;
    preview.id = "preview";
    preview.at = 995;
    preview.scope.mode = .preview;
    var previous_head = slow_finished;
    previous_head.id = "old";
    previous_head.at = 999;
    previous_head.scope.head = "a" ** 40;
    const attempts = try pairAttempts(a, &.{ slow, fast, fast_finished, slow_finished, preview, previous_head }, 1000);
    const result = try buildJobRow(a, entry, job, null, attempts, .{ .now = 1000, .paused = false });
    const latest = result.last_pass.?;
    try t.expectEqual(@as(i64, 990), latest.finished_at);
    try t.expectEqual(@as(?usize, 4), latest.section);
    try t.expectEqual(@as(?u64, 90_000), latest.duration_ms);
    try t.expectEqualStrings("timed_out", latest.outcome);
}

test "metrics pair starts and finishes and account for advisor models separately" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var db = try store.Store.open(a, path);
    defer db.dir.close();
    const now = std.time.timestamp();
    const scope: telemetry.Scope = .{ .repo = "example/repo", .pr = 42, .head = "a" ** 40 };
    const started: telemetry.Event = .{
        .id = "1" ** 32,
        .at = now - 10,
        .kind = .started,
        .scope = scope,
        .engine = .claude,
        .model = "opus",
        .effort = .high,
    };
    var finished = started;
    finished.kind = .finished;
    finished.at = now;
    finished.outcome = .success;
    finished.duration_ms = 10_000;
    finished.tokens = .{ .input = 160, .output = 25 };
    finished.model_usage = &.{
        .{ .model = "opus", .tokens = .{ .input = 100, .output = 15 } },
        .{ .model = "fable", .tokens = .{ .input = 60, .output = 10 } },
    };
    try telemetry.append(a, db.dir, started);
    try telemetry.append(a, db.dir, finished);
    var unreported = finished;
    unreported.id = "2" ** 32;
    unreported.engine = .kimi;
    unreported.model = "kimi";
    unreported.tokens = null;
    unreported.model_usage = &.{};
    unreported.outcome = .timed_out;
    unreported.duration_ms = null;
    try telemetry.append(a, db.dir, unreported);
    var verdict: telemetry.Verdict = .{
        .at = now - 1,
        .repo = scope.repo,
        .pr = scope.pr,
        .head = scope.head,
        .route = .multi,
        .event = .COMMENT,
        .publication = .local,
        .complete = false,
    };
    try telemetry.recordVerdict(db.dir, verdict);
    verdict.publication = .verified;
    verdict.github_review_id = 55;
    try telemetry.recordVerdict(db.dir, verdict);
    verdict.at = now;
    verdict.review_id = "follow-up";
    verdict.publication = .local;
    verdict.github_review_id = null;
    verdict.complete = true;
    try telemetry.recordVerdict(db.dir, verdict);

    const Summary = struct {
        attempts: usize,
        reported: usize,
        review_count: usize,
        review_published: usize,
        reviewed_heads: usize,
        coverage: ReviewCoverage,
        input_tokens: ?u64,
        output_tokens: ?u64,
        models: []const ModelRow,
        providers: []const ProviderRow,
    };
    const result = try io.parse(a, Summary, try metricsJson(a, db, 7, 0, now));
    try t.expectEqual(@as(usize, 2), result.attempts);
    try t.expectEqual(@as(usize, 1), result.reported);
    try t.expectEqual(@as(usize, 2), result.review_count);
    try t.expectEqual(@as(usize, 1), result.review_published);
    try t.expectEqual(@as(usize, 1), result.reviewed_heads);
    try t.expectEqual(ReviewCoverage{ .complete = 1 }, result.coverage);
    try t.expectEqual(@as(?u64, 160), result.input_tokens);
    try t.expectEqual(@as(?u64, 25), result.output_tokens);
    try t.expectEqual(@as(usize, 2), result.models.len);
    try t.expectEqual(@as(?u64, 160), result.models[0].input_tokens.? + result.models[1].input_tokens.?);
    for (result.providers) |profile| {
        if (profile.engine == .kimi) {
            try t.expect(profile.input_tokens == null);
            try t.expectEqual(@as(?u64, null), profile.p95_duration_ms);
            try t.expectEqual(@as(usize, 1), profile.failures);
        } else {
            try t.expectEqual(@as(usize, 1), profile.measured);
            try t.expectEqual(@as(?u64, 10_000), profile.p50_duration_ms);
            try t.expectEqual(@as(?u64, 10_000), profile.p95_duration_ms);
        }
    }
}

test "extended usage includes attempts and verdicts older than 90 days" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var db = try store.Store.open(a, path);
    defer db.dir.close();
    const now = std.time.timestamp();
    const scope: telemetry.Scope = .{ .repo = "example/repo", .pr = 8, .head = "a" ** 40 };
    var attempt: telemetry.Event = .{
        .id = "old-attempt",
        .at = now - 120 * day_seconds,
        .kind = .finished,
        .scope = scope,
        .engine = .codex,
        .model = "example-model",
        .effort = .high,
        .outcome = .success,
        .tokens = .{ .input = 1200 },
    };
    var verdict: telemetry.Verdict = .{
        .at = attempt.at,
        .repo = scope.repo,
        .pr = scope.pr,
        .head = scope.head,
        .route = .multi,
        .event = .APPROVE,
        .publication = .local,
        .complete = true,
    };
    try telemetry.append(a, db.dir, attempt);
    try telemetry.recordVerdict(db.dir, verdict);
    attempt.id = "new-attempt";
    attempt.at = now;
    attempt.tokens = .{ .input = 100 };
    verdict.at = now;
    verdict.head = "b" ** 40;
    try telemetry.append(a, db.dir, attempt);
    try telemetry.recordVerdict(db.dir, verdict);

    const Summary = struct { attempts: usize, review_count: usize, input_tokens: ?u64 };
    const recent = try io.parse(a, Summary, try metricsJson(a, db, 30, 0, now));
    try t.expectEqual(Summary{ .attempts = 1, .review_count = 1, .input_tokens = 100 }, recent);
    const extended = try io.parse(a, Summary, try metricsJson(a, db, 365, 0, now));
    try t.expectEqual(Summary{ .attempts = 2, .review_count = 2, .input_tokens = 1300 }, extended);
    const older = try io.parse(a, Summary, try metricsJson(a, db, 30, 105, now));
    try t.expectEqual(Summary{ .attempts = 1, .review_count = 1, .input_tokens = 1200 }, older);

    const midnight = @divFloor(now, day_seconds) * day_seconds - 110 * day_seconds;
    attempt.id = "cross-midnight";
    attempt.kind = .started;
    attempt.at = midnight - 60;
    attempt.outcome = null;
    attempt.tokens = null;
    try telemetry.append(a, db.dir, attempt);
    attempt.kind = .finished;
    attempt.at = midnight + 60;
    attempt.outcome = .success;
    attempt.tokens = .{ .input = 75 };
    try telemetry.append(a, db.dir, attempt);
    const day_started = try io.parse(a, Summary, try metricsJson(a, db, 1, 111, now));
    try t.expectEqual(Summary{ .attempts = 1, .review_count = 0, .input_tokens = 75 }, day_started);
    const day_finished = try io.parse(a, Summary, try metricsJson(a, db, 1, 110, now));
    try t.expectEqual(Summary{ .attempts = 0, .review_count = 0, .input_tokens = null }, day_finished);
}
