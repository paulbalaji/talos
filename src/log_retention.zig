const std = @import("std");
const io = @import("io.zig");
const posix = std.posix;

pub const filename = "launchd.log";
const archive_prefix = filename ++ ".";
const day_ns = @as(i128, std.time.s_per_day) * std.time.ns_per_s;
const max_age_ns = 30 * day_ns;
const max_bytes = 10 * 1024 * 1024;
const segment_bytes = 1024 * 1024;

fn regularStat(dir: std.fs.Dir, name: []const u8) !?posix.Stat {
    const stat = posix.fstatat(dir.fd, name, posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return if (stat.mode & posix.S.IFMT == posix.S.IFREG) stat else null;
}

// The scheduler opens stderr before the tick starts. Rebind it if it points
// at the rotated inode so subsequent writes go to the new active file.
pub fn rotate(dir: std.fs.Dir, now: i128) !void {
    const current = (try regularStat(dir, filename)) orelse return;
    const stat = std.fs.File.Stat.fromPosix(current);
    if (stat.size == 0 or (stat.size < segment_bytes and @divFloor(stat.mtime, day_ns) >= @divFloor(now, day_ns))) return;

    const stderr = std.fs.File.stderr().handle;
    const inherited: ?posix.Stat = posix.fstat(stderr) catch null;
    const redirects = if (inherited) |opened| opened.dev == current.dev and opened.ino == current.ino else false;
    var name_buffer: [96]u8 = undefined;
    const archive = try std.fmt.bufPrint(&name_buffer, archive_prefix ++ "{d}.{x:0>16}", .{
        stat.mtime, std.crypto.random.int(u64),
    });
    try dir.rename(filename, archive);
    if (redirects) {
        const new_fd = try posix.openat(dir.fd, filename, .{
            .ACCMODE = .WRONLY,
            .APPEND = true,
            .CREAT = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
        }, 0o600);
        defer posix.close(new_fd);
        const replacement = try posix.fstat(new_fd);
        if (replacement.mode & posix.S.IFMT != posix.S.IFREG) return error.InvalidDiagnosticLog;
        try posix.dup2(new_fd, stderr);
    }
}

const Archive = struct {
    name: []const u8,
    time: i128,
    size: u64,

    fn newestFirst(_: void, left: Archive, right: Archive) bool {
        if (left.time != right.time) return left.time > right.time;
        return std.mem.order(u8, left.name, right.name) == .gt;
    }
};

fn archiveTime(name: []const u8) ?i128 {
    if (!std.mem.startsWith(u8, name, archive_prefix)) return null;
    const fields = name[archive_prefix.len..];
    const dot = std.mem.indexOfScalar(u8, fields, '.') orelse return null;
    const time = fields[0..dot];
    const digits = if (std.mem.startsWith(u8, time, "-")) time[1..] else time;
    if (digits.len == 0) return null;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const suffix = fields[dot + 1 ..];
    if (suffix.len != 16) return null;
    for (suffix) |byte| {
        if (!std.ascii.isHex(byte)) return null;
    }
    return std.fmt.parseInt(i128, time, 10) catch null;
}

fn keepTail(a: io.A, dir: std.fs.Dir, archive: Archive, bytes: usize) !void {
    const fd = try posix.openat(dir.fd, archive.name, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    }, 0);
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    const stat = try file.stat();
    if (stat.kind != .file or stat.size <= bytes) return;
    const tail = try a.alloc(u8, bytes);
    defer a.free(tail);
    const read = try file.preadAll(tail, stat.size - bytes);
    try io.write(dir, archive.name, tail[0..read]);
}

fn prune(a: io.A, dir: std.fs.Dir, now: i128, cap: u64) !void {
    const active_size = if (try regularStat(dir, filename)) |stat| std.fs.File.Stat.fromPosix(stat).size else 0;
    var archives: std.ArrayList(Archive) = .empty;
    defer {
        for (archives.items) |archive| a.free(archive.name);
        archives.deinit(a);
    }
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const time = archiveTime(entry.name) orelse continue;
        const stat = (try regularStat(dir, entry.name)) orelse continue;
        const name = try a.dupe(u8, entry.name);
        errdefer a.free(name);
        try archives.append(a, .{ .name = name, .time = time, .size = std.fs.File.Stat.fromPosix(stat).size });
    }
    std.mem.sort(Archive, archives.items, {}, Archive.newestFirst);
    var remaining = cap -| active_size;
    const cutoff = now -| max_age_ns;
    var trim: ?struct { archive: Archive, bytes: usize } = null;
    for (archives.items) |archive| {
        if (archive.time <= cutoff or remaining == 0) {
            try dir.deleteFile(archive.name);
        } else if (archive.size > remaining) {
            trim = .{ .archive = archive, .bytes = @intCast(remaining) };
            remaining = 0;
        } else {
            remaining -= archive.size;
        }
    }
    if (trim) |item| try keepTail(a, dir, item.archive, item.bytes);
}

pub fn maintain(a: io.A, dir: std.fs.Dir, now: i128) !void {
    try rotate(dir, now);
    try prune(a, dir, now, max_bytes);
}

test "rotation archives an earlier UTC day and keeps today's log in place" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const now = std.time.nanoTimestamp();
    const yesterday = now - day_ns;
    try io.write(tmp.dir, filename, "old diagnostic");
    {
        const file = try tmp.dir.openFile(filename, .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(yesterday, yesterday);
    }
    try rotate(tmp.dir, now);
    try t.expectError(error.FileNotFound, tmp.dir.access(filename, .{}));
    var iter = tmp.dir.iterate();
    const archive = (try iter.next()).?;
    try t.expectEqual(yesterday, archiveTime(archive.name).?);
    const data = try tmp.dir.readFileAlloc(t.allocator, archive.name, 64);
    defer t.allocator.free(data);
    try t.expectEqualStrings("old diagnostic", data);
    try t.expect(try iter.next() == null);
    try io.write(tmp.dir, filename, "new diagnostic");
    try maintain(t.allocator, tmp.dir, now);
    try tmp.dir.access(filename, .{});
}

test "pruning keeps the newest tail within the cap and only touches managed regular logs" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const now = 40 * day_ns;
    var old_buffer: [96]u8 = undefined;
    var tail_buffer: [96]u8 = undefined;
    var fresh_buffer: [96]u8 = undefined;
    const old = try std.fmt.bufPrint(&old_buffer, archive_prefix ++ "{d}.0000000000000001", .{now - max_age_ns});
    const tail = try std.fmt.bufPrint(&tail_buffer, archive_prefix ++ "{d}.0000000000000002", .{now - 2 * day_ns});
    const fresh = try std.fmt.bufPrint(&fresh_buffer, archive_prefix ++ "{d}.0000000000000003", .{now - day_ns});
    try io.write(tmp.dir, old, "expired");
    try io.write(tmp.dir, tail, "discardXYZ");
    try io.write(tmp.dir, fresh, "fresh");
    try io.write(tmp.dir, filename, "now");
    try io.write(tmp.dir, "state.json", "evidence");
    try io.write(tmp.dir, "launchd.log.custom", "operator archive");
    try tmp.dir.symLink("state.json", "launchd.log.1.0000000000000004", .{});
    try prune(t.allocator, tmp.dir, now, 11);
    try t.expectError(error.FileNotFound, tmp.dir.access(old, .{}));
    const data = try tmp.dir.readFileAlloc(t.allocator, tail, 64);
    defer t.allocator.free(data);
    try t.expectEqualStrings("XYZ", data);
    for ([_][]const u8{ filename, fresh, "state.json", "launchd.log.custom", "launchd.log.1.0000000000000004" }) |name|
        try tmp.dir.access(name, .{});
}
