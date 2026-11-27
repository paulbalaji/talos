const std = @import("std");
const builtin = @import("builtin");

const c = struct {
    const sqlite3 = opaque {};
    const sqlite3_stmt = opaque {};
    const sqlite3_destructor_type = ?*const fn (?*anyopaque) callconv(.c) void;
    const sqlite3_callback = ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;
    const SQLITE_OK = 0;
    const SQLITE_PERM = 3;
    const SQLITE_BUSY = 5;
    const SQLITE_LOCKED = 6;
    const SQLITE_NOMEM = 7;
    const SQLITE_READONLY = 8;
    const SQLITE_CORRUPT = 11;
    const SQLITE_FULL = 13;
    const SQLITE_CANTOPEN = 14;
    const SQLITE_CONSTRAINT = 19;
    const SQLITE_NOTADB = 26;
    const SQLITE_ROW = 100;
    const SQLITE_DONE = 101;
    const SQLITE_NULL = 5; // Column type.
    const SQLITE_OPEN_READWRITE = 0x00000002;
    const SQLITE_OPEN_NOFOLLOW = 0x01000000;
    const SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE = 1006;
};

const Api = struct {
    sqlite3_open_v2: *const fn ([*:0]const u8, *?*c.sqlite3, c_int, ?[*:0]const u8) callconv(.c) c_int,
    sqlite3_close: *const fn (*c.sqlite3) callconv(.c) c_int,
    sqlite3_libversion_number: *const fn () callconv(.c) c_int,
    sqlite3_exec: *const fn (*c.sqlite3, [*:0]const u8, c.sqlite3_callback, ?*anyopaque, ?*?[*:0]u8) callconv(.c) c_int,
    sqlite3_busy_timeout: *const fn (*c.sqlite3, c_int) callconv(.c) c_int,
    sqlite3_db_config: *const fn (*c.sqlite3, c_int, ...) callconv(.c) c_int,
    sqlite3_changes: *const fn (*c.sqlite3) callconv(.c) c_int,
    sqlite3_prepare_v2: *const fn (*c.sqlite3, [*:0]const u8, c_int, *?*c.sqlite3_stmt, ?*?[*:0]const u8) callconv(.c) c_int,
    sqlite3_finalize: *const fn (*c.sqlite3_stmt) callconv(.c) c_int,
    sqlite3_bind_blob: *const fn (*c.sqlite3_stmt, c_int, ?*const anyopaque, c_int, c.sqlite3_destructor_type) callconv(.c) c_int,
    sqlite3_bind_text: *const fn (*c.sqlite3_stmt, c_int, [*]const u8, c_int, c.sqlite3_destructor_type) callconv(.c) c_int,
    sqlite3_bind_null: *const fn (*c.sqlite3_stmt, c_int) callconv(.c) c_int,
    sqlite3_bind_int64: *const fn (*c.sqlite3_stmt, c_int, i64) callconv(.c) c_int,
    sqlite3_step: *const fn (*c.sqlite3_stmt) callconv(.c) c_int,
    sqlite3_reset: *const fn (*c.sqlite3_stmt) callconv(.c) c_int,
    sqlite3_clear_bindings: *const fn (*c.sqlite3_stmt) callconv(.c) c_int,
    sqlite3_column_int64: *const fn (*c.sqlite3_stmt, c_int) callconv(.c) i64,
    sqlite3_column_type: *const fn (*c.sqlite3_stmt, c_int) callconv(.c) c_int,
    sqlite3_column_blob: *const fn (*c.sqlite3_stmt, c_int) callconv(.c) ?*const anyopaque,
    sqlite3_column_bytes: *const fn (*c.sqlite3_stmt, c_int) callconv(.c) c_int,
};

var api_mutex: std.Thread.Mutex = .{};
var loaded_api: ?Api = null;

fn systemApi() !*const Api {
    api_mutex.lock();
    defer api_mutex.unlock();
    if (loaded_api == null) {
        // The macOS SDK's SQLite link stub now requires arm64e. Load the system
        // library at runtime so the normal arm64 build works across SDKs.
        const path = switch (builtin.os.tag) {
            .macos => "/usr/lib/libsqlite3.dylib",
            .linux => "libsqlite3.so.0",
            else => return error.SQLiteUnavailable,
        };
        var lib = std.DynLib.open(path) catch return error.SQLiteUnavailable;
        errdefer lib.close();
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            @field(api, field.name) = lib.lookup(field.type, field.name) orelse return error.SQLiteUnavailable;
        }
        // Keep the system library open for the lifetime of the process.
        loaded_api = api;
    }
    return &loaded_api.?;
}

const filename = "talos.sqlite3";
const schema_version = 1;

const schema =
    \\CREATE TABLE settings (key TEXT PRIMARY KEY, payload TEXT NOT NULL);
    \\CREATE TABLE repository (
    \\    name TEXT PRIMARY KEY COLLATE NOCASE, position INTEGER NOT NULL, payload TEXT NOT NULL
    \\);
    \\CREATE TABLE review_job (
    \\    repo TEXT COLLATE NOCASE REFERENCES repository(name) ON DELETE CASCADE,
    \\    number INTEGER NOT NULL, head TEXT NOT NULL, position INTEGER NOT NULL, payload TEXT NOT NULL,
    \\    PRIMARY KEY (repo, number, head)
    \\);
    \\CREATE INDEX review_job_order ON review_job(repo, position);
    \\CREATE TABLE paused_repository (name TEXT PRIMARY KEY COLLATE NOCASE);
    \\CREATE TABLE review_result (
    \\    repo TEXT COLLATE NOCASE, number INTEGER NOT NULL, changed_at INTEGER NOT NULL, payload TEXT NOT NULL,
    \\    PRIMARY KEY (repo, number)
    \\);
    \\CREATE INDEX review_result_time ON review_result(changed_at);
    \\CREATE TABLE publication_intent (
    \\    repo TEXT COLLATE NOCASE, number INTEGER NOT NULL, head TEXT NOT NULL, event TEXT NOT NULL, review_key TEXT NOT NULL,
    \\    payload TEXT NOT NULL, PRIMARY KEY (repo, number, head, event, review_key)
    \\);
    \\CREATE TABLE reviewer_pass (
    \\    key BLOB PRIMARY KEY, lease BLOB, lease_until INTEGER NOT NULL,
    \\    payload TEXT, finished_at INTEGER, CHECK ((lease IS NULL) = (payload IS NOT NULL))
    \\);
    \\CREATE INDEX reviewer_pass_active ON reviewer_pass(key) WHERE lease IS NOT NULL;
    \\CREATE INDEX reviewer_pass_expiry ON reviewer_pass(finished_at) WHERE finished_at IS NOT NULL;
    \\CREATE TABLE telemetry_event (
    \\    id TEXT NOT NULL, kind TEXT NOT NULL, at INTEGER NOT NULL, repo TEXT NOT NULL COLLATE NOCASE,
    \\    number INTEGER NOT NULL, payload TEXT NOT NULL, UNIQUE (id, kind)
    \\);
    \\CREATE INDEX telemetry_event_time ON telemetry_event(at);
    \\CREATE INDEX telemetry_event_pr ON telemetry_event(repo, number, at);
    \\CREATE TABLE review_verdict (
    \\    repo TEXT COLLATE NOCASE, number INTEGER NOT NULL, head TEXT NOT NULL, review_key TEXT NOT NULL,
    \\    at INTEGER NOT NULL, event TEXT NOT NULL, publication TEXT NOT NULL, payload TEXT NOT NULL,
    \\    UNIQUE (repo, number, head, review_key, at, event, publication)
    \\);
    \\CREATE INDEX review_verdict_time ON review_verdict(at);
    \\CREATE INDEX review_verdict_pr ON review_verdict(repo, number, at);
    \\PRAGMA user_version=1;
;

fn check(code: c_int) !void {
    switch (code & 0xff) {
        c.SQLITE_OK => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => return error.DatabaseBusy,
        c.SQLITE_NOMEM => return error.OutOfMemory,
        c.SQLITE_FULL => return error.DatabaseFull,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => return error.InvalidDatabase,
        c.SQLITE_READONLY, c.SQLITE_PERM, c.SQLITE_CANTOPEN => return error.DatabaseOpenFailed,
        c.SQLITE_CONSTRAINT => return error.DatabaseConstraint,
        else => {
            std.log.warn("SQLite returned code {d}", .{code});
            return error.DatabaseFailure;
        },
    }
}

pub const Blob = struct { bytes: []const u8 };
pub const Db = struct {
    raw: *c.sqlite3,
    api: *const Api,

    pub fn open(a: std.mem.Allocator, dir: std.fs.Dir) !Db {
        const root = try dir.realpathAlloc(a, ".");
        defer a.free(root);
        const path = try std.fs.path.joinZ(a, &.{ root, filename });
        defer a.free(path);

        const file = dir.createFile(filename, .{ .mode = 0o600, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => null,
            else => return err,
        };
        if (file) |created| created.close();

        const api = try systemApi();
        var raw: ?*c.sqlite3 = null;
        errdefer if (raw) |handle| {
            _ = api.sqlite3_close(handle);
        };
        try check(api.sqlite3_open_v2(path, &raw, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_NOFOLLOW, null));
        const db: Db = .{ .raw = raw orelse return error.DatabaseOpenFailed, .api = api };
        try check(api.sqlite3_busy_timeout(db.raw, 5000));
        // Short-lived connections still use SQLite's ordinary WAL auto-checkpoint.
        // Avoid forcing a checkpoint on every last connection close.
        if (api.sqlite3_libversion_number() >= 3_051_003)
            try check(api.sqlite3_db_config(db.raw, c.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, @as(c_int, 1), @as(?*c_int, null)));
        try db.exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY;");
        try db.ensureSchema();
        return db;
    }

    fn schemaVersion(self: Db) !i64 {
        var query = try self.prepare("PRAGMA user_version");
        defer query.close();
        if (!try query.step()) return error.InvalidDatabase;
        return query.int(0);
    }

    fn ensureSchema(self: Db) !void {
        const version = try self.schemaVersion();
        if (version == schema_version) return;
        if (version != 0) return error.UnsupportedDatabaseVersion;

        try self.beginWrite();
        errdefer self.rollback();
        const current = try self.schemaVersion();
        if (current == 0) {
            try self.exec(schema);
        } else if (current != schema_version) return error.UnsupportedDatabaseVersion;
        try self.commit();

        // SQLite 3.51.3 fixed a concurrent WAL checkpoint race. A newly
        // created database can use WAL when nobody else has started using it.
        if (current == 0 and self.api.sqlite3_libversion_number() >= 3_051_003)
            self.exec("PRAGMA journal_mode=WAL;") catch |err| switch (err) {
                error.DatabaseBusy => {},
                else => return err,
            };
    }

    pub fn close(self: Db) void {
        const code = self.api.sqlite3_close(self.raw);
        std.debug.assert(code == c.SQLITE_OK);
    }

    pub fn exec(self: Db, sql: [:0]const u8) !void {
        try check(self.api.sqlite3_exec(self.raw, sql, null, null, null));
    }

    pub fn beginRead(self: Db) !void {
        try self.exec("BEGIN");
    }

    pub fn beginWrite(self: Db) !void {
        try self.exec("BEGIN IMMEDIATE");
    }

    pub fn commit(self: Db) !void {
        try self.exec("COMMIT");
    }

    pub fn rollback(self: Db) void {
        self.exec("ROLLBACK") catch {};
    }

    pub fn changed(self: Db) bool {
        return self.api.sqlite3_changes(self.raw) != 0;
    }

    pub fn prepare(self: Db, sql: [:0]const u8) !Statement {
        var raw: ?*c.sqlite3_stmt = null;
        try check(self.api.sqlite3_prepare_v2(self.raw, sql, -1, &raw, null));
        return .{ .raw = raw orelse return error.DatabaseFailure, .api = self.api };
    }

    pub fn run(self: Db, sql: [:0]const u8, parameters: anytype) !void {
        var stmt = try self.prepare(sql);
        defer stmt.close();
        try stmt.run(parameters);
    }

    pub fn setting(self: Db, a: std.mem.Allocator, key: []const u8) !?[]const u8 {
        var stmt = try self.prepare("SELECT payload FROM settings WHERE key=?");
        defer stmt.close();
        try stmt.bind(.{key});
        return if (try stmt.step()) try a.dupe(u8, stmt.bytes(0)) else null;
    }

    pub fn hasSetting(self: Db, key: []const u8) !bool {
        var stmt = try self.prepare("SELECT 1 FROM settings WHERE key=?");
        defer stmt.close();
        try stmt.bind(.{key});
        return stmt.step();
    }

    pub fn setSetting(self: Db, key: []const u8, value: []const u8) !void {
        try self.run(
            "INSERT INTO settings VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload WHERE settings.payload<>excluded.payload",
            .{ key, value },
        );
    }
};

pub const Statement = struct {
    raw: *c.sqlite3_stmt,
    api: *const Api,

    pub fn close(self: Statement) void {
        _ = self.api.sqlite3_finalize(self.raw);
    }

    pub fn bind(self: Statement, parameters: anytype) !void {
        // Bindings borrow the caller's bytes until reset or close.
        inline for (parameters, 1..) |value, index| {
            if (@TypeOf(value) == Blob) {
                try check(self.api.sqlite3_bind_blob(self.raw, index, value.bytes.ptr, @intCast(value.bytes.len), null));
            } else switch (@typeInfo(@TypeOf(value))) {
                .null => try check(self.api.sqlite3_bind_null(self.raw, index)),
                .int, .comptime_int => try check(self.api.sqlite3_bind_int64(self.raw, index, @intCast(value))),
                .pointer => {
                    const bytes_value: []const u8 = value;
                    try check(self.api.sqlite3_bind_text(self.raw, index, bytes_value.ptr, @intCast(bytes_value.len), null));
                },
                else => @compileError("unsupported SQLite bind parameter"),
            }
        }
    }

    pub fn step(self: Statement) !bool {
        const code = self.api.sqlite3_step(self.raw);
        switch (code) {
            c.SQLITE_ROW => return true,
            c.SQLITE_DONE => return false,
            else => {
                try check(code);
                return error.DatabaseFailure;
            },
        }
    }

    pub fn run(self: Statement, parameters: anytype) !void {
        try self.bind(parameters);
        if (try self.step()) return error.DatabaseFailure;
        try self.reset();
    }

    pub fn reset(self: Statement) !void {
        try check(self.api.sqlite3_reset(self.raw));
        try check(self.api.sqlite3_clear_bindings(self.raw));
    }

    pub fn int(self: Statement, column: c_int) i64 {
        return self.api.sqlite3_column_int64(self.raw, column);
    }

    pub fn isNull(self: Statement, column: c_int) bool {
        return self.api.sqlite3_column_type(self.raw, column) == c.SQLITE_NULL;
    }

    pub fn bytes(self: Statement, column: c_int) []const u8 {
        const ptr: ?[*]const u8 = @ptrCast(self.api.sqlite3_column_blob(self.raw, column));
        return if (ptr) |value| value[0..@intCast(self.api.sqlite3_column_bytes(self.raw, column))] else "";
    }
};

test "failed transactions do not expose partial state to another connection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const writer = try Db.open(a, tmp.dir);
    defer writer.close();
    const reader = try Db.open(a, tmp.dir);
    defer reader.close();

    try writer.beginWrite();
    try writer.setSetting("state", "uncommitted");
    try std.testing.expect(!try reader.hasSetting("state"));
    writer.rollback();
    try std.testing.expect(!try reader.hasSetting("state"));

    try writer.beginWrite();
    try writer.setSetting("state", "committed");
    try writer.commit();
    const saved = (try reader.setting(a, "state")).?;
    defer a.free(saved);
    try std.testing.expectEqualStrings("committed", saved);
}
