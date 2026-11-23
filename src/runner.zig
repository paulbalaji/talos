const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");
const codex = @import("reviewers/codex.zig");
const claude = @import("reviewers/claude.zig");
const kimi = @import("reviewers/kimi.zig");
pub const Profile = @import("reviewers/shared.zig").Profile;

fn adapter(comptime engine: core.Engine) type {
    return switch (engine) {
        .codex => codex,
        .claude => claude,
        .kimi => kimi,
    };
}

pub fn configureEnvironment(engine: core.Engine, profile: Profile, parent: *const std.process.EnvMap, child: *std.process.EnvMap) !void {
    switch (engine) {
        inline else => |selected| {
            const reviewer = adapter(selected);
            for (reviewer.auth_env) |name| {
                if (parent.get(name)) |value| try child.put(name, value);
            }
            try reviewer.configureEnv(child, profile);
        },
    }
}

pub const Runner = struct {
    cmd: io.Command,
    bin: []const u8,
    engine: core.Engine,
    profile: Profile,

    pub fn review(self: Runner, prompt: []const u8) ![]const u8 {
        // Keep the same bound for all reviewers. Kimi passes the prompt as
        // one argument, so it must fit below Linux's per-argument limit.
        if (prompt.len > 96 * 1024) return error.ReviewContextLimit;
        switch (self.engine) {
            inline else => |engine| {
                const reviewer = adapter(engine);
                const invocation = try reviewer.prepare(self.cmd, self.bin, self.profile, prompt);
                const output = self.cmd.run(invocation.args, invocation.stdin, 900) catch |err| {
                    if (err == error.SubprocessTimeout) return error.ReviewerTimedOut;
                    return reviewer.failure;
                };
                return reviewer.result(self.cmd, output);
            },
        }
    }
};

test "reviewer envelope decoding preserves strict validation downstream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = std.process.EnvMap.init(a);
    const cmd: io.Command = .{ .a = a, .env = &env, .cwd = ".", .dir = std.fs.cwd() };
    try std.testing.expectEqualStrings("{\"complete\":true}", try kimi.result(cmd, "{\"role\":\"assistant\",\"content\":\"{\\\"complete\\\":true}\"}\n{\"role\":\"meta\",\"type\":\"session.resume_hint\"}\n"));
    try std.testing.expectEqualStrings("{\"complete\":true}", try claude.result(cmd, "{\"is_error\":false,\"structured_output\":{\"complete\":true}}"));
}

test "reviewer command profiles pin default models and preserve explicit overrides" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = std.process.EnvMap.init(a);
    const scratch = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(scratch) catch {};
    var dir = try std.fs.openDirAbsolute(scratch, .{});
    defer dir.close();
    const cmd: io.Command = .{ .a = a, .env = &env, .cwd = scratch, .dir = dir };
    const cases = [_]struct {
        engine: core.Engine,
        profile: Profile = .{},
        expected_tail: []const []const u8,
        stdin: []const u8 = "prompt",
    }{
        .{ .engine = .codex, .expected_tail = &.{ "-m", "gpt-6.2-sol", "-c", "model_reasoning_effort=\"high\"", "-" } },
        .{ .engine = .claude, .profile = .{ .advisor = "fable" }, .expected_tail = &.{ "--model", "opus", "--effort", "high", "--advisor", "fable" } },
        .{ .engine = .kimi, .expected_tail = &.{ "-m", "kimi-code/k3.1-pro", "-p", "prompt" }, .stdin = "" },
        .{ .engine = .codex, .profile = .{ .model = "custom-model", .effort = .default }, .expected_tail = &.{ "-m", "custom-model", "-" } },
        .{ .engine = .claude, .profile = .{ .model = "sonnet", .effort = .medium }, .expected_tail = &.{ "--model", "sonnet", "--effort", "medium" } },
    };
    inline for (cases) |case| {
        const invocation = try adapter(case.engine).prepare(cmd, @tagName(case.engine), case.profile, "prompt");
        try t.expectEqualStrings(case.stdin, invocation.stdin);
        try t.expect(invocation.args.len >= case.expected_tail.len);
        const tail = invocation.args[invocation.args.len - case.expected_tail.len ..];
        for (case.expected_tail, tail) |expected, actual| try t.expectEqualStrings(expected, actual);
    }
}
