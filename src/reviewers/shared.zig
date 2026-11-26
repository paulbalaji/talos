const std = @import("std");
const core = @import("../core.zig");
const telemetry = @import("../telemetry.zig");

pub const Profile = struct {
    model: ?[]const u8 = null,
    effort: core.ReviewEffort = .high,
    advisor: ?[]const u8 = null,
    timeout_seconds: u32 = 15 * std.time.s_per_min,
};

pub const Invocation = struct {
    args: []const []const u8,
    stdin: []const u8,
};

pub const Report = struct {
    tokens: ?telemetry.Tokens = null,
    model_usage: []const telemetry.ModelUsage = &.{},
};

pub fn modelLabel(model: []const u8) []const u8 {
    if (model.len == 0 or model.len > 100) return "unknown";
    for (model) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "._-/:[]", byte) == null) return "unknown";
    }
    for ([_][]const u8{ "sk-", "sk_", "ghp_", "gho_", "github_pat_" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(model, prefix)) return "unknown";
    }
    return model;
}

pub fn requireStandardModel(model: []const u8) !void {
    const id = std.fs.path.basename(model);
    const name = id[0 .. std.mem.indexOfAny(u8, id, "[:") orelse id.len];
    for ([_][]const u8{ "fast", "ultrafast", "highspeed" }) |kind| {
        if (std.ascii.eqlIgnoreCase(name, kind)) return error.PremiumSpeedModelDisabled;
        if (name.len > kind.len and name[name.len - kind.len - 1] == '-' and
            std.ascii.eqlIgnoreCase(name[name.len - kind.len ..], kind))
            return error.PremiumSpeedModelDisabled;
    }
}
