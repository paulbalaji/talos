const std = @import("std");
const io = @import("io.zig");
const core = @import("core.zig");
const queue = @import("queue.zig");
const followup = @import("followup.zig");
const telemetry = @import("telemetry.zig");
const sqlite = @import("sqlite.zig");
const usage = @import("usage.zig");
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

const StateSettings = struct {
    version: u32 = 1,
    default_engines: []const core.Engine = &.{.codex},
    queue_budget: queue.Budget = .{},
    followups: []followup.Job = &.{},
};

const migration_key = "legacy_state_imported";
const state_key = "scheduler_state";
const pass_ttl = 7 * std.time.s_per_day;

pub const PassClaim = union(enum) {
    cached: []const u8,
    claimed: [16]u8,
    busy: i64,
};

pub const ResultFile = struct {
    repo: []const u8,
    number: u32,
    changed_at: i64,
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
        const real_path = try dir.realpathAlloc(a, ".");
        errdefer a.free(real_path);
        const store: Store = .{ .a = a, .path = real_path, .dir = dir };
        try store.migrate();
        return store;
    }

    fn migrate(self: Store) !void {
        const db = try self.connect();
        defer db.close();
        if (try db.hasSetting(migration_key)) return;
        try db.beginWrite();
        errdefer db.rollback();
        if (!try db.hasSetting(migration_key)) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            if (try readLegacy(self.dir, a, "state.json", 16 * 1024 * 1024)) |data| {
                const state = try io.parse(a, State, data);
                try saveState(db, &state);
            }
            try importRepositories(db, self.dir);
            try telemetry.migrate(db, self.dir);
            try usage.migrate(db, self.dir);
            try db.setSetting(migration_key, "1");
        }
        try db.commit();
    }

    fn connect(self: Store) !sqlite.Db {
        return sqlite.Db.open(self.a, self.dir);
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
        const db = try self.connect();
        defer db.close();
        try db.beginRead();
        errdefer db.rollback();
        const state = try loadState(db, self.a);
        try db.commit();
        return state;
    }

    pub fn save(self: Store, state: *const State) !void {
        const db = try self.connect();
        defer db.close();
        try db.beginWrite();
        errdefer db.rollback();
        try saveState(db, state);
        try db.commit();
    }

    pub fn repoPath(self: Store, repo: []const u8, suffix: []const u8) ![]const u8 {
        return io.fmt(self.a, "repos/{s}/{s}", .{ repo, suffix });
    }

    pub fn paused(self: Store, repo: []const u8) !bool {
        const db = try self.connect();
        defer db.close();
        return isPaused(db, repo);
    }

    fn isPaused(db: sqlite.Db, repo: []const u8) !bool {
        const row = try db.prepare("SELECT 1 FROM paused_repository WHERE name=?");
        defer row.close();
        try row.bind(.{repo});
        return row.step();
    }

    pub fn setPaused(self: Store, repo: []const u8, pause: bool) !void {
        const db = try self.connect();
        defer db.close();
        return db.run(if (pause) "INSERT OR IGNORE INTO paused_repository VALUES (?)" else "DELETE FROM paused_repository WHERE name=?", .{repo});
    }

    pub fn readResult(self: Store, repo: []const u8, number: u32) ![]const u8 {
        const db = try self.connect();
        defer db.close();
        const row = try db.prepare("SELECT payload FROM review_result WHERE repo=? AND number=?");
        defer row.close();
        try row.bind(.{ repo, number });
        if (!try row.step()) return error.NoLocalReview;
        return self.a.dupe(u8, row.bytes(0));
    }

    pub fn listResults(self: Store, since: i64, limit: usize) ![]const ResultFile {
        const db = try self.connect();
        defer db.close();
        const rows = try db.prepare(
            "SELECT repo, number, changed_at FROM review_result WHERE changed_at>=? ORDER BY changed_at DESC, repo, number LIMIT ?",
        );
        defer rows.close();
        try rows.bind(.{ since, limit });
        var results: std.ArrayList(ResultFile) = .empty;
        while (try rows.step()) try results.append(self.a, .{
            .repo = try self.a.dupe(u8, rows.bytes(0)),
            .number = std.math.cast(u32, rows.int(1)) orelse return error.InvalidDatabase,
            .changed_at = rows.int(2),
        });
        return results.toOwnedSlice(self.a);
    }

    fn loadResult(self: Store, repo: []const u8, number: u32) !?core.Result {
        const db = try self.connect();
        defer db.close();
        return readResultRow(db, self.a, repo, number);
    }

    pub fn result(self: Store, repo: []const u8, number: u32, candidate: core.Result) !void {
        const db = try self.connect();
        defer db.close();
        try db.beginWrite();
        errdefer db.rollback();
        try saveReview(db, self.a, repo, number, candidate);
        try db.commit();
    }

    pub fn saveResultAndState(self: Store, repo: []const u8, number: u32, candidate: core.Result, state: *const State) !void {
        const db = try self.connect();
        defer db.close();
        try db.beginWrite();
        errdefer db.rollback();
        if (candidate.explanation) |detail| {
            if (detail.publication == .pending and try isPaused(db, repo)) return error.RepoPaused;
        }
        try saveReview(db, self.a, repo, number, candidate);
        try saveState(db, state);
        try db.commit();
    }

    pub fn confirmResult(self: Store, repo: []const u8, number: u32, head: []const u8, followup_id: []const u8, event: core.Event, id: u64) !void {
        const db = try self.connect();
        defer db.close();
        try db.beginWrite();
        errdefer db.rollback();
        try confirmReview(db, self.a, repo, number, head, followup_id, event, id);
        try db.commit();
    }

    pub fn confirmResultAndState(self: Store, repo: []const u8, number: u32, head: []const u8, followup_id: []const u8, event: core.Event, id: u64, state: *const State) !void {
        const db = try self.connect();
        defer db.close();
        try db.beginWrite();
        errdefer db.rollback();
        try confirmReview(db, self.a, repo, number, head, followup_id, event, id);
        try saveState(db, state);
        try db.commit();
    }

    /// Only call after taking the provider batch lock, when no prior worker
    /// could still be finishing one of these leases.
    pub fn recoverPasses(self: Store, now: i64) !void {
        const db = try self.connect();
        defer db.close();
        try db.run(
            \\DELETE FROM reviewer_pass WHERE key IN (
            \\    SELECT key FROM reviewer_pass WHERE lease IS NOT NULL
            \\    UNION ALL
            \\    SELECT key FROM reviewer_pass WHERE finished_at<?
            \\)
        , .{now -| pass_ttl});
    }

    pub fn claimPass(self: Store, key: [32]u8, now: i64, lease_until: i64) !PassClaim {
        if (lease_until <= now) return error.InvalidPassLease;
        const db = try self.connect();
        defer db.close();
        try db.beginWrite();
        errdefer db.rollback();
        const encoded: sqlite.Blob = .{ .bytes = &key };
        if (try self.readPass(db, encoded, now)) |claim| {
            try db.commit();
            return claim;
        }
        var lease: [16]u8 = undefined;
        std.crypto.random.bytes(&lease);
        const token: sqlite.Blob = .{ .bytes = &lease };
        try db.run(
            \\INSERT INTO reviewer_pass(key, lease, lease_until) VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET
            \\lease=excluded.lease, lease_until=excluded.lease_until, payload=NULL, finished_at=NULL
        , .{ encoded, token, lease_until });
        try db.commit();
        return .{ .claimed = lease };
    }

    fn readPass(self: Store, db: sqlite.Db, key: sqlite.Blob, now: i64) !?PassClaim {
        const row = try db.prepare("SELECT payload, lease_until, finished_at FROM reviewer_pass WHERE key=?");
        defer row.close();
        try row.bind(.{key});
        if (!try row.step()) return null;
        if (!row.isNull(0)) {
            if (row.int(2) < now -| pass_ttl) return null;
            return .{ .cached = try self.a.dupe(u8, row.bytes(0)) };
        }
        const until = row.int(1);
        return if (until > now) .{ .busy = until } else null;
    }

    pub fn finishPass(self: Store, key: [32]u8, lease: [16]u8, accepted: ?[]const u8, now: i64) !bool {
        const db = try self.connect();
        defer db.close();
        const encoded: sqlite.Blob = .{ .bytes = &key };
        const token: sqlite.Blob = .{ .bytes = &lease };
        if (accepted) |payload| {
            if (payload.len > 128 * 1024) return error.PassPayloadTooLarge;
            try db.run(
                "UPDATE reviewer_pass SET payload=?, finished_at=?, lease=NULL, lease_until=0 WHERE key=? AND lease=?",
                .{ payload, now, encoded, token },
            );
        } else {
            try db.run("DELETE FROM reviewer_pass WHERE key=? AND lease=?", .{ encoded, token });
        }
        return db.changed();
    }
};

fn validate(state: State) !void {
    if (state.version != 1) return error.UnsupportedStateVersion;
    try core.validateEngines(state.default_engines);
    try state.queue_budget.validate(state.entries);
}

fn loadState(db: sqlite.Db, a: A) !State {
    const raw = (try db.setting(a, state_key)) orelse return .{};
    defer a.free(raw);
    const settings = try io.parse(a, StateSettings, raw);
    var entries: std.ArrayList(core.Entry) = .empty;
    const repos = try db.prepare("SELECT name, payload FROM repository ORDER BY position");
    defer repos.close();
    const jobs = try db.prepare("SELECT payload FROM review_job WHERE repo=? ORDER BY position");
    defer jobs.close();
    while (try repos.step()) {
        var entry = try io.parse(a, core.Entry, repos.bytes(1));
        var list: std.ArrayList(core.Job) = .empty;
        try jobs.bind(.{repos.bytes(0)});
        while (try jobs.step()) try list.append(a, try io.parse(a, core.Job, jobs.bytes(0)));
        try jobs.reset();
        entry.jobs = try list.toOwnedSlice(a);
        try entries.append(a, entry);
    }
    const state: State = .{
        .version = settings.version,
        .default_engines = settings.default_engines,
        .queue_budget = settings.queue_budget,
        .followups = settings.followups,
        .entries = try entries.toOwnedSlice(a),
    };
    try validate(state);
    return state;
}

fn saveState(db: sqlite.Db, state: *const State) !void {
    try validate(state.*);
    const a = std.heap.page_allocator;
    const settings: StateSettings = .{
        .version = state.version,
        .default_engines = state.default_engines,
        .queue_budget = state.queue_budget,
        .followups = state.followups,
    };
    const encoded = try io.json(a, settings);
    defer a.free(encoded);
    try db.setSetting(state_key, encoded);

    // Preserve queue order and remove only missing keys. Unchanged rows are
    // not rewritten, even when the coordinator saves a full in-memory view.
    try db.exec(
        \\CREATE TEMP TABLE live_repo (name TEXT PRIMARY KEY COLLATE NOCASE);
        \\CREATE TEMP TABLE live_job (repo TEXT COLLATE NOCASE, number INTEGER, head TEXT, PRIMARY KEY(repo,number,head));
    );
    const live_repo = try db.prepare("INSERT INTO live_repo VALUES (?)");
    defer live_repo.close();
    const live_job = try db.prepare("INSERT INTO live_job VALUES (?,?,?)");
    defer live_job.close();
    const repo_stmt = try db.prepare(
        \\INSERT INTO repository VALUES (?,?,?) ON CONFLICT(name) DO UPDATE SET position=excluded.position,payload=excluded.payload
        \\WHERE repository.position<>excluded.position OR repository.payload<>excluded.payload
    );
    defer repo_stmt.close();
    const job_stmt = try db.prepare(
        \\INSERT INTO review_job VALUES (?,?,?,?,?) ON CONFLICT(repo,number,head) DO UPDATE SET position=excluded.position,payload=excluded.payload
        \\WHERE review_job.position<>excluded.position OR review_job.payload<>excluded.payload
    );
    defer job_stmt.close();
    for (state.entries, 0..) |entry, index| {
        try live_repo.run(.{entry.repo.name});
        var repo = entry;
        repo.jobs = &.{};
        const payload = try io.json(a, repo);
        defer a.free(payload);
        try repo_stmt.run(.{ entry.repo.name, index, payload });
        for (entry.jobs, 0..) |job, position| {
            try live_job.run(.{ entry.repo.name, job.number, job.head });
            const data = try io.json(a, job);
            defer a.free(data);
            try job_stmt.run(.{ entry.repo.name, job.number, job.head, position, data });
        }
    }
    try db.exec(
        \\DELETE FROM review_job WHERE NOT EXISTS (SELECT 1 FROM live_job
        \\    WHERE repo=review_job.repo AND number=review_job.number AND head=review_job.head);
        \\DELETE FROM repository WHERE NOT EXISTS (SELECT 1 FROM live_repo WHERE name=repository.name);
    );
}

fn readLegacy(dir: std.fs.Dir, a: A, path: []const u8, max_bytes: usize) !?[]const u8 {
    const fd = std.posix.openat(dir.fd, path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    const stat = try std.posix.fstat(fd);
    if (stat.mode & std.posix.S.IFMT != std.posix.S.IFREG or stat.nlink != 1) return error.InvalidLegacyStateFile;
    return try file.readToEndAlloc(a, max_bytes);
}

fn openLegacy(parent: std.fs.Dir, path: []const u8) !?std.fs.Dir {
    return parent.openDir(path, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn importRepositories(db: sqlite.Db, root: std.fs.Dir) !void {
    var repos = (try openLegacy(root, "repos")) orelse return;
    defer repos.close();
    var owners = repos.iterate();
    while (try owners.next()) |owner| {
        if (owner.kind != .directory) continue;
        var owner_dir = (try openLegacy(repos, owner.name)) orelse continue;
        defer owner_dir.close();
        var children = owner_dir.iterate();
        while (try children.next()) |child| {
            if (child.kind != .directory) continue;
            var name_buffer: [152]u8 = undefined;
            const repo = std.fmt.bufPrint(&name_buffer, "{s}/{s}", .{ owner.name, child.name }) catch continue;
            if (!core.validRepoName(repo)) continue;
            var repo_dir = (try openLegacy(owner_dir, child.name)) orelse continue;
            defer repo_dir.close();
            if (repo_dir.access("paused", .{})) |_| {
                try db.run("INSERT OR IGNORE INTO paused_repository VALUES (?)", .{repo});
            } else |err| if (err != error.FileNotFound) return err;
            try importResults(db, repo_dir, repo);
        }
    }
}

fn importResults(db: sqlite.Db, repo_dir: std.fs.Dir, repo: []const u8) !void {
    var dir = (try openLegacy(repo_dir, "results")) orelse return;
    defer dir.close();
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var results = dir.iterate();
    while (try results.next()) |file| {
        const suffix = ".json";
        if (file.kind != .file or !std.mem.endsWith(u8, file.name, suffix)) continue;
        const number = std.fmt.parseInt(u32, file.name[0 .. file.name.len - suffix.len], 10) catch continue;
        if (number == 0) continue;
        defer _ = scratch.reset(.retain_capacity);
        const data = (try readLegacy(dir, a, file.name, 4 * 1024 * 1024)) orelse continue;
        const stat = try dir.statFile(file.name);
        try putResult(db, repo, number, @intCast(@divFloor(stat.mtime, std.time.ns_per_s)), data);
        const record = try io.parse(a, core.Result, data);
        if (record.explanation) |detail| try saveIntent(db, a, repo, number, record.commit_id, record.event, detail);
        for (record.history) |old| if (old.explanation) |detail| try saveIntent(db, a, repo, number, old.commit_id, old.event, detail);
    }
}

fn putResult(db: sqlite.Db, repo: []const u8, number: u32, changed_at: i64, data: []const u8) !void {
    try db.run(
        \\INSERT INTO review_result VALUES (?,?,?,?) ON CONFLICT(repo,number) DO UPDATE SET
        \\changed_at=excluded.changed_at,payload=excluded.payload
    , .{ repo, number, changed_at, data });
}

fn readResultRow(db: sqlite.Db, a: A, repo: []const u8, number: u32) !?core.Result {
    const row = try db.prepare("SELECT payload FROM review_result WHERE repo=? AND number=?");
    defer row.close();
    try row.bind(.{ repo, number });
    return if (try row.step()) try io.parse(a, core.Result, row.bytes(0)) else null;
}

fn saveReview(db: sqlite.Db, a: A, repo: []const u8, number: u32, candidate: core.Result) !void {
    var saved = candidate;
    var history: [7]core.PastResult = undefined;
    if (try readResultRow(db, a, repo, number)) |prior| {
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
    const encoded = try io.json(a, saved);
    defer a.free(encoded);
    try putResult(db, repo, number, std.time.timestamp(), encoded);
    if (saved.explanation) |detail| {
        try saveIntent(db, a, repo, number, saved.commit_id, saved.event, detail);
        if (detail.publication == .local) try recordVerdict(db, a, repo, number, saved.commit_id, saved.event, detail);
    }
}

fn saveIntent(db: sqlite.Db, a: A, repo: []const u8, number: u32, head: []const u8, event: core.Event, detail: core.Explanation) !void {
    if (detail.publication != .pending) return;
    const encoded = try io.json(a, detail);
    defer a.free(encoded);
    try db.run(
        \\INSERT INTO publication_intent VALUES (?,?,?,?,?,?) ON CONFLICT(repo,number,head,event,review_key)
        \\DO UPDATE SET payload=excluded.payload
    , .{ repo, number, head, @tagName(event), detail.followup_id orelse "", encoded });
}

fn confirmReview(db: sqlite.Db, a: A, repo: []const u8, number: u32, head: []const u8, followup_id: []const u8, event: core.Event, id: u64) !void {
    if (try readResultRow(db, a, repo, number)) |original| {
        var saved = original;
        if (try confirmRecent(a, &saved, head, followup_id, event, id)) |detail| {
            const encoded = try io.json(a, saved);
            defer a.free(encoded);
            try putResult(db, repo, number, std.time.timestamp(), encoded);
            try recordVerdict(db, a, repo, number, head, event, detail);
            try removeIntent(db, repo, number, head, event, followup_id);
            return;
        }
    }
    // Reconciliation is independent of the bounded display history.
    const intent = try db.prepare("SELECT payload FROM publication_intent WHERE repo=? AND number=? AND head=? AND event=? AND review_key=?");
    defer intent.close();
    try intent.bind(.{ repo, number, head, @tagName(event), followup_id });
    if (!try intent.step()) return;
    var detail: ?core.Explanation = try io.parse(a, core.Explanation, intent.bytes(0));
    try intent.reset();
    if (!confirmExplanation(&detail, followup_id, id)) return;
    try recordVerdict(db, a, repo, number, head, event, detail.?);
    try removeIntent(db, repo, number, head, event, followup_id);
}

fn confirmRecent(a: A, saved: *core.Result, head: []const u8, followup_id: []const u8, event: core.Event, id: u64) !?core.Explanation {
    if (saved.event == event and io.eq(u8, saved.commit_id, head) and confirmExplanation(&saved.explanation, followup_id, id))
        return saved.explanation.?;
    for (saved.history, 0..) |prior, index| {
        if (prior.event != event or !io.eq(u8, prior.commit_id, head)) continue;
        var updated = prior;
        if (!confirmExplanation(&updated.explanation, followup_id, id)) continue;
        const history = try a.dupe(core.PastResult, saved.history);
        history[index] = updated;
        saved.history = history;
        return updated.explanation.?;
    }
    return null;
}

fn removeIntent(db: sqlite.Db, repo: []const u8, number: u32, head: []const u8, event: core.Event, followup_id: []const u8) !void {
    try db.run("DELETE FROM publication_intent WHERE repo=? AND number=? AND head=? AND event=? AND review_key=?", .{ repo, number, head, @tagName(event), followup_id });
}

fn recordVerdict(db: sqlite.Db, a: A, repo: []const u8, number: u32, head: []const u8, event: core.Event, detail: core.Explanation) !void {
    if (detail.at <= 0) return;
    try telemetry.putVerdict(db, a, .{
        .repo = repo,
        .pr = number,
        .head = head,
        .event = event,
        .at = detail.at,
        .review_id = detail.followup_id,
        .route = detail.route,
        .complete = detail.coverage.complete,
        .publication = if (detail.publication == .verified) .verified else .local,
        .disposition = detail.disposition,
        .github_review_id = detail.github_review_id,
    });
}

fn confirmExplanation(explanation: *?core.Explanation, followup_id: []const u8, id: u64) bool {
    const detail = if (explanation.*) |*value| value else return false;
    if (detail.publication != .pending or !io.eq(u8, detail.followup_id orelse "", followup_id)) return false;
    detail.publication = .verified;
    detail.disposition = .posted;
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
    const repo = "example/repo";
    const head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const legacy = "{\"commit_id\":\"" ++ head ++ "\",\"event\":\"COMMENT\",\"body\":\"Legacy verdict\",\"comments\":[]}";
    const legacy_path = "repos/example/repo/results/42.json";
    {
        var dir = try std.fs.openDirAbsolute(root, .{});
        defer dir.close();
        try dir.makePath("repos/example/repo/results");
        try io.write(dir, legacy_path, legacy);
    }
    var db = try Store.open(a, root);
    defer db.dir.close();
    try db.confirmResult(repo, 42, head, "", .COMMENT, 54);
    try t.expectEqualStrings(legacy, try db.readResult(repo, 42));
    const imported = try db.listResults(0, 2);
    try t.expectEqual(@as(usize, 1), imported.len);
    try t.expectEqual(@as(u32, 42), imported[0].number);

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

test "publication intent verdict and job update commit together and surviving intents can be reconciled" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(root) catch {};
    var db = try Store.open(a, root);
    defer db.dir.close();
    const repo = "example/repo";
    const head = "a" ** 40;
    const base = "b" ** 40;
    var jobs = [_]core.Job{.{ .number = 42, .head = head }};
    var entries = [_]core.Entry{.{ .repo = .{ .name = repo, .login = "reviewer" }, .jobs = &jobs }};
    var state: State = .{ .entries = &entries };
    try db.save(&state);

    var candidate: core.Result = .{
        .commit_id = head,
        .event = .APPROVE,
        .body = "",
        .comments = &.{},
        .explanation = .{
            .at = 1,
            .followup_id = "original",
            .base = .{ .oid = base, .ref = "main" },
            .merge_base = base,
            .route = .regular,
            .blockers = &.{},
            .coverage = .{ .complete = true, .snapshot_limited = false, .snapshot_reasons = &.{}, .supplemental_limited = false, .truncated_threads = 0, .omitted_findings = 0, .reviewers = &.{} },
            .synthesis_provider = null,
            .synthesis_summary = null,
            .evidence_requests = &.{},
            .onchain_observations = &.{},
            .publication = .pending,
        },
    };
    jobs[0].phase = .uncertain;
    jobs[0].event = .APPROVE;
    try db.setPaused(repo, true);
    try t.expectError(error.RepoPaused, db.saveResultAndState(repo, 42, candidate, &state));
    try t.expectError(error.NoLocalReview, db.readResult(repo, 42));
    try db.setPaused(repo, false);
    state.version = 99;
    try t.expectError(error.UnsupportedStateVersion, db.saveResultAndState(repo, 42, candidate, &state));
    try t.expectError(error.NoLocalReview, db.readResult(repo, 42));
    const before = try db.load();
    try t.expectEqual(.pending, before.entries[0].jobs[0].phase);

    state.version = 1;
    try db.saveResultAndState(repo, 42, candidate, &state);
    const pending = try db.load();
    try t.expectEqual(.uncertain, pending.entries[0].jobs[0].phase);
    try t.expectEqual(.pending, (try db.loadResult(repo, 42)).?.explanation.?.publication);

    for (2..11) |index| {
        candidate.explanation.?.at = @intCast(index);
        candidate.explanation.?.followup_id = try io.fmt(a, "followup-{d}", .{index});
        try db.result(repo, 42, candidate);
    }
    const latest = (try db.loadResult(repo, 42)).?;
    try t.expectEqual(@as(usize, 7), latest.history.len);
    try t.expectEqualStrings("followup-3", latest.history[6].explanation.?.followup_id.?);

    jobs[0].phase = .complete;
    jobs[0].receipt = 123;
    state.version = 99;
    try t.expectError(error.UnsupportedStateVersion, db.confirmResultAndState(repo, 42, head, "original", .APPROVE, 123, &state));
    try t.expectEqual(@as(usize, 0), (try telemetry.readVerdicts(a, db.dir, .{ .since = 0 })).len);
    const still_pending = try db.load();
    try t.expectEqual(.uncertain, still_pending.entries[0].jobs[0].phase);

    state.version = 1;
    try db.confirmResultAndState(repo, 42, head, "original", .APPROVE, 123, &state);
    try db.confirmResultAndState(repo, 42, head, "original", .APPROVE, 124, &state);
    const verified = try db.load();
    try t.expectEqual(.complete, verified.entries[0].jobs[0].phase);
    try t.expectEqual(@as(?u64, 123), verified.entries[0].jobs[0].receipt);
    const verdicts = try telemetry.readVerdicts(a, db.dir, .{ .since = 0 });
    try t.expectEqual(@as(usize, 1), verdicts.len);
    try t.expectEqual(.verified, verdicts[0].publication);
    try t.expectEqual(@as(?u64, 123), verdicts[0].github_review_id);
    try t.expectEqual(.posted, verdicts[0].disposition);
}

test "pass leases reject stale owners and recover accepted work on restart" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(root) catch {};
    var db = try Store.open(a, root);
    defer db.dir.close();
    const key: [32]u8 = @splat(72);
    const accepted_key: [32]u8 = @splat(73);
    const first = try db.claimPass(key, 1, 10);
    try t.expectEqual(@as(i64, 10), (try db.claimPass(key, 2, 10)).busy);
    const second = try db.claimPass(key, 10, 100);
    try t.expect(!try db.finishPass(key, first.claimed, "stale body", 10));
    const ready = try db.claimPass(accepted_key, 10, 100);
    try t.expect(try db.finishPass(accepted_key, ready.claimed, "accepted body", 11));
    var reopened = try Store.open(a, root);
    defer reopened.dir.close();
    try reopened.recoverPasses(12);
    try t.expect(!try reopened.finishPass(key, second.claimed, "orphaned body", 13));
    try t.expect((try reopened.claimPass(key, 13, 20)) == .claimed);
    try t.expectEqualStrings("accepted body", (try reopened.claimPass(accepted_key, 13, 20)).cached);
    try reopened.recoverPasses(12 + pass_ttl);
    try t.expect((try reopened.claimPass(accepted_key, 13 + pass_ttl, 20 + pass_ttl)) == .claimed);
}
