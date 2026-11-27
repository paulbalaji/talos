const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");
const routing = @import("routing.zig");
const posix = std.posix;
const sqlite = @import("sqlite.zig");

pub const Stage = enum { review, screen, completion, synthesis, preview, followup, audit };
pub const Mode = enum { scheduled, preview, followup };
pub const Outcome = enum { success, failed, timed_out, rate_limited };

pub const Scope = struct {
    repo: []const u8,
    pr: u32,
    head: []const u8,
    review_id: ?[]const u8 = null,
    section: ?usize = null,
    section_count: ?usize = null,
    stage: Stage = .review,
    mode: Mode = .scheduled,
    route: ?routing.Depth = null,
    focus: ?core.ReviewFocus = null,
    additional_focuses: ?[]const core.ReviewFocus = null,
};

// Cached and cache-write inputs are included in input. Reasoning output
// is included in output. Null means the provider did not report that count.
pub const Tokens = struct {
    input: ?u64 = null,
    output: ?u64 = null,
    cached_input: ?u64 = null,
    cache_write_input: ?u64 = null,
    reasoning_output: ?u64 = null,

    pub fn known(self: Tokens) bool {
        return self.input != null or self.output != null or self.cached_input != null or
            self.cache_write_input != null or self.reasoning_output != null;
    }
};

pub const ModelUsage = struct {
    model: []const u8,
    tokens: Tokens,
};

pub const Event = struct {
    id: []const u8,
    at: i64,
    kind: enum { started, finished },
    scope: Scope,
    engine: core.Engine,
    model: []const u8,
    effort: core.ReviewEffort,
    pid: ?u32 = null,
    duration_ms: ?u64 = null,
    outcome: ?Outcome = null,
    error_name: ?[]const u8 = null,
    tokens: ?Tokens = null,
    model_usage: []const ModelUsage = &.{},
};

pub const Verdict = struct {
    at: i64,
    repo: []const u8,
    pr: u32,
    head: []const u8,
    review_id: ?[]const u8 = null,
    route: routing.Depth,
    event: core.Event,
    publication: enum { local, verified },
    disposition: ?core.PublicationDisposition = null,
    github_review_id: ?u64 = null,
    complete: bool,
};

pub const Recorder = struct {
    dir: std.fs.Dir,
    scope: Scope,

    pub fn write(self: Recorder, a: io.A, event: Event) void {
        append(a, self.dir, event) catch |err| std.log.warn("review telemetry: {s}", .{@errorName(err)});
    }
};

pub const Query = struct {
    since: i64,
    repo: ?[]const u8 = null,
    pr: ?u32 = null,
    limit: usize = 2000,
    now: ?i64 = null,
};

pub const max_query_events = 12_000;
const attempt_directory = "telemetry";
const verdict_directory = "verdicts";
const suffix = ".jsonl";
const max_day_bytes = 1024 * 1024;
const max_event_bytes = 8 * 1024;

const migration_key = "legacy_telemetry_imported";

pub fn append(a: io.A, root: std.fs.Dir, event: Event) !void {
    const db = try open(a, root);
    defer db.close();
    try putEvent(db, a, event);
}

pub fn recordVerdict(root: std.fs.Dir, verdict: Verdict) !void {
    const a = std.heap.page_allocator;
    const db = try open(a, root);
    defer db.close();
    try putVerdict(db, a, verdict);
}

fn open(a: io.A, root: std.fs.Dir) !sqlite.Db {
    const db = try sqlite.Db.open(a, root);
    errdefer db.close();
    if (!try db.hasSetting(migration_key)) {
        try db.beginWrite();
        errdefer db.rollback();
        try migrate(db, root);
        try db.commit();
    }
    return db;
}

fn putEvent(db: sqlite.Db, a: io.A, event: Event) !void {
    const json = try std.json.Stringify.valueAlloc(a, event, .{ .emit_null_optional_fields = false });
    defer a.free(json);
    if (json.len > max_event_bytes) return error.TelemetryRecordTooLarge;
    try db.run(
        "INSERT INTO telemetry_event(id,kind,at,repo,number,payload) VALUES (?,?,?,?,?,?) ON CONFLICT(id,kind) DO NOTHING",
        .{ event.id, @tagName(event.kind), event.at, event.scope.repo, event.scope.pr, json },
    );
}

/// Insert the verdict in the same transaction as the saved review.
pub fn putVerdict(db: sqlite.Db, a: io.A, verdict: Verdict) !void {
    const json = try std.json.Stringify.valueAlloc(a, verdict, .{ .emit_null_optional_fields = false });
    defer a.free(json);
    if (json.len > max_event_bytes) return error.TelemetryRecordTooLarge;
    try db.run(
        \\INSERT INTO review_verdict(repo,number,head,review_key,at,event,publication,payload) VALUES (?,?,?,?,?,?,?,?)
        \\ON CONFLICT(repo,number,head,review_key,at,event,publication) DO NOTHING
    , .{ verdict.repo, verdict.pr, verdict.head, verdict.review_id orelse "", verdict.at, @tagName(verdict.event), @tagName(verdict.publication), json });
}

/// Run under the caller's write transaction. Files remain as a pre-cutover snapshot.
pub fn migrate(db: sqlite.Db, root: std.fs.Dir) !void {
    if (try db.hasSetting(migration_key)) return;
    try importSegments(db, root, attempt_directory, Event);
    try importSegments(db, root, verdict_directory, Verdict);
    try db.setSetting(migration_key, "1");
}

fn importSegments(db: sqlite.Db, root: std.fs.Dir, directory: []const u8, comptime Record: type) !void {
    var dir = root.openDir(directory, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var segment = dir.iterate();
    while (try segment.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, suffix)) continue;
        _ = std.fmt.parseInt(i64, entry.name[0 .. entry.name.len - suffix.len], 10) catch continue;
        const fd = try posix.openat(dir.fd, entry.name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
        const file: std.fs.File = .{ .handle = fd };
        defer file.close();
        const stat = try posix.fstat(fd);
        if (stat.mode & posix.S.IFMT != posix.S.IFREG or stat.nlink != 1) return error.InvalidTelemetryFile;
        const raw = try file.readToEndAlloc(std.heap.page_allocator, max_day_bytes);
        defer std.heap.page_allocator.free(raw);
        const end = std.mem.lastIndexOfScalar(u8, raw, '\n') orelse continue;
        var records = std.mem.splitScalar(u8, raw[0..end], '\n');
        while (records.next()) |line| {
            if (line.len == 0 or line.len > max_event_bytes) continue;
            defer _ = scratch.reset(.retain_capacity);
            const record = io.parse(a, Record, line) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue, // The old reader also ignored damaged records.
            };
            if (Record == Event) {
                try putEvent(db, a, record);
            } else {
                try putVerdict(db, a, record);
            }
        }
    }
}

pub fn read(a: io.A, root: std.fs.Dir, query: Query) ![]const Event {
    return readRecords(a, root, "telemetry_event", Event, query);
}

pub fn readVerdicts(a: io.A, root: std.fs.Dir, query: Query) ![]const Verdict {
    return readRecords(a, root, "review_verdict", Verdict, query);
}

fn readRecords(a: io.A, root: std.fs.Dir, comptime table: []const u8, comptime Record: type, query: Query) ![]const Record {
    const limit = @min(query.limit, max_query_events);
    if (limit == 0) return &.{};
    const db = try open(a, root);
    defer db.close();
    const select = "SELECT payload FROM " ++ table ++ " WHERE at>=? AND at<=?";
    const order = " ORDER BY at DESC, rowid DESC LIMIT ?";
    const until = query.now orelse std.time.timestamp();
    var rows = if (query.repo != null and query.pr != null)
        try db.prepare(select ++ " AND repo=? AND number=?" ++ order)
    else if (query.repo != null)
        try db.prepare(select ++ " AND repo=?" ++ order)
    else if (query.pr != null)
        try db.prepare(select ++ " AND number=?" ++ order)
    else
        try db.prepare(select ++ order);
    defer rows.close();
    if (query.repo) |repo| {
        if (query.pr) |pr| try rows.bind(.{ query.since, until, repo, pr, limit }) else try rows.bind(.{ query.since, until, repo, limit });
    } else if (query.pr) |pr| {
        try rows.bind(.{ query.since, until, pr, limit });
    } else {
        try rows.bind(.{ query.since, until, limit });
    }
    var found: std.ArrayList(Record) = .empty;
    while (try rows.step()) try found.append(a, try io.parse(a, Record, rows.bytes(0)));
    return found.toOwnedSlice(a);
}

const sample: Event = .{
    .id = "attempt",
    .at = 120 * std.time.s_per_day,
    .kind = .started,
    .scope = .{ .repo = "example/repo", .pr = 7, .head = "01234567" },
    .engine = .codex,
    .model = "example-model",
    .effort = .max,
};

test "legacy complete records import once and later writes leave older days readable" {
    const t = std.testing;
    var scratch = t.tmpDir(.{});
    defer scratch.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = scratch.dir;
    var earlier = sample;
    earlier.at = 30 * std.time.s_per_day;
    earlier.id = "earlier attempt";
    try root.makePath(attempt_directory);
    var dir = try root.openDir(attempt_directory, .{});
    defer dir.close();
    const early_file = try dir.createFile("30.jsonl", .{});
    try early_file.writeAll(try io.fmt(a, "{s}\n", .{try io.json(a, earlier)}));
    early_file.close();
    const file = try dir.createFile("120.jsonl", .{});
    try file.writeAll(try io.fmt(a, "{s}\n{{\"id\":\"partial", .{try io.json(a, sample)}));
    file.close();
    try t.expectEqual(@as(usize, 1), (try read(a, root, .{ .since = sample.at, .now = sample.at })).len);

    var finish = sample;
    finish.kind = .finished;
    finish.duration_ms = 89;
    finish.outcome = .success;
    try append(a, root, finish);
    try append(a, root, finish);
    const events = try read(a, root, .{ .since = sample.at, .now = sample.at, .repo = "Example/Repo", .pr = 7 });
    try t.expectEqual(@as(usize, 2), events.len);
    try t.expectEqual(.finished, events[0].kind);
    try t.expectEqual(@as(?u64, 89), events[0].duration_ms);
    try t.expectEqual(@as(usize, 0), (try read(a, root, .{ .since = sample.at, .now = sample.at, .pr = 99 })).len);
    try t.expectEqual(@as(usize, 1), (try read(a, root, .{ .since = sample.at, .now = sample.at, .limit = 1 })).len);
    finish.at += 91 * std.time.s_per_day;
    finish.id = "later attempt";
    try append(a, root, finish);
    const history = try read(a, root, .{ .since = earlier.at, .now = finish.at });
    try t.expectEqual(@as(usize, 4), history.len);
    try t.expectEqual(earlier.at, history[3].at);
}

test "parallel telemetry writers keep every record readable" {
    const t = std.testing;
    var scratch = t.tmpDir(.{});
    defer scratch.cleanup();
    const Writer = struct {
        fn run(dir: std.fs.Dir, pr: u32, sink: *?anyerror) void {
            const a = std.heap.page_allocator;
            var event = sample;
            event.scope.pr = pr;
            for (0..24) |index| {
                var id: [80]u8 = undefined;
                event.id = std.fmt.bufPrint(&id, "{d}-{d}", .{ pr, index }) catch unreachable;
                append(a, dir, event) catch |err| {
                    sink.* = err;
                    return;
                };
            }
        }
    };
    var workers: [4]std.Thread = undefined;
    var failures: [4]?anyerror = @splat(null);
    for (&workers, &failures, 0..) |*worker, *failure, index| {
        worker.* = try std.Thread.spawn(.{}, Writer.run, .{ scratch.dir, @as(u32, @intCast(index + 1)), failure });
    }
    for (workers) |worker| worker.join();
    for (failures) |failure| try t.expect(failure == null);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try read(a, scratch.dir, .{ .since = sample.at, .now = sample.at });
    try t.expectEqual(@as(usize, workers.len * 24), rows.len);
    for (1..workers.len + 1) |pr| {
        const filtered = try read(a, scratch.dir, .{ .since = sample.at, .now = sample.at, .pr = @intCast(pr) });
        try t.expectEqual(@as(usize, 24), filtered.len);
        const last_id = try std.fmt.allocPrint(a, "{d}-23", .{pr});
        try t.expectEqualStrings(last_id, filtered[0].id);
    }
}

test "verdicts are durable separately from provider starts" {
    const t = std.testing;
    var scratch = t.tmpDir(.{});
    defer scratch.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try recordVerdict(scratch.dir, .{
        .at = sample.at,
        .repo = sample.scope.repo,
        .pr = sample.scope.pr,
        .head = sample.scope.head,
        .route = .multi,
        .event = .APPROVE,
        .publication = .verified,
        .github_review_id = 81,
        .complete = true,
    });
    try t.expectEqual(@as(usize, 0), (try read(a, scratch.dir, .{ .since = sample.at, .now = sample.at })).len);
    const verdicts = try readVerdicts(a, scratch.dir, .{ .since = sample.at, .now = sample.at, .pr = 7 });
    try t.expectEqual(@as(usize, 1), verdicts.len);
    try t.expectEqual(@as(?u64, 81), verdicts[0].github_review_id);
}
