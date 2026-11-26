const std = @import("std");
const io = @import("../io.zig");
const shared = @import("shared.zig");
const telemetry = @import("../telemetry.zig");

pub const auth_env = [_][]const u8{ "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN" };
pub const failure = error.ClaudeFailed;
pub const default_model = "opus";

pub fn configureEnv(env: *std.process.EnvMap, profile: shared.Profile) !void {
    try env.put("CLAUDE_CODE_DISABLE_FAST_MODE", "1");
    if (profile.advisor == null) try env.put("CLAUDE_CODE_DISABLE_ADVISOR_TOOL", "1");
}

pub fn prepare(cmd: io.Command, bin: []const u8, profile: shared.Profile, prompt: []const u8, schema: []const u8) !shared.Invocation {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(cmd.a, &.{
        bin,                                "-p",                                                            "--restricted",             "--tools",                  "",
        "--setting-sources",                "",                                                              "--strict-mcp-config",      "--disable-slash-commands", "--no-chrome",
        "--settings",                       "{\"disableAllHooks\":true,\"disableClaudeAiConnectors\":true}", "--no-session-persistence", "--permission-mode",        "dontAsk",
        "--output-format",                  "json",                                                          "--json-schema",            schema,                     "--model",
        profile.model orelse default_model,
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
    if (decoded.is_error) return if (io.claudeRateLimit(cmd.a, output)) error.ClaudeRateLimited else failure;
    return io.json(cmd.a, decoded.structured_output orelse return error.InvalidReview);
}

fn totalInput(uncached: ?u64, cached: ?u64, written: ?u64) ?u64 {
    const input = uncached orelse return null;
    const before_write = std.math.add(u64, input, cached orelse return null) catch return null;
    return std.math.add(u64, before_write, written orelse return null) catch null;
}

fn counter(map: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = map.get(name) orelse return null;
    return switch (value) {
        .integer => |number| std.math.cast(u64, number),
        else => null,
    };
}

pub fn report(a: io.A, output: []const u8) shared.Report {
    const Terminal = struct {
        type: []const u8,
        is_error: bool,
        usage: ?struct {
            input_tokens: ?u64 = null,
            output_tokens: ?u64 = null,
            cache_read_input_tokens: ?u64 = null,
            cache_creation_input_tokens: ?u64 = null,
        } = null,
        modelUsage: ?std.json.Value = null,
    };
    const parsed = std.json.parseFromSlice(Terminal, a, output, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    if (!io.eq(u8, parsed.value.type, "result")) return .{};

    var captured: shared.Report = .{};
    if (parsed.value.usage) |usage| {
        const tokens: telemetry.Tokens = .{
            .input = totalInput(usage.input_tokens, usage.cache_read_input_tokens, usage.cache_creation_input_tokens),
            .output = usage.output_tokens,
            .cached_input = usage.cache_read_input_tokens,
            .cache_write_input = usage.cache_creation_input_tokens,
        };
        if (tokens.known()) captured.tokens = tokens;
    }
    if (parsed.value.modelUsage) |models| {
        if (models == .object and models.object.count() <= 16) {
            var per_model: std.ArrayList(telemetry.ModelUsage) = .empty;
            for (models.object.keys(), models.object.values()) |key, value| {
                const model = shared.modelLabel(key);
                if (io.eq(u8, model, "unknown") or value != .object) continue;
                const map = value.object;
                const cached = counter(map, "cacheReadInputTokens");
                const written = counter(map, "cacheCreationInputTokens");
                const tokens: telemetry.Tokens = .{
                    .input = totalInput(counter(map, "inputTokens"), cached, written),
                    .output = counter(map, "outputTokens"),
                    .cached_input = cached,
                    .cache_write_input = written,
                };
                if (!tokens.known()) continue;
                per_model.append(a, .{ .model = a.dupe(u8, model) catch return captured, .tokens = tokens }) catch return captured;
            }
            captured.model_usage = per_model.items;
        }
    }
    return captured;
}
