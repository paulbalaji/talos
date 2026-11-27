const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");
const sqlite = @import("sqlite.zig");

pub const Provider = struct {
    limit: u32 = 0,
    starts: u32 = 0,
    total_starts: u64 = 0,
};

pub const Snapshot = struct {
    day: i64 = -1,
    codex: Provider = .{},
    claude: Provider = .{},
    kimi: Provider = .{},

    pub fn get(self: *Snapshot, engine: core.Engine) *Provider {
        return switch (engine) {
            inline else => |tag| &@field(self, @tagName(tag)),
        };
    }

    fn roll(self: *Snapshot, now: i64) void {
        const day = @divFloor(now, std.time.s_per_day);
        if (day <= self.day) return;
        self.day = day;
        for (std.meta.tags(core.Engine)) |engine| self.get(engine).starts = 0;
    }

    pub fn availableAt(self: Snapshot, engine: core.Engine, now: i64) i64 {
        var current = self;
        current.roll(now);
        const provider = current.get(engine);
        if (provider.limit != 0 and provider.starts >= provider.limit)
            return (current.day + 1) * std.time.s_per_day;
        return now;
    }
};

const setting = "provider_usage";

pub fn load(a: io.A, dir: std.fs.Dir, now: i64) !Snapshot {
    const db = try sqlite.Db.open(a, dir);
    defer db.close();
    const raw = (try db.setting(a, setting)) orelse return .{};
    defer a.free(raw);
    var data = try io.parse(a, Snapshot, raw);
    data.roll(now);
    return data;
}

pub fn save(dir: std.fs.Dir, data: Snapshot) !void {
    const a = std.heap.page_allocator;
    const db = try sqlite.Db.open(a, dir);
    defer db.close();
    const json = try io.json(a, data);
    defer a.free(json);
    try db.setSetting(setting, json);
}

pub fn migrate(db: sqlite.Db, dir: std.fs.Dir) !void {
    if (try db.hasSetting(setting)) return;
    const a = std.heap.page_allocator;
    const raw = dir.readFileAlloc(a, "usage.json", 16 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer a.free(raw);
    _ = try io.parse(a, Snapshot, raw);
    try db.setSetting(setting, raw);
}

pub const Ledger = struct {
    dir: std.fs.Dir,
    data: Snapshot,
    mutex: std.Thread.Mutex = .{},

    pub fn snapshot(self: *Ledger) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.data;
    }

    // Count attempted starts before dispatch. A killed worker cannot refund an
    // invocation that may already have reached the provider.
    pub fn start(self: *Ledger, engine: core.Engine, now: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var next = self.data;
        next.roll(now);
        const provider = next.get(engine);
        if (provider.limit != 0 and provider.starts >= provider.limit) return error.ProviderBudgetReached;
        provider.starts +|= 1;
        provider.total_starts +|= 1;
        try save(self.dir, next);
        self.data = next;
    }
};

test "provider starts survive restart and reset at the next UTC day" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const timestamp = 100 * std.time.s_per_day;
    var first: Ledger = .{ .dir = scratch.dir, .data = .{ .codex = .{ .limit = 1 } } };
    try first.start(.codex, timestamp);
    try std.testing.expectError(error.ProviderBudgetReached, first.start(.codex, timestamp + 1));
    try first.start(.claude, timestamp);
    var reopened: Ledger = .{ .dir = scratch.dir, .data = try load(std.testing.allocator, scratch.dir, timestamp) };
    try std.testing.expectEqual(timestamp + std.time.s_per_day, reopened.data.availableAt(.codex, timestamp));
    try reopened.start(.codex, timestamp + std.time.s_per_day);
    try std.testing.expectEqual(@as(u64, 2), reopened.data.codex.total_starts);
    try std.testing.expectEqual(@as(u32, 0), reopened.data.claude.starts);
}
