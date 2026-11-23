const std = @import("std");
const io = @import("io.zig");
const core = @import("core.zig");
const queue = @import("queue.zig");
const A = io.A;

pub const State = struct {
    version: u32 = 1,
    default_engines: []const core.Engine = &.{.codex},
    queue_budget: queue.Budget = .{},
    entries: []core.Entry = &.{},

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
        const file = try self.dir.createFile("watch.lock", .{ .truncate = false, .mode = 0o600 });
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
        const path = try self.repoPath(repo, try io.fmt(self.a, "results/{d}.json", .{number}));
        return self.dir.readFileAlloc(self.a, path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => error.NoLocalReview,
            else => err,
        };
    }

    pub fn result(self: Store, repo: []const u8, number: u32, payload: core.Payload) !void {
        const dir = try self.repoPath(repo, "results");
        try self.dir.makePath(dir);
        const path = try io.fmt(self.a, "{s}/{d}.json", .{ dir, number });
        try io.writeJson(self.dir, path, payload);
    }
};
