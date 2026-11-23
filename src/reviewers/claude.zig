const std = @import("std");
const core = @import("../core.zig");
const io = @import("../io.zig");
const shared = @import("shared.zig");

pub const auth_env = [_][]const u8{ "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN" };
pub const failure = error.ClaudeFailed;

pub fn configureEnv(env: *std.process.EnvMap, profile: shared.Profile) !void {
    try env.put("CLAUDE_CODE_DISABLE_FAST_MODE", "1");
    if (profile.advisor == null) try env.put("CLAUDE_CODE_DISABLE_ADVISOR_TOOL", "1");
}

pub fn prepare(cmd: io.Command, bin: []const u8, profile: shared.Profile, prompt: []const u8) !shared.Invocation {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(cmd.a, &.{
        bin,                         "-p",                                                            "--restricted",             "--tools",                  "",
        "--setting-sources",         "",                                                              "--strict-mcp-config",      "--disable-slash-commands", "--no-chrome",
        "--settings",                "{\"disableAllHooks\":true,\"disableClaudeAiConnectors\":true}", "--no-session-persistence", "--permission-mode",        "dontAsk",
        "--output-format",           "json",                                                          "--json-schema",            core.schema,                "--model",
        profile.model orelse "opus",
    });
    if (profile.effort != .default) try args.appendSlice(cmd.a, &.{ "--effort", @tagName(profile.effort) });
    if (profile.advisor) |advisor| try args.appendSlice(cmd.a, &.{ "--advisor", advisor });
    return .{ .args = args.items, .stdin = prompt };
}

pub fn result(cmd: io.Command, output: []const u8) ![]const u8 {
    const decoded = try io.parse(cmd.a, struct {
        is_error: bool,
        structured_output: ?std.json.Value = null,
    }, output);
    if (decoded.is_error) return failure;
    return io.json(cmd.a, decoded.structured_output orelse return error.InvalidReview);
}
