const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");

pub const directory = "objects.git";
const marker = "talos-cache-v1";
pub const check_interval = 60 * 60;
const day_seconds = 24 * 60 * 60;

pub const Cache = struct {
    a: io.A,
    root: std.fs.Dir,
    repo: core.Repo,

    // Walk the private state directory one component at a time. A symlink to
    // a worktree or another object store must never become an eviction target.
    pub fn repoDir(self: Cache, create: bool) !?std.fs.Dir {
        if (!core.validRepoName(self.repo.name)) return error.InvalidRepository;
        var parts = std.mem.splitScalar(u8, self.repo.name, '/');
        var repos = (try openChild(self.root, "repos", create)) orelse return null;
        defer repos.close();
        var owner = (try openChild(repos, parts.next().?, create)) orelse return null;
        defer owner.close();
        return openChild(owner, parts.next().?, create);
    }

    pub fn maintain(self: Cache, now: i64) !void {
        var dir = (try self.repoDir(false)) orelse return;
        defer dir.close();
        try self.evict(dir, now);
    }

    // Call only while holding the watcher lock and no Git child is using
    // this cache. Talos retains a whole bare cache or rebuilds it as needed.
    pub fn evict(self: Cache, repo_dir: std.fs.Dir, now: i64) !void {
        var dir = (try openCache(repo_dir)) orelse return;
        const remove = self.shouldEvict(dir, now) catch |err| {
            dir.close();
            return err;
        };
        dir.close();
        if (remove) try repo_dir.deleteTree(directory);
    }

    fn shouldEvict(self: Cache, dir: std.fs.Dir, now: i64) !bool {
        if (self.repo.cache_mib == 0) return true;
        const used = (try lastUse(dir)) orelse return true;
        if (now -| used >= @as(i64, self.repo.cache_idle_days) * day_seconds) return true;
        // A v0 binary may have reopened this cache during a rollback.
        if (dir.access("objects/info/alternates", .{})) |_| {
            return true;
        } else |err| if (err != error.FileNotFound) return err;
        return try size(self.a, dir) > @as(u64, self.repo.cache_mib) * 1024 * 1024;
    }

    pub fn measure(self: Cache) !u64 {
        var repo_dir = (try self.repoDir(false)) orelse return 0;
        defer repo_dir.close();
        var dir = (try openCache(repo_dir)) orelse return 0;
        defer dir.close();
        return size(self.a, dir);
    }
};

fn openChild(parent: std.fs.Dir, name: []const u8, create: bool) !?std.fs.Dir {
    if (create) parent.makeDir(name) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return parent.openDir(name, .{ .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn openCache(repo_dir: std.fs.Dir) !?std.fs.Dir {
    return repo_dir.openDir(directory, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn touch(a: io.A, dir: std.fs.Dir, now: i64) !void {
    try io.write(dir, marker, try io.fmt(a, "{d}\n", .{now}));
}

fn lastUse(dir: std.fs.Dir) !?i64 {
    var bytes: [32]u8 = undefined;
    const input = dir.readFile(marker, &bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const timestamp = std.fmt.parseInt(i64, io.trim(u8, input, "\n"), 10) catch return null;
    return if (timestamp >= 0) timestamp else null;
}

fn size(a: io.A, dir: std.fs.Dir) !u64 {
    var walker = try dir.walk(a);
    defer walker.deinit();
    var bytes: u64 = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .sym_link) return error.GitCacheContainsSymlink;
        if (entry.kind != .file) continue;
        const stat = entry.dir.statFile(entry.basename) catch |err| switch (err) {
            error.FileNotFound => continue, // status can race with eviction
            else => return err,
        };
        bytes +|= stat.size;
    }
    return bytes;
}

test "size eviction preserves other state and an in-budget cache stays warm" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const object_cache: Cache = .{
        .a = a,
        .root = tmp.dir,
        .repo = .{ .name = "example/repo", .login = "reviewer", .cache_mib = 1 },
    };
    var repo_dir = (try object_cache.repoDir(true)).?;
    defer repo_dir.close();
    try io.write(tmp.dir, "state.json", "ledger");
    try repo_dir.makeDir("results");
    try io.write(repo_dir, "results/42.json", "review");
    try repo_dir.makeDir(directory);
    {
        var dir = (try openCache(repo_dir)).?;
        defer dir.close();
        try touch(a, dir, 10);
        try io.write(dir, "pack", "objects");
    }
    const bytes = try object_cache.measure();
    try testing.expect(bytes > 0);
    try object_cache.maintain(20);
    try testing.expectEqual(bytes, try object_cache.measure());

    {
        var dir = (try openCache(repo_dir)).?;
        defer dir.close();
        const pack = try dir.openFile("pack", .{ .mode = .read_write });
        defer pack.close();
        try pack.setEndPos(1024 * 1024);
    }
    try object_cache.maintain(20);
    try testing.expectEqual(@as(u64, 0), try object_cache.measure());
    try tmp.dir.access("state.json", .{});
    try repo_dir.access("results/42.json", .{});
}

test "idle and v0 caches are evicted and zero size leaves no retained cache" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var object_cache: Cache = .{ .a = a, .root = tmp.dir, .repo = .{ .name = "example/repo", .login = "reviewer" } };
    var repo_dir = (try object_cache.repoDir(true)).?;
    defer repo_dir.close();

    try repo_dir.makePath(directory ++ "/objects/info");
    try io.write(repo_dir, directory ++ "/objects/info/alternates", "/unrelated/repository/.git/objects\n");
    try object_cache.maintain(50);
    try testing.expect((try openCache(repo_dir)) == null);

    try repo_dir.makeDir(directory);
    {
        var dir = (try openCache(repo_dir)).?;
        defer dir.close();
        try touch(a, dir, 50);
    }
    try object_cache.maintain(50 + 7 * day_seconds - 1);
    try testing.expect((try object_cache.measure()) > 0);
    try object_cache.maintain(50 + 7 * day_seconds);
    try testing.expect((try openCache(repo_dir)) == null);

    try repo_dir.makeDir(directory);
    {
        var dir = (try openCache(repo_dir)).?;
        defer dir.close();
        try touch(a, dir, 50);
    }
    object_cache.repo.cache_mib = 0;
    try object_cache.maintain(50);
    try testing.expect((try openCache(repo_dir)) == null);
}

test "eviction never follows symlinks to another checkout" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const object_cache: Cache = .{ .a = a, .root = tmp.dir, .repo = .{ .name = "example/repo", .login = "reviewer" } };
    var repo_dir = (try object_cache.repoDir(true)).?;
    defer repo_dir.close();

    try tmp.dir.makeDir("checkout");
    try io.write(tmp.dir, "checkout/keep", "existing work");
    const external = try tmp.dir.realpathAlloc(a, "checkout");
    try repo_dir.symLink(external, directory, .{ .is_directory = true });
    if (object_cache.maintain(50)) |_| {
        return error.ExpectedSymlinkRejection;
    } else |err| switch (err) {
        error.NotDir, error.SymLinkLoop => {},
        else => return err,
    }
    try tmp.dir.access("checkout/keep", .{});

    try repo_dir.deleteFile(directory);
    try repo_dir.makeDir(directory);
    {
        var dir = (try openCache(repo_dir)).?;
        defer dir.close();
        try touch(a, dir, 50);
        try dir.symLink(external, "objects", .{ .is_directory = true });
    }
    try testing.expectError(error.GitCacheContainsSymlink, object_cache.maintain(50));
    try object_cache.maintain(50 + 7 * day_seconds);
    try testing.expect((try openCache(repo_dir)) == null);
    try tmp.dir.access("checkout/keep", .{});
}
