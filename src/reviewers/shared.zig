const std = @import("std");
const core = @import("../core.zig");

pub const Profile = struct {
    model: ?[]const u8 = null,
    effort: core.ReviewEffort = .high,
    advisor: ?[]const u8 = null,
};

pub const Invocation = struct {
    args: []const []const u8,
    stdin: []const u8,
};

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
