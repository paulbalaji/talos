const std = @import("std");
const io = @import("io.zig");
const core = @import("core.zig");
const queue = @import("queue.zig");
const followup = @import("followup.zig");
const telemetry = @import("telemetry.zig");
const A = io.A;

pub const State = struct {
    version: u32 = 1,
    default_engines: []const core.Engine = &.{.codex},
    queue_budget: queue.Budget = .{},
    entries: []core.Entry = &.{},
    followups: []followup.Job = &.{},

    pub fn find(self: *State, repo: []const u8) ?*core.Entry {
        for (self.entries) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.repo.name, repo)) return entry;
        }
        return null;
    }

    pub fn add(self: *State, a: A, entry: core.Entry) !void {
        const entries = try a.alloc(core.Entry, self.entries.len + 1);
        @memcpy(entries[0..self.entries.len], self.entries);
        entries[self.entries.len] = entry;
        self.entries = entries;
    }
};

pub const Store = struct {
    a: A,
    path: []const u8,
    dir: std.fs.Dir,

    pub fn open(a: A, path: []const u8) !Store {
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\r\n") != null)
            return error.InvalidTalosHome;
        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {
                try std.fs.cwd().makePath(std.fs.path.dirname(path) orelse return err);
                try std.fs.makeDirAbsolute(path);
            },
            error.PathAlreadyExists => {},
            else => return err,
        };
        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true, .no_follow = true });
        errdefer dir.close();
        const stat = try dir.stat();
        if (stat.mode & 0o077 != 0) return error.TalosHomeMustBePrivate;
        return .{ .a = a, .path = try dir.realpathAlloc(a, "."), .dir = dir };
    }

    pub fn lock(self: Store) !std.fs.File {
        return self.exclusive("watch.lock");
    }

    pub fn batchLock(self: Store) !std.fs.File {
        return self.exclusive("review-batch.lock");
    }

    fn exclusive(self: Store, name: []const u8) !std.fs.File {
        const file = try self.dir.createFile(name, .{ .truncate = false, .mode = 0o600 });
        errdefer file.close();
        if (!try file.tryLock(.exclusive)) return error.AlreadyRunning;
        return file;
    }

    pub fn load(self: Store) !State {
        const data = self.dir.readFileAlloc(self.a, "state.json", 16 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        const state = try io.parse(self.a, State, data);
        if (state.version != 1) return error.UnsupportedStateVersion;
        try core.validateEngines(state.default_engines);
        try state.queue_budget.validate(state.entries);
        return state;
    }

    pub fn save(self: Store, state: *const State) !void {
        try io.writeJson(self.dir, "state.json", state);
    }

    pub fn repoPath(self: Store, repo: []const u8, suffix: []const u8) ![]const u8 {
        return io.fmt(self.a, "repos/{s}/{s}", .{ repo, suffix });
    }

    pub fn paused(self: Store, repo: []const u8) !bool {
        self.dir.access(try self.repoPath(repo, "paused"), .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    pub fn setPaused(self: Store, repo: []const u8, pause: bool) !void {
        const path = try self.repoPath(repo, "paused");
        if (pause) {
            try io.write(self.dir, path, "");
        } else {
            self.dir.deleteFile(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    pub fn readResult(self: Store, repo: []const u8, number: u32) ![]const u8 {
        const path = try self.resultPath(repo, number);
        return self.dir.readFileAlloc(self.a, path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => error.NoLocalReview,
            else => err,
        };
    }

    fn resultPath(self: Store, repo: []const u8, number: u32) ![]const u8 {
        return self.repoPath(repo, try io.fmt(self.a, "results/{d}.json", .{number}));
    }

    fn loadResult(self: Store, repo: []const u8, number: u32) !?core.Result {
        const data = self.readResult(repo, number) catch |err| switch (err) {
            error.NoLocalReview => return null,
            else => return err,
        };
        return try io.parse(self.a, core.Result, data);
    }

    pub fn result(self: Store, repo: []const u8, number: u32, candidate: core.Result) !void {
        const dir = try self.repoPath(repo, "results");
        try self.dir.makePath(dir);
        var saved = candidate;
        var history: [7]core.PastResult = undefined;
        if (try self.loadResult(repo, number)) |prior| {
            var count: usize = 0;
            const same_pending = prior.explanation != null and prior.explanation.?.publication == .pending and
                candidate.explanation != null and candidate.explanation.?.publication == .pending and
                prior.event == candidate.event and io.eq(u8, prior.commit_id, candidate.commit_id) and
                io.eq(u8, prior.followupId(), candidate.followupId());
            if (!same_pending) {
                history[0] = .{ .commit_id = prior.commit_id, .event = prior.event, .explanation = prior.explanation };
                count += 1;
            }
            const retained = @min(prior.history.len, history.len - count);
            @memcpy(history[count..][0..retained], prior.history[0..retained]);
            saved.history = history[0 .. count + retained];
        }
        try io.writeJson(self.dir, try self.resultPath(repo, number), saved);
        if (saved.explanation) |detail| {
            if (detail.publication == .local) self.recordVerdict(repo, number, saved.commit_id, saved.event, detail);
        }
    }

    pub fn confirmResult(self: Store, repo: []const u8, number: u32, head: []const u8, followup_id: []const u8, event: core.Event, id: u64) !void {
        var saved = (try self.loadResult(repo, number)) orelse return;
        const detail = if (saved.event == event and io.eq(u8, saved.commit_id, head) and confirmExplanation(&saved.explanation, followup_id, id))
            saved.explanation.?
        else historical: {
            // An ambiguous submission can outlive a newer head's verdict.
            for (saved.history, 0..) |prior, index| {
                if (prior.event != event or !io.eq(u8, prior.commit_id, head)) continue;
                var updated = prior;
                if (!confirmExplanation(&updated.explanation, followup_id, id)) continue;
                const history = try self.a.dupe(core.PastResult, saved.history);
                history[index] = updated;
                saved.history = history;
                break :historical updated.explanation.?;
            } else return;
        };
        try io.writeJson(self.dir, try self.resultPath(repo, number), saved);
        self.recordVerdict(repo, number, head, event, detail);
    }

    fn recordVerdict(self: Store, repo: []const u8, number: u32, head: []const u8, event: core.Event, detail: core.Explanation) void {
        if (detail.at <= 0) return;
        telemetry.recordVerdict(self.dir, .{
            .repo = repo,
            .pr = number,
            .head = head,
            .event = event,
            .at = detail.at,
            .review_id = detail.followup_id,
            .route = detail.route,
            .complete = detail.coverage.complete,
            .publication = if (detail.publication == .verified) .verified else .local,
            .github_review_id = detail.github_review_id,
        }) catch |err| std.log.warn("verdict telemetry: {s}", .{@errorName(err)});
    }
};

fn confirmExplanation(explanation: *?core.Explanation, followup_id: []const u8, id: u64) bool {
    const detail = if (explanation.*) |*value| value else return false;
    if (detail.publication != .pending or !io.eq(u8, detail.followup_id orelse "", followup_id)) return false;
    detail.publication = .verified;
    detail.github_review_id = id;
    return true;
}

test "results preserve legacy reads and bound same-head history by review identity" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(root) catch {};
    var db = try Store.open(a, root);
    defer db.dir.close();
    const repo = "example/repo";
    const head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const legacy = "{\"commit_id\":\"" ++ head ++ "\",\"event\":\"COMMENT\",\"body\":\"Legacy verdict\",\"comments\":[]}";
    try db.dir.makePath(try db.repoPath(repo, "results"));
    try io.write(db.dir, try db.resultPath(repo, 42), legacy);
    try db.confirmResult(repo, 42, head, "", .COMMENT, 54);
    try t.expectEqualStrings(legacy, try db.readResult(repo, 42));

    var record: core.Result = .{
        .commit_id = head,
        .event = .COMMENT,
        .body = "New verdict",
        .comments = &.{},
        .explanation = .{
            .at = 0,
            .followup_id = null,
            .base = .{ .oid = base, .ref = "main" },
            .merge_base = base,
            .route = .regular,
            .blockers = &.{.limited_coverage},
            .coverage = .{ .complete = false, .snapshot_limited = true, .snapshot_reasons = &.{"Missing current source"}, .supplemental_limited = false, .truncated_threads = 0, .omitted_findings = 0, .reviewers = &.{} },
            .synthesis_provider = null,
            .synthesis_summary = null,
            .evidence_requests = &.{},
            .onchain_observations = &.{},
            .publication = .pending,
        },
    };
    for (0..9) |index| {
        record.explanation.?.followup_id = try io.fmt(a, "{d}", .{index});
        try db.result(repo, 42, record);
    }
    try db.result(repo, 42, record);
    try db.confirmResult(repo, 42, head, "7", .COMMENT, 55);
    var saved = (try db.loadResult(repo, 42)).?;
    try t.expectEqual(.pending, saved.explanation.?.publication);
    try t.expectEqual(@as(usize, 7), saved.history.len);
    try t.expectEqualStrings("7", saved.history[0].explanation.?.followup_id.?);
    try t.expectEqual(.verified, saved.history[0].explanation.?.publication);
    try t.expectEqual(@as(?u64, 55), saved.history[0].explanation.?.github_review_id);
    try t.expectEqualStrings("1", saved.history[6].explanation.?.followup_id.?);
    try db.confirmResult(repo, 42, head, "8", .COMMENT, 56);
    try db.confirmResult(repo, 42, head, "8", .COMMENT, 57);
    saved = (try db.loadResult(repo, 42)).?;
    try t.expectEqual(.verified, saved.explanation.?.publication);
    try t.expectEqual(@as(?u64, 56), saved.explanation.?.github_review_id);
    try t.expectEqual(@as(?u64, 55), saved.history[0].explanation.?.github_review_id);

    record.explanation.?.followup_id = null;
    record.explanation.?.publication = .local;
    try db.result(repo, 42, record);
    record.explanation.?.at = 1;
    try db.result(repo, 42, record);
    saved = (try db.loadResult(repo, 42)).?;
    try t.expectEqual(.local, saved.history[0].explanation.?.publication);
    try t.expectEqual(@as(i64, 0), saved.history[0].explanation.?.at);
    try t.expectEqual(.verified, saved.history[1].explanation.?.publication);

    record.explanation.?.publication = .pending;
    try db.result(repo, 42, record);
    const newer = "cccccccccccccccccccccccccccccccccccccccc";
    record.commit_id = newer;
    try db.result(repo, 42, record);
    try db.confirmResult(repo, 42, head, "", .COMMENT, 58);
    saved = (try db.loadResult(repo, 42)).?;
    try t.expectEqualStrings(newer, saved.commit_id);
    try t.expectEqual(.pending, saved.explanation.?.publication);
    try t.expectEqualStrings(head, saved.history[0].commit_id);
    try t.expectEqual(.verified, saved.history[0].explanation.?.publication);
    try t.expectEqual(@as(?u64, 58), saved.history[0].explanation.?.github_review_id);

    try db.confirmResult(repo, 42, newer, "", .COMMENT, 59);
    record.explanation.?.publication = .local;
    try db.result(repo, 42, record);
    saved = (try db.loadResult(repo, 42)).?;
    try t.expectEqual(.local, saved.explanation.?.publication);
    try t.expectEqualStrings(newer, saved.history[0].commit_id);
    try t.expectEqual(.verified, saved.history[0].explanation.?.publication);
    try t.expectEqual(@as(?u64, 59), saved.history[0].explanation.?.github_review_id);
}
