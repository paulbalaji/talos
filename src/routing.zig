const std = @import("std");

pub const Mode = enum { fixed, shadow, adaptive };
pub const Depth = enum { light, regular, focused, multi };
pub const Lens = enum { performance, reliability, security };

pub const Decision = struct {
    depth: Depth = .regular,
    performance: bool = false,
    reliability: bool = false,
    security: bool = false,

    pub fn has(self: Decision, lens: Lens) bool {
        return switch (lens) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    pub fn merge(self: Decision, other: Decision) Decision {
        return .{
            .depth = @enumFromInt(@max(@intFromEnum(self.depth), @intFromEnum(other.depth))),
            .performance = self.performance or other.performance,
            .reliability = self.reliability or other.reliability,
            .security = self.security or other.security,
        };
    }

    pub fn valid(self: Decision) bool {
        const has_lens = self.performance or self.reliability or self.security;
        return switch (self.depth) {
            .light, .regular => !has_lens,
            .focused, .multi => has_lens,
        };
    }
};

pub const Screen = struct {
    floor: Decision,
    ask_model: bool,
};

fn contains(path: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, path, part) != null;
}

fn pathRisk(path: []const u8) Decision {
    if (std.mem.endsWith(u8, path, ".sol") or contains(path, "/contracts/") or std.mem.startsWith(u8, path, "contracts/") or
        contains(path, "auth") or contains(path, "permission") or contains(path, "iam.") or
        contains(path, "access-control") or contains(path, "security") or std.mem.startsWith(u8, path, ".github/workflows/"))
        return .{ .depth = .multi, .security = true, .reliability = true };
    if (contains(path, "migrat") or contains(path, "schema") or contains(path, "deploy"))
        return .{ .depth = .multi, .reliability = true };
    if (contains(path, "benchmark") or contains(path, "perf") or contains(path, "cache"))
        return .{ .depth = .focused, .performance = true };
    if (contains(path, "queue") or contains(path, "retry") or contains(path, "scheduler"))
        return .{ .depth = .focused, .reliability = true };
    return .{};
}

const Image = struct { prefix: []const u8, suffix: []const u8, patch: u32 };

fn image(line: []const u8) ?Image {
    const text = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, text, "image:")) return null;
    var value = std.mem.trim(u8, text["image:".len..], " \t");
    if (value.len < 2) return null;
    if ((value[0] == '"' or value[0] == '\'') and value[0] == value[value.len - 1]) value = value[1 .. value.len - 1];
    if (std.mem.indexOfAny(u8, value, " \t@#\x00") != null) return null;
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return null;
    if (colon == 0) return null;
    const name = value[0..colon];
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '_' or c == '-' or c == '.' or c == ':')) return null;
    const tag = value[colon + 1 ..];
    var parts = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag, '.');
    var version: [3]u32 = undefined;
    for (&version) |*part| {
        const digits = parts.next() orelse return null;
        if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return null;
        for (digits) |c| if (!std.ascii.isDigit(c)) return null;
        part.* = std.fmt.parseUnsigned(u32, digits, 10) catch return null;
    }
    if (parts.next() != null) return null;
    const patch_start = std.mem.lastIndexOfScalar(u8, tag, '.').? + 1;
    const offset = @intFromPtr(tag.ptr) - @intFromPtr(line.ptr);
    return .{ .prefix = line[0 .. offset + patch_start], .suffix = line[offset + tag.len ..], .patch = version[2] };
}

fn patchBump(patch: []const u8, additions: ?u32, deletions: ?u32) bool {
    var lines = std.mem.splitScalar(u8, patch, '\n');
    var old: ?Image = null;
    var pairs: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        switch (line[0]) {
            '-' => {
                if (old != null) return false;
                old = image(line[1..]) orelse return false;
            },
            '+' => {
                const before = old orelse return false;
                const after = image(line[1..]) orelse return false;
                if (!std.mem.eql(u8, before.prefix, after.prefix) or !std.mem.eql(u8, before.suffix, after.suffix) or
                    after.patch <= before.patch) return false;
                old = null;
                pairs += 1;
            },
            else => if (old != null) return false,
        }
    }
    return pairs != 0 and old == null and pairs == (additions orelse 0) and pairs == (deletions orelse 0);
}

pub fn inspect(files: anytype, limited: bool) Screen {
    var floor: Decision = .{};
    var mechanical = !limited and files.len > 0 and files.len <= 4;
    var edits: usize = 0;
    for (files) |file| {
        const path = file.filename;
        floor = floor.merge(pathRisk(path));
        if (file.previous_filename) |old| floor = floor.merge(pathRisk(old));
        const patch = file.patch orelse {
            mechanical = false;
            continue;
        };
        var lines = std.mem.splitScalar(u8, patch, '\n');
        while (lines.next()) |line| {
            if (line.len > 0 and (line[0] == '+' or line[0] == '-')) edits += 1;
        }
        if (!std.mem.eql(u8, file.status, "modified") or file.previous_filename != null or
            !(std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) or
            !patchBump(patch, file.additions, file.deletions)) mechanical = false;
    }
    if (files.len >= 12 or edits >= 400) floor = floor.merge(.{ .depth = .focused, .reliability = true });
    if (floor.depth == .regular and mechanical and edits <= 8) {
        floor.depth = .light;
        return .{ .floor = floor, .ask_model = true };
    }
    return .{ .floor = floor, .ask_model = !limited and floor.depth == .regular };
}

test "the light floor only covers same-image semver patch bumps in complete modified YAML" {
    const File = struct {
        filename: []const u8 = "config/images.yaml",
        status: []const u8 = "modified",
        previous_filename: ?[]const u8 = null,
        additions: ?u32 = 1,
        deletions: ?u32 = 1,
        patch: ?[]const u8,
    };
    const cases = [_]struct { file: File, expected: Depth }{
        .{ .file = .{ .patch = "@@ -1 +1 @@\n-  image: image/path:1.2.3\n+  image: image/path:1.2.4" }, .expected = .light },
        .{ .file = .{ .patch = "-image: image/path:1.2.3\n+image: another/path:1.2.4" }, .expected = .regular },
        .{ .file = .{ .patch = "-image: image/path:1.2.3\n+image: image/path:2.0.0" }, .expected = .regular },
        .{ .file = .{ .patch = "-image: image/path:1.2.3\n+image: image/path:1.2.4\n+privileged: true" }, .expected = .regular },
        .{ .file = .{ .patch = "-  image: image/path:1.2.3\n+ image: image/path:1.2.4" }, .expected = .regular },
        .{ .file = .{ .patch = "-image: image/path:1.2.3\n+image: image/path:1.2.4", .additions = 2 }, .expected = .regular },
        .{ .file = .{ .filename = ".github/workflows/deploy.yaml", .patch = null }, .expected = .multi },
        .{ .file = .{ .filename = "src/cache.zig", .patch = null }, .expected = .focused },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, inspect(&[_]File{case.file}, false).floor.depth);
    try std.testing.expectEqual(Depth.regular, inspect(&[_]File{cases[0].file}, true).floor.depth);
}
