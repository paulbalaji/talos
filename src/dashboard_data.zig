const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");
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
    engine: core.Engine,
    model: []const u8,
    stage: telemetry.Stage,
    section: ?usize,
    section_count: ?usize,
    at: i64,
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
            .engine = latest.engine,
            .model = latest.model,
            .stage = latest.scope.stage,
            .section = latest.scope.section,
            .section_count = latest.scope.section_count,
            .at = started.at,
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
            return left.at > right.at;
        }
    }.newer);
    return attempts;
}

const ActiveProvider = struct { engine: core.Engine, model: []const u8, stage: telemetry.Stage, section: ?usize, at: i64 };
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
    next_at: i64,
    attempts: u8,
    last_error: ?[]const u8,
    blocked_by: ?u32,
    all_models: bool,
    stack: ?u32,
};

fn jobRow(a: A, entry: core.Entry, number: u32, attempts: []const Attempt, now: i64, paused: bool) !?JobRow {
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
    return try buildJobRow(a, entry, job, seen, attempts, now, paused);
}

fn buildJobRow(a: A, entry: core.Entry, job: ?core.Job, seen_: ?core.Seen, attempts: []const Attempt, now: i64, paused: bool) !JobRow {
    const seen = seen_ orelse core.Seen{ .number = job.?.number, .head = job.?.head };
    const head = if (job) |current| current.head else seen.head;
    const progress = if (job) |current| current.route_progress else null;
    const complete = if (progress) |p| p.sections.index else 0;
    var total: ?usize = null;
    if (progress) |p| if (p.sections.checkpoint) |checkpoint| {
        total = checkpoint.section_count;
    };
    var active: std.ArrayList(ActiveProvider) = .empty;
    if (job != null and job.?.phase == .pending) {
        const review_key = try core.followupId(a, job.?);
        for (attempts) |attempt| {
            if (!io.eq(u8, attempt.outcome, "running") or attempt.mode != .scheduled or
                !io.eq(u8, attempt.repo, entry.repo.name) or attempt.number != seen.number or !io.eq(u8, attempt.head, head)) continue;
            if (!io.eq(u8, attempt.review_key orelse "", review_key orelse "")) continue;
            if (total == null) total = attempt.section_count;
            try active.append(a, .{ .engine = attempt.engine, .model = attempt.model, .stage = attempt.stage, .section = attempt.section, .at = attempt.at });
        }
    }
    var blocked: ?u32 = null;
    var stack_number: ?u32 = null;
    if (stack.find(entry.stacks, seen.number)) |position| {
        const item = entry.stacks[position.stack_index];
        if (item.native) |native| stack_number = native.number;
        if (stack.blocker(entry, item, position.member_index)) |block| blocked = block.number;
    }
    var last_error: ?[]const u8 = null;
    var errors = std.mem.reverseIterator(entry.errors);
    while (errors.next()) |entry_error| {
        if (entry_error.number == seen.number) {
            last_error = entry_error.detail;
            break;
        }
    }
    const phase = if (job) |current| @tagName(current.phase) else "baseline";
    const stage = stage: {
        const current = job orelse break :stage "baseline";
        switch (current.phase) {
            .complete => break :stage "complete",
            .uncertain => break :stage "receipt",
            .failed => break :stage "failed",
            .pending => {},
        }
        if (active.items.len != 0) break :stage @tagName(active.items[0].stage);
        if (paused) break :stage "paused";
        if (blocked != null) break :stage "blocked";
        if (current.next > now) break :stage "retry";
        if (current.analysis != null) break :stage "publishing";
        if (progress) |p| {
            if (p.readyToPublish()) break :stage "publishing";
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
        .percent = if (io.eq(u8, phase, "complete")) 100 else if (total) |count| if (count > 0) @intCast(@min(99, @as(u128, complete) * 100 / count)) else null else null,
        .completed_sections = complete,
        .total_sections = total,
        .active_providers = active.items,
        .next_at = if (job) |current| current.next else 0,
        .attempts = if (job) |current| current.attempts else 0,
        .last_error = last_error,
        .blocked_by = blocked,
        .stack = stack_number,
        .all_models = if (job) |current| current.options.all_models or (progress != null and progress.?.all_models) else false,
    };
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
};

const HistoryKey = struct { repo: []const u8, number: u32, head: []const u8, run: []const u8 };
const HistoryIndex = std.HashMapUnmanaged(HistoryKey, void, struct {
    pub fn hash(_: @This(), key: HistoryKey) u64 {
        var digest = std.hash.Wyhash.init(key.number);
        digest.update(key.repo);
        digest.update(&.{0});
        digest.update(key.head);
        digest.update(&.{0});
        digest.update(key.run);
        return digest.final();
    }
    pub fn eql(_: @This(), left: HistoryKey, right: HistoryKey) bool {
        return left.number == right.number and io.eq(u8, left.repo, right.repo) and io.eq(u8, left.head, right.head) and io.eq(u8, left.run, right.run);
    }
}, std.hash_map.default_max_load_percentage);

fn historyKey(row: HistoryRow) HistoryKey {
    return .{ .repo = row.repo, .number = row.number, .head = row.head, .run = row.review_key orelse "" };
}

const LegacyFile = struct { repo: []const u8, number: u32, changed_at: i64 };
fn compareFiles(_: void, left: LegacyFile, right: LegacyFile) std.math.Order {
    return std.math.order(left.changed_at, right.changed_at);
}

fn legacyHistory(a: A, db: store.Store, entries: []const core.Entry, since: i64, rows: *std.ArrayList(HistoryRow), index: *HistoryIndex) !bool {
    var latest = std.PriorityQueue(LegacyFile, void, compareFiles).init(a, {});
    defer latest.deinit();
    var truncated = false;
    for (entries) |entry| {
        const path = try db.repoPath(entry.repo.name, "results");
        var results = db.dir.openDir(path, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer results.close();
        var files = results.iterate();
        while (try files.next()) |file| {
            if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".json")) continue;
            const number = std.fmt.parseUnsigned(u32, file.name[0 .. file.name.len - ".json".len], 10) catch continue;
            const stat = results.statFile(file.name) catch continue;
            const changed_at: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
            if (changed_at < since) continue;
            if (latest.count() == legacy_file_limit) {
                truncated = true;
                if (latest.peek().?.changed_at >= changed_at) continue;
                _ = latest.remove();
            }
            try latest.add(.{ .repo = entry.repo.name, .number = number, .changed_at = changed_at });
        }
    }
    while (latest.removeOrNull()) |file| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var local = db;
        local.a = arena.allocator();
        const raw = local.readResult(file.repo, file.number) catch continue;
        const result = io.parse(local.a, core.Result, raw) catch continue;
        try addLegacy(a, rows, index, file, result.commit_id, result.event, result.explanation, since, file.changed_at);
        for (result.history) |prior| try addLegacy(a, rows, index, file, prior.commit_id, prior.event, prior.explanation, since, 0);
    }
    return truncated;
}

fn addLegacy(a: A, rows: *std.ArrayList(HistoryRow), index: *HistoryIndex, file: LegacyFile, head: []const u8, event: core.Event, detail: ?core.Explanation, since: i64, fallback: i64) !void {
    const at = if (detail) |explanation| explanation.at else fallback;
    if (at < since) return;
    const key = if (detail) |explanation| explanation.followup_id else null;
    if (index.contains(.{ .repo = file.repo, .number = file.number, .head = head, .run = key orelse "" })) return;
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
    };
    try index.put(a, historyKey(row), {});
    try rows.append(a, row);
}

const History = struct { rows: []const HistoryRow = &.{}, truncated: bool = false };

fn getHistory(a: A, db: store.Store, entries: []const core.Entry, since: i64, now: i64) !History {
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
        };
        const slot = try index.getOrPut(a, historyKey(row));
        if (!slot.found_existing) try rows.append(a, row);
    }
    const limited = try legacyHistory(a, db, entries, since, &rows, &index);
    std.mem.sort(HistoryRow, rows.items, {}, struct {
        fn newer(_: void, left: HistoryRow, right: HistoryRow) bool {
            return left.at > right.at;
        }
    }.newer);
    return .{ .rows = rows.items, .truncated = limited or verdicts.len >= telemetry.max_query_events };
}

const RepoRow = struct { name: []const u8, paused: bool, last_scan_at: i64, next_scan_at: i64 };
const StackMemberRow = struct { number: u32, draft: bool, phase: []const u8, blocked_by: ?u32 };
const StackRow = struct { repo: []const u8, number: ?u32, name: []const u8, members: []const StackMemberRow };

pub fn stateJson(a: A, db: store.Store, include_history: bool, now: i64) ![]const u8 {
    const state = try db.load();
    const attempts = try pairAttempts(a, try telemetry.read(a, db.dir, .{ .since = now - active_attempt_seconds, .limit = 2048, .now = now }), now);
    var repos: std.ArrayList(RepoRow) = .empty;
    var jobs: std.ArrayList(JobRow) = .empty;
    var stacks: std.ArrayList(StackRow) = .empty;
    for (state.entries) |entry| {
        const paused = try db.paused(entry.repo.name);
        try repos.append(a, .{ .name = entry.repo.name, .paused = paused, .last_scan_at = entry.last_scan, .next_scan_at = entry.next_scan });
        for (entry.jobs) |job| {
            var seen: ?core.Seen = null;
            for (entry.seen) |pull| {
                if (pull.number == job.number and io.eq(u8, pull.head, job.head)) {
                    seen = pull;
                    break;
                }
            }
            try jobs.append(a, try buildJobRow(a, entry, job, seen, attempts, now, paused));
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
    const history = if (include_history) try getHistory(a, db, state.entries, now - detail_days * day_seconds, now) else History{};
    return io.json(a, .{
        .at = now,
        .repos = repos.items,
        .jobs = jobs.items,
        .stacks = stacks.items,
        .history = history.rows[0..@min(history.rows.len, history_limit)],
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
    measured: usize = 0,
    duration_ms: u64 = 0,
};
const ProviderRow = struct { engine: core.Engine, model: []const u8, attempts: usize, reported: usize, failures: usize, input_tokens: ?u64, output_tokens: ?u64, mean_duration_ms: ?u64 };
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
        if (!io.eq(u8, attempt.outcome, "success") and !io.eq(u8, attempt.outcome, "running")) bucket.failures += 1;
        if (attempt.duration_ms) |duration| {
            bucket.measured += 1;
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
    for (providers, buckets.items) |*provider, bucket| provider.* = .{
        .engine = bucket.engine,
        .model = bucket.model,
        .attempts = bucket.totals.attempts,
        .reported = bucket.totals.reported,
        .failures = bucket.failures,
        .input_tokens = bucket.totals.input_tokens,
        .output_tokens = bucket.totals.output_tokens,
        .mean_duration_ms = if (bucket.measured == 0) null else bucket.duration_ms / bucket.measured,
    };
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
    const state = try db.load();
    const history = try getHistory(a, db, state.entries, first, end);
    const Depth = @FieldType(core.Explanation, "route");
    var routes: std.EnumArray(Depth, usize) = .initFill(0);
    var verdict_count: usize = 0;
    for (history.rows) |item| {
        if (item.at > end) continue;
        if (io.eq(u8, item.publication, "pending") or io.eq(u8, item.publication, "preview")) continue;
        verdict_count += 1;
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
    const attempts = try pairAttempts(a, try telemetry.read(a, db.dir, .{ .repo = entry.repo.name, .pr = number, .since = now - detail_days * day_seconds, .limit = telemetry.max_query_events, .now = now }), now);
    const job = try jobRow(a, entry.*, number, attempts, now, try db.paused(entry.repo.name));
    const result: ?core.Result = result: {
        const raw = db.readResult(entry.repo.name, number) catch |err| switch (err) {
            error.NoLocalReview => break :result null,
            else => return err,
        };
        break :result try io.parse(a, core.Result, raw);
    };
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
    });
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
    try telemetry.append(a, db.dir, unreported);
    var verdict: telemetry.Verdict = .{
        .at = now,
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

    const Summary = struct {
        attempts: usize,
        reported: usize,
        review_count: usize,
        input_tokens: ?u64,
        output_tokens: ?u64,
        models: []const ModelRow,
        providers: []const ProviderRow,
    };
    const result = try io.parse(a, Summary, try metricsJson(a, db, 7, 0, now));
    try t.expectEqual(@as(usize, 2), result.attempts);
    try t.expectEqual(@as(usize, 1), result.reported);
    try t.expectEqual(@as(usize, 1), result.review_count);
    try t.expectEqual(@as(?u64, 160), result.input_tokens);
    try t.expectEqual(@as(?u64, 25), result.output_tokens);
    try t.expectEqual(@as(usize, 2), result.models.len);
    try t.expectEqual(@as(?u64, 160), result.models[0].input_tokens.? + result.models[1].input_tokens.?);
    for (result.providers) |profile| {
        if (profile.engine == .kimi) try t.expect(profile.input_tokens == null);
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
