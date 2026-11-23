const std = @import("std");
const core = @import("../core.zig");
const io = @import("../io.zig");
const shared = @import("shared.zig");

pub const auth_env = [_][]const u8{ "CODEX_HOME", "OPENAI_API_KEY" };
pub const failure = error.CodexFailed;

pub fn configureEnv(_: *std.process.EnvMap, _: shared.Profile) !void {}

pub fn prepare(cmd: io.Command, bin: []const u8, profile: shared.Profile, prompt: []const u8) !shared.Invocation {
    cmd.dir.deleteFile("result.json") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try io.write(cmd.dir, "schema.json", core.schema);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(cmd.a, &.{
        bin,                     "exec",                     "--ignore-user-config", "--ignore-rules",
        "--ephemeral",           "--skip-git-repo-check",    "--sandbox",            "read-only",
        "--color",               "never",                    "--disable",            "shell_tool",
        "--disable",             "apps",                     "--disable",            "plugins",
        "--disable",             "hooks",                    "--disable",            "computer_use",
        "--disable",             "browser_use",              "--disable",            "multi_agent_v2",
        "--disable",             "code_mode",                "-c",                   "approval_policy=\"never\"",
        "-c",                    "web_search=\"disabled\"",  "-c",                   "project_doc_max_bytes=0",
        "--disable",             "fast_mode",                "--disable",            "ultrafast_mode",
        "-c",                    "service_tier=\"default\"", "--output-schema",      "schema.json",
        "--output-last-message", "result.json",              "-m",                   profile.model orelse "gpt-6.2-sol",
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
