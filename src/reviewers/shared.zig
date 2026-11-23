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
