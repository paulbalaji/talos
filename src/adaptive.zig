const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");
const routing = @import("routing.zig");

pub const Plan = struct {
    repo: core.Repo,
    providers: []const core.Engine,
    prepared: core.Prepared,
    screen: routing.Screen,
    progress: core.RouteProgress,
    start_limit: u32,
};

pub const Outcome = struct {
    progress: core.RouteProgress,
    report: ?core.RouteReport = null,
    failure: ?anyerror = null,
};

fn unavailable(err: anyerror) bool {
    return switch (err) {
        error.ProviderBudgetReached, error.CodexRateLimited, error.ClaudeRateLimited, error.KimiRateLimited => true,
        else => false,
    };
}

fn appliedDecision(plan: Plan, progress: core.RouteProgress) routing.Decision {
    if (plan.repo.routing_mode != .adaptive or !plan.prepared.options.allowRouting()) return .{};
    return progress.decision orelse plan.screen.floor;
}

pub fn requestedCount(repo: core.Repo, decision: routing.Decision) usize {
    return if (decision.depth == .multi) @max(2, repo.reviewSize()) else repo.reviewSize();
}

fn hasProvider(results: []const core.ReviewerResult, engine: core.Engine) bool {
    for (results) |result| if (result.engine == engine) return true;
    return false;
}

// A job has a fixed number of starts reserved for this tick. Successful passes
// are carried forward by the coordinator when a later pass needs a new tick.
pub fn run(a: io.A, reviewer: anytype, plan: Plan) !Outcome {
    var outcome: Outcome = .{ .progress = plan.progress };
    const progress = &outcome.progress;
    if (progress.screen_waiting) try screen(a, reviewer, plan, progress);

    const applied = appliedDecision(plan, progress.*);
    if (applied.depth == .light) {
        const first_pass = progress.screen_result orelse return error.InvalidScreenDecision;
        progress.results = try a.dupe(core.ReviewerResult, &.{first_pass});
        outcome.report = try report(a, plan, progress.*, applied);
        return outcome;
    }

    const required = requestedCount(plan.repo, applied);
    if (plan.providers.len < required) {
        // Keep the decision and pin for discovery without retaining a review.
        progress.screen_result = null;
        return outcome;
    }
    const prompt = try core.routedPrompt(a, plan.prepared.context, applied);
    // If only the additional lens header would overflow the transport, keep
    // its requirements and mark the review incomplete rather than dropping a lens.
    if (prompt.len > core.review_context_limit) return error.ReviewContextLimit;
    for (plan.providers) |engine| {
        if (progress.results.len == required or reviewer.starts() >= plan.start_limit) break;
        if (hasProvider(progress.results, engine) or !reviewer.available(engine)) continue;

        var timer = try std.time.Timer.start();
        const raw = reviewer.routeReview(engine, null, core.schema, prompt) catch |err| {
            progress.review_ms +|= timer.read() / std.time.ns_per_ms;
            if (unavailable(err)) continue;
            outcome.failure = err;
            return outcome;
        };
        progress.review_ms +|= timer.read() / std.time.ns_per_ms;
        const result = core.parseReview(a, raw) catch |err| {
            outcome.failure = err;
            return outcome;
        };
        progress.results = try std.mem.concat(a, core.ReviewerResult, &.{ progress.results, &.{.{ .engine = engine, .review = result }} });
    }
    if (progress.results.len == required) outcome.report = try report(a, plan, progress.*, applied);
    return outcome;
}

fn screen(a: io.A, reviewer: anytype, plan: Plan, progress: *core.RouteProgress) !void {
    progress.screen_waiting = false;
    const eligible = plan.repo.routing_mode != .fixed and plan.prepared.options.allowRouting() and plan.screen.ask_model;
    if (!eligible) {
        progress.decision = if (plan.screen.floor.depth == .light) .{} else plan.screen.floor;
        return;
    }
    const prompt = try core.screenPrompt(a, plan.prepared);
    if (prompt.len <= core.review_context_limit) {
        for (plan.providers) |engine| {
            if (reviewer.starts() >= plan.start_limit) break;
            const model = plan.repo.lightModel(engine) orelse continue;
            if (!reviewer.available(engine)) continue;
            var timer = try std.time.Timer.start();
            const raw = reviewer.routeReview(engine, model, core.screen_schema, prompt) catch |err| {
                progress.screen_ms +|= timer.read() / std.time.ns_per_ms;
                if (unavailable(err)) continue;
                break;
            };
            progress.screen_ms +|= timer.read() / std.time.ns_per_ms;
            const result = core.parseScreen(a, raw) catch break;
            progress.screen_result = .{ .engine = engine, .review = result.review };
            var decision = plan.screen.floor.merge(result.decision);
            if (decision.depth == .light and (plan.repo.reviewSize() > 1 or !core.lightComplete(result.review, plan.prepared)))
                decision.depth = .regular;
            progress.decision = decision;
            return;
        }
    }
    // Unsupported models, invalid responses and exhausted screening quota
    // all fall through to the full review.
    progress.decision = if (plan.screen.floor.depth == .light) .{} else plan.screen.floor;
}

fn report(a: io.A, plan: Plan, progress: core.RouteProgress, applied: routing.Decision) !core.RouteReport {
    const providers = try a.alloc(core.Engine, progress.results.len);
    for (providers, progress.results) |*engine, result| engine.* = result.engine;
    var result: core.RouteReport = .{
        .mode = plan.repo.routing_mode,
        .suggested = progress.decision orelse .{},
        .applied = applied,
        .screen_provider = if (progress.screen_result) |candidate| candidate.engine else null,
        .providers = providers,
        .screen_ms = progress.screen_ms,
        .review_ms = progress.review_ms,
    };
    if (progress.screen_result) |candidate| {
        result.light_findings = candidate.review.findings.len;
        if (applied.depth != .light) core.compareRoute(&result, candidate.review, progress.results);
    }
    return result;
}

const clean_result =
    \\{"complete":true,"summary":"Static fixture review.","findings":[],"existing_open_findings":[],"non_blocking_threads":[]}
;

const light_screen =
    \\{"decision":{"depth":"light","performance":false,"reliability":false,"security":false},"review":
++ clean_result ++ "}";

const MockReviewer = struct {
    calls: [5]core.Engine = undefined,
    count: u32 = 0,
    unavailable_engine: ?core.Engine = null,
    screen_enabled: bool = true,
    screen_rate_limit: bool = false,

    pub fn available(self: *MockReviewer, engine: core.Engine) bool {
        return self.unavailable_engine != engine;
    }

    pub fn starts(self: *MockReviewer) u32 {
        return self.count;
    }

    pub fn routeReview(self: *MockReviewer, engine: core.Engine, model: ?[]const u8, schema: []const u8, prompt: []const u8) ![]const u8 {
        self.calls[self.count] = engine;
        self.count += 1;
        if (model != null) {
            try std.testing.expectEqualStrings(core.screen_schema, schema);
            if (self.screen_rate_limit and engine == .codex) return error.CodexRateLimited;
            return if (self.screen_enabled) light_screen else "malformed";
        }
        try std.testing.expect(!std.mem.containsAtLeast(u8, prompt, 1, "Choose review fidelity"));
        return clean_result;
    }
};

const sample_plan: Plan = .{
    .repo = .{
        .name = "example/repo",
        .login = "reviewer",
        .routing_mode = .adaptive,
        .fallback_engines = &.{.claude},
        .light_models = &.{.{ .engine = .codex, .model = "fixture" }},
    },
    .providers = &.{ .codex, .claude },
    .prepared = .{
        .pr = .{ .number = 1, .headRefOid = "head", .isDraft = false },
        .snap = .{ .merge_base = "base", .evidence = "diff" },
        .threads = &.{},
        .inherited = .{},
        .engines = &.{.codex},
        .context = "Pinned review input",
        .evidence_offset = 0,
        .options = .{},
        .dry = false,
    },
    .screen = .{ .floor = .{ .depth = .light }, .ask_model = true },
    .progress = .{ .fingerprint = @splat(1) },
    .start_limit = 3,
};

test "shadow retains full review and a malformed lightweight response falls through" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reviewer: MockReviewer = .{};
    const light = try run(a, &reviewer, sample_plan);
    try t.expectEqual(routing.Depth.light, light.report.?.applied.depth);
    try t.expectEqual(@as(u32, 1), reviewer.count);

    var shadow = sample_plan;
    shadow.repo.routing_mode = .shadow;
    reviewer = .{};
    const combined = try run(a, &reviewer, shadow);
    try t.expectEqual(routing.Depth.regular, combined.report.?.applied.depth);
    try t.expectEqual(routing.Depth.light, combined.report.?.suggested.depth);
    try t.expectEqual(@as(u32, 2), reviewer.count);
    try t.expectEqual(@as(?usize, 0), combined.report.?.full_only_anchors);

    reviewer = .{ .screen_enabled = false };
    const malformed = try run(a, &reviewer, sample_plan);
    try t.expectEqual(routing.Depth.regular, malformed.report.?.applied.depth);
    try t.expectEqual(@as(u32, 2), reviewer.count);

    var manual = sample_plan;
    manual.prepared.options.explicit_mode = true;
    reviewer = .{};
    const explicit = try run(a, &reviewer, manual);
    try t.expectEqual(@as(?core.Engine, null), explicit.report.?.screen_provider);
    try t.expectEqual(@as(u32, 1), reviewer.count);
}

test "independence survives a pause and a completed provider is never repeated" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan = sample_plan;
    plan.screen = .{ .floor = .{ .depth = .multi, .security = true }, .ask_model = false };
    var first: MockReviewer = .{ .unavailable_engine = .claude };
    const pending = try run(a, &first, plan);
    try t.expect(pending.report == null);
    try t.expectEqual(@as(usize, 1), pending.progress.results.len);
    plan.progress = try io.parse(a, core.RouteProgress, try io.json(a, pending.progress));

    var resumed: MockReviewer = .{};
    const final = try run(a, &resumed, plan);
    try t.expectEqual(routing.Depth.multi, final.report.?.applied.depth);
    try t.expectEqualSlices(core.Engine, &.{ .codex, .claude }, final.report.?.providers);
    try t.expectEqualSlices(core.Engine, &.{.claude}, resumed.calls[0..resumed.count]);
}

test "an authorized light model takes over screening after a provider rate limit" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var plan = sample_plan;
    plan.repo.light_models = &.{
        .{ .engine = .codex, .model = "primary-fixture" },
        .{ .engine = .claude, .model = "fallback-fixture" },
    };
    plan.start_limit = @import("queue.zig").reviewerCost(plan.repo);
    try t.expectEqual(@as(u32, 4), plan.start_limit);
    var reviewer: MockReviewer = .{ .screen_rate_limit = true };
    const outcome = try run(arena.allocator(), &reviewer, plan);
    try t.expectEqual(routing.Depth.light, outcome.report.?.applied.depth);
    try t.expectEqual(@as(?core.Engine, .claude), outcome.report.?.screen_provider);
    try t.expectEqualSlices(core.Engine, &.{ .codex, .claude }, reviewer.calls[0..reviewer.count]);
}
