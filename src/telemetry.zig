const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");
const routing = @import("routing.zig");
const posix = std.posix;

pub const Stage = enum { review, screen, completion, synthesis, preview, followup };
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

fn segmentName(buffer: *[32]u8, day: i64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}" ++ suffix, .{day});
}

fn openSegment(dir: std.fs.Dir, name: []const u8, flags: posix.O) !std.fs.File {
    const file: std.fs.File = .{ .handle = try posix.openat(dir.fd, name, flags, 0o600) };
    errdefer file.close();
    const stat = try posix.fstat(file.handle);
    if (stat.mode & posix.S.IFMT != posix.S.IFREG or stat.nlink != 1) return error.InvalidTelemetryFile;
    return file;
}

fn repairTail(file: std.fs.File) !u64 {
    const size = try file.getEndPos();
    if (size == 0) return 0;
    var last: [1]u8 = undefined;
    if (try file.preadAll(&last, size - 1) != last.len) return error.TelemetryChanged;
    if (last[0] == '\n') return size;

    // A previous write may have stopped mid-record. Remove just its tail
    // under the same lock that serializes append operations.
    var buffer: [max_event_bytes]u8 = undefined;
    const offset = size -| buffer.len;
    const count = try file.preadAll(&buffer, offset);
    const end = if (std.mem.lastIndexOfScalar(u8, buffer[0..count], '\n')) |index|
        offset + index + 1
    else if (offset == 0)
        0
    else
        return error.InvalidTelemetryTail;
    try file.setEndPos(end);
    return end;
}

pub fn append(a: io.A, root: std.fs.Dir, event: Event) !void {
    try appendRecord(a, root, attempt_directory, event);
}

pub fn recordVerdict(root: std.fs.Dir, verdict: Verdict) !void {
    try appendRecord(std.heap.page_allocator, root, verdict_directory, verdict);
}

fn appendRecord(a: io.A, root: std.fs.Dir, directory: []const u8, record: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(a, record, .{ .emit_null_optional_fields = false });
    defer a.free(json);
    const encoded = try std.fmt.allocPrint(a, "{s}\n", .{json});
    defer a.free(encoded);
    if (encoded.len > max_event_bytes) return error.TelemetryRecordTooLarge;
    root.makeDir(directory) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try root.openDir(directory, .{ .no_follow = true });
    defer dir.close();
    const day = @divFloor(record.at, std.time.s_per_day);
    var name_buffer: [32]u8 = undefined;
    const name = try segmentName(&name_buffer, day);
    const base: posix.O = .{ .ACCMODE = .RDWR, .APPEND = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true };
    var create = base;
    create.CREAT = true;
    create.EXCL = true;
    const file = openSegment(dir, name, create) catch |err| switch (err) {
        error.PathAlreadyExists => try openSegment(dir, name, base),
        else => return err,
    };
    defer file.close();
    try file.lock(.exclusive);
    defer file.unlock();
    const size = try repairTail(file);
    if (size + encoded.len > max_day_bytes) return error.TelemetryDayLimit;
    try file.writeAll(encoded);
    try file.sync();
}

fn matches(record: anytype, query: Query) bool {
    const repo_name = if (@TypeOf(record) == Event) record.scope.repo else record.repo;
    const number = if (@TypeOf(record) == Event) record.scope.pr else record.pr;
    if (query.repo) |repo| if (!std.ascii.eqlIgnoreCase(repo, repo_name)) return false;
    if (query.pr) |pr| if (pr != number) return false;
    return record.at >= query.since;
}

fn copyOptional(a: io.A, value: ?[]const u8) !?[]const u8 {
    return if (value) |str| try a.dupe(u8, str) else null;
}

fn copyRecord(a: io.A, record: anytype) !@TypeOf(record) {
    var copy = record;
    if (@TypeOf(record) == Event) {
        copy.id = try a.dupe(u8, record.id);
        copy.scope.repo = try a.dupe(u8, record.scope.repo);
        copy.scope.head = try a.dupe(u8, record.scope.head);
        copy.scope.review_id = try copyOptional(a, record.scope.review_id);
        copy.model = try a.dupe(u8, record.model);
        copy.error_name = try copyOptional(a, record.error_name);
        if (record.model_usage.len != 0) {
            const usage = try a.dupe(ModelUsage, record.model_usage);
            for (usage) |*model| model.model = try a.dupe(u8, model.model);
            copy.model_usage = usage;
        }
    } else {
        copy.repo = try a.dupe(u8, record.repo);
        copy.head = try a.dupe(u8, record.head);
        copy.review_id = try copyOptional(a, record.review_id);
    }
    return copy;
}

// Reads newest records first, holding one day's bytes at a time.
// An incomplete final record is invisible.
pub fn read(a: io.A, root: std.fs.Dir, query: Query) ![]const Event {
    return readRecords(a, root, attempt_directory, Event, query);
}

pub fn readVerdicts(a: io.A, root: std.fs.Dir, query: Query) ![]const Verdict {
    return readRecords(a, root, verdict_directory, Verdict, query);
}

fn readRecords(a: io.A, root: std.fs.Dir, directory: []const u8, comptime Record: type, query: Query) ![]const Record {
    const limit = @min(query.limit, max_query_events);
    if (limit == 0) return &.{};
    var dir = root.openDir(directory, .{ .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close();
    const today = @divFloor(query.now orelse std.time.timestamp(), std.time.s_per_day);
    const first = @divFloor(query.since, std.time.s_per_day);
    var found: std.ArrayList(Record) = .empty;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var day_buffer: std.ArrayList(u8) = .empty;
    defer day_buffer.deinit(std.heap.page_allocator);
    var day = today;
    while (day >= first and found.items.len < limit) : (day -= 1) {
        var name_buffer: [32]u8 = undefined;
        const file = openSegment(dir, try segmentName(&name_buffer, day), .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer file.close();
        try day_buffer.resize(std.heap.page_allocator, @intCast(@min(try file.getEndPos(), max_day_bytes)));
        const raw = day_buffer.items[0..try file.preadAll(day_buffer.items, 0)];
        var end = std.mem.lastIndexOfScalar(u8, raw, '\n') orelse continue;
        while (found.items.len < limit) {
            const offset = std.mem.lastIndexOfScalar(u8, raw[0..end], '\n');
            const line = if (offset) |start| raw[start + 1 .. end] else raw[0..end];
            if (line.len != 0 and line.len <= max_event_bytes) {
                defer _ = scratch.reset(.retain_capacity);
                if (std.json.parseFromSliceLeaky(Record, scratch.allocator(), line, .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed })) |record| {
                    if (matches(record, query)) try found.append(a, try copyRecord(a, record));
                } else |err| {
                    if (err == error.OutOfMemory) return err;
                }
            }
            end = offset orelse break;
        }
    }
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

test "interrupted appends recover and later writes leave older days readable" {
    const t = std.testing;
    var scratch = t.tmpDir(.{});
    defer scratch.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = scratch.dir;
    var earlier = sample;
    earlier.at = 30 * std.time.s_per_day;
    try append(a, root, earlier);
    try append(a, root, sample);

    var dir = try root.openDir(attempt_directory, .{});
    defer dir.close();
    const file = try dir.openFile("120.jsonl", .{ .mode = .read_write });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll("{\"id\":\"partial");
    try t.expectEqual(@as(usize, 1), (try read(a, root, .{ .since = sample.at, .now = sample.at })).len);

    var finish = sample;
    finish.kind = .finished;
    finish.duration_ms = 89;
    finish.outcome = .success;
    try append(a, root, finish);
    const events = try read(a, root, .{ .since = sample.at, .now = sample.at, .repo = "Example/Repo", .pr = 7 });
    try t.expectEqual(@as(usize, 2), events.len);
    try t.expectEqual(.finished, events[0].kind);
    try t.expectEqual(@as(?u64, 89), events[0].duration_ms);
    try t.expectEqual(@as(usize, 0), (try read(a, root, .{ .since = sample.at, .now = sample.at, .pr = 99 })).len);
    try t.expectEqual(@as(usize, 1), (try read(a, root, .{ .since = sample.at, .now = sample.at, .limit = 1 })).len);
    finish.at += 91 * std.time.s_per_day;
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
