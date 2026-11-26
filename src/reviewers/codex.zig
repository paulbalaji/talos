const std = @import("std");
const io = @import("../io.zig");
const shared = @import("shared.zig");
const telemetry = @import("../telemetry.zig");

pub const auth_env = [_][]const u8{ "CODEX_HOME", "OPENAI_API_KEY" };
pub const failure = error.CodexFailed;
pub const default_model = "gpt-6.2-sol";

pub fn configureEnv(_: *std.process.EnvMap, _: shared.Profile) !void {}

pub fn prepare(cmd: io.Command, bin: []const u8, profile: shared.Profile, prompt: []const u8, schema: []const u8) !shared.Invocation {
    cmd.dir.deleteFile("result.json") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try io.write(cmd.dir, "schema.json", schema);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(cmd.a, &.{
        bin,                                "exec",                  "--ignore-user-config",     "--ignore-rules",
        "--ephemeral",                      "--skip-git-repo-check", "--sandbox",                "read-only",
        "--json",                           "--color",               "never",                    "--disable",
        "shell_tool",                       "--disable",             "apps",                     "--disable",
        "plugins",                          "--disable",             "hooks",                    "--disable",
        "computer_use",                     "--disable",             "browser_use",              "--disable",
        "multi_agent_v2",                   "--disable",             "code_mode",                "-c",
        "approval_policy=\"never\"",        "-c",                    "web_search=\"disabled\"",  "-c",
        "project_doc_max_bytes=0",          "--disable",             "fast_mode",                "--disable",
        "ultrafast_mode",                   "-c",                    "service_tier=\"default\"", "--output-schema",
        "schema.json",                      "--output-last-message", "result.json",              "-m",
        profile.model orelse default_model,
    });
    if (profile.effort != .default) {
        const setting = try io.fmt(cmd.a, "model_reasoning_effort=\"{s}\"", .{@tagName(profile.effort)});
        try args.appendSlice(cmd.a, &.{ "-c", setting });
    }
    try args.append(cmd.a, "-");
    return .{ .args = args.items, .stdin = prompt };
}

pub fn result(cmd: io.Command, _: []const u8) ![]const u8 {
    return cmd.dir.readFileAlloc(cmd.a, "result.json", 128 * 1024);
}

pub fn report(a: io.A, output: []const u8) shared.Report {
    const Terminal = struct {
        type: []const u8,
        usage: struct {
            input_tokens: ?u64 = null,
            output_tokens: ?u64 = null,
            cached_input_tokens: ?u64 = null,
            cache_write_input_tokens: ?u64 = null,
            reasoning_output_tokens: ?u64 = null,
        },
    };
    var lines = std.mem.splitBackwardsScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"turn.completed\"") == null) continue;
        const parsed = std.json.parseFromSlice(Terminal, a, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        if (!io.eq(u8, parsed.value.type, "turn.completed")) continue;
        const usage = parsed.value.usage;
        const tokens: telemetry.Tokens = .{
            .input = usage.input_tokens,
            .output = usage.output_tokens,
            .cached_input = usage.cached_input_tokens,
            .cache_write_input = usage.cache_write_input_tokens,
            .reasoning_output = usage.reasoning_output_tokens,
        };
        return .{ .tokens = if (tokens.known()) tokens else null };
    }
    return .{};
}
