const std = @import("std");
const core = @import("core.zig");
const routing = @import("routing.zig");
const reviewer_profile = @import("reviewers/shared.zig");
const A = std.mem.Allocator;
const eq = std.mem.eql;

pub const Tool = enum { git, gh, codex, claude, kimi };
pub const Programs = struct {
    git: []const u8 = "git",
    gh: []const u8 = "gh",
    codex: []const u8 = "codex",
    claude: []const u8 = "claude",
    kimi: []const u8 = "kimi",

    pub fn fromRepo(repo: ?core.Repo) Programs {
        const entry = repo orelse return .{};
        return .{ .git = entry.git, .gh = entry.gh, .codex = entry.codex, .claude = entry.claude, .kimi = entry.kimi };
    }
};

const Config = struct { repo: core.Repo, programs: Programs };

pub fn parse(a: A, name: []const u8, previous: ?core.Repo, default_engines: []const core.Engine, args: []const []const u8) !Config {
    var repo: core.Repo = .{
        .name = name,
        .login = "",
    };
    if (previous) |old| {
        repo.reviewer_efforts = old.reviewer_efforts;
        repo.claude_advisor = old.claude_advisor;
    }
    var programs = Programs.fromRepo(previous);
    var engines = if (previous) |old| try old.engines(a) else default_engines;
    var new_engines = false;
    var models = std.EnumArray(core.Engine, ?[]const u8).initFill(null);
    var light = std.EnumArray(core.Engine, ?[]const u8).initFill(null);
    var explicit_light: std.EnumSet(core.Engine) = .initEmpty();
    if (previous) |old| {
        repo.routing_mode = old.routing_mode;
        repo.fallback_engines = old.fallback_engines;
        for (old.light_models) |model| light.set(model.engine, model.model);
    }
    var options = args;
    // Preserve the v0 command line without opening the old checkout.
    if (options.len != 0 and !std.mem.startsWith(u8, options[0], "--")) options = options[1..];
    while (options.len > 0) {
        const opt = options[0];
        options = options[1..];
        if (eq(u8, opt, "--comments")) {
            repo.comments = true;
        } else if (eq(u8, opt, "--approvals")) {
            repo.approvals = true;
        } else {
            if (options.len == 0) return error.Usage;
            const value = options[0];
            options = options[1..];
            if (eq(u8, opt, "--interval")) {
                repo.interval = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidInterval;
                if (repo.interval < 15) return error.InvalidInterval;
            } else if (eq(u8, opt, "--cache-mib")) {
                repo.cache_mib = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidCacheSize;
            } else if (eq(u8, opt, "--cache-idle-days")) {
                repo.cache_idle_days = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidCacheAge;
                if (repo.cache_idle_days == 0) return error.InvalidCacheAge;
            } else if (eq(u8, opt, "--engine")) {
                engines = try parseEngines(a, value);
                new_engines = true;
            } else if (eq(u8, opt, "--model")) {
                repo.model = try modelName(value);
            } else if (eq(u8, opt, "--reviewer-model")) {
                const split = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidModel;
                const engine = std.meta.stringToEnum(core.Engine, value[0..split]) orelse return error.UnknownReviewer;
                models.set(engine, try modelName(value[split + 1 ..]));
            } else if (eq(u8, opt, "--routing")) {
                repo.routing_mode = std.meta.stringToEnum(routing.Mode, value) orelse return error.InvalidRoutingMode;
            } else if (eq(u8, opt, "--fallback")) {
                repo.fallback_engines = if (eq(u8, value, "off")) &.{} else try parseEngines(a, value);
            } else if (eq(u8, opt, "--light-model")) {
                const split = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidModel;
                const engine = std.meta.stringToEnum(core.Engine, value[0..split]) orelse return error.UnknownReviewer;
                explicit_light.insert(engine);
                light.set(engine, if (eq(u8, value[split + 1 ..], "off")) null else try modelName(value[split + 1 ..]));
            } else if (eq(u8, opt, "--reviewer-effort")) {
                const split = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidReviewerEffort;
                const engine = std.meta.stringToEnum(core.Engine, value[0..split]) orelse return error.UnknownReviewer;
                const effort = std.meta.stringToEnum(core.ReviewEffort, value[split + 1 ..]) orelse return error.InvalidReviewerEffort;
                if (engine == .kimi and (effort == .medium or effort == .xhigh)) return error.InvalidReviewerEffort;
                switch (engine) {
                    inline else => |selected| @field(repo.reviewer_efforts, @tagName(selected)) = effort,
                }
            } else if (eq(u8, opt, "--claude-advisor")) {
                repo.claude_advisor = std.meta.stringToEnum(core.ClaudeAdvisor, value) orelse return error.InvalidClaudeAdvisor;
            } else if (std.mem.startsWith(u8, opt, "--")) {
                const tool = std.meta.stringToEnum(Tool, opt[2..]) orelse return error.Usage;
                switch (tool) {
                    inline else => |t| @field(programs, @tagName(t)) = value,
                }
            } else return error.Usage;
        }
    }
    try core.validateEngines(engines);
    repo.engine = engines[0];
    repo.additional_engines = engines[1..];
    const pool = try repo.providers(a);
    try core.validateEngines(pool);
    var lightweight: std.ArrayList(core.ReviewerModel) = .empty;
    var light_options = light.iterator();
    while (light_options.next()) |option| {
        if (option.value.*) |model| {
            if (std.mem.indexOfScalar(core.Engine, pool, option.key) == null) {
                if (explicit_light.contains(option.key)) return error.ReviewerModelForUnselectedEngine;
                continue;
            }
            try lightweight.append(a, .{ .engine = option.key, .model = model });
        }
    }
    repo.light_models = lightweight.items;
    var model_options = models.iterator();
    while (model_options.next()) |option| {
        if (option.value.* != null and std.mem.indexOfScalar(core.Engine, pool, option.key) == null)
            return error.ReviewerModelForUnselectedEngine;
    }
    const retained = if (new_engines) null else previous;
    if (models.get(repo.engine)) |named| {
        repo.model = named;
    } else if (repo.model == null) {
        if (retained) |old| repo.model = old.modelFor(repo.engine);
    }
    var additional_models: std.ArrayList(core.ReviewerModel) = .empty;
    for (pool[1..]) |engine| {
        const model = models.get(engine) orelse if (retained) |old| old.modelFor(engine) else null;
        if (model) |value| try additional_models.append(a, .{ .engine = engine, .model = value });
    }
    repo.additional_models = additional_models.items;
    return .{ .repo = repo, .programs = programs };
}

fn modelName(value: []const u8) ![]const u8 {
    if (value.len == 0 or value[0] == '-' or value.len > 200) return error.InvalidModel;
    try reviewer_profile.requireStandardModel(value);
    return value;
}

pub fn parseEngines(a: A, value: []const u8) ![]const core.Engine {
    var parts = std.mem.splitScalar(u8, value, ',');
    var engines: std.ArrayList(core.Engine) = .empty;
    while (parts.next()) |part| {
        const engine = std.meta.stringToEnum(core.Engine, part) orelse return error.UnknownReviewer;
        if (std.mem.indexOfScalar(core.Engine, engines.items, engine) != null) return error.DuplicateReviewer;
        try engines.append(a, engine);
    }
    return engines.toOwnedSlice(a);
}

test "registration options preserve overrides and reset publication unless selected" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try parse(a, "example/repo", null, &.{ .claude, .codex }, &.{
        "/old/checkout",
        "--model",
        "opus",
        "--reviewer-model",
        "claude=sonnet",
        "--reviewer-model",
        "codex=codex-test",
        "--reviewer-effort",
        "codex=medium",
        "--claude-advisor",
        "off",
        "--claude",
        "/bin/reviewer",
        "--comments",
        "--approvals",
    });
    try t.expectEqualSlices(core.Engine, &.{ .claude, .codex }, try first.repo.engines(a));
    try t.expectEqualStrings("sonnet", first.repo.modelFor(.claude).?);
    try t.expectEqualStrings("codex-test", first.repo.modelFor(.codex).?);
    try t.expect(first.repo.comments and first.repo.approvals);

    var saved = first.repo;
    saved.claude = first.programs.claude;
    const updated = try parse(a, saved.name, saved, &.{.kimi}, &.{ "--interval", "240" });
    try t.expectEqualSlices(core.Engine, &.{ .claude, .codex }, try updated.repo.engines(a));
    try t.expectEqualStrings("sonnet", updated.repo.modelFor(.claude).?);
    try t.expectEqualStrings("codex-test", updated.repo.modelFor(.codex).?);
    try t.expectEqualStrings("/bin/reviewer", updated.programs.claude);
    try t.expectEqual(@as(u32, 240), updated.repo.interval);
    try t.expect(!updated.repo.comments and !updated.repo.approvals);

    const switched = try parse(a, saved.name, saved, &.{.kimi}, &.{ "--engine", "codex" });
    try t.expectEqual(core.Engine.codex, switched.repo.engine);
    try t.expect(switched.repo.modelFor(.codex) == null);
    try t.expectEqual(core.ReviewEffort.medium, switched.repo.reviewer_efforts.get(.codex));
    try t.expectEqual(core.ClaudeAdvisor.off, switched.repo.claude_advisor);
    try t.expectError(error.PremiumSpeedModelDisabled, parse(a, saved.name, saved, &.{.kimi}, &.{
        "--engine", "kimi", "--reviewer-model", "kimi=kimi-code/kimi-for-coding-highspeed",
    }));
}

test "adaptive settings resolve the explicit provider pool and retain model overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try parse(a, "example/repo", null, &.{.codex}, &.{
        "--routing", "adaptive", "--fallback", "claude,kimi", "--light-model", "claude=haiku", "--reviewer-model", "kimi=custom",
    });
    try std.testing.expectEqualSlices(core.Engine, &.{ .codex, .claude, .kimi }, try first.repo.providers(a));
    const retained = try parse(a, "example/repo", first.repo, &.{.codex}, &.{"--comments"});
    try std.testing.expectEqual(routing.Mode.adaptive, retained.repo.routing_mode);
    try std.testing.expectEqualStrings("haiku", retained.repo.lightModel(.claude).?);
    try std.testing.expectEqualStrings("custom", retained.repo.modelFor(.kimi).?);
    const removed = try parse(a, "example/repo", first.repo, &.{.codex}, &.{ "--routing", "fixed", "--fallback", "off" });
    try std.testing.expectEqual(@as(usize, 0), removed.repo.light_models.len);
    try std.testing.expectError(error.ReviewerModelForUnselectedEngine, parse(a, "example/repo", null, &.{.codex}, &.{ "--light-model", "claude=haiku" }));
}
