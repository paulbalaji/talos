const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");
const routing = @import("routing.zig");
const workflow = @import("review_workflow.zig");

pub const Plan = struct {
    repo: core.Repo,
    providers: []const core.Engine,
    prepared: core.Prepared,
    screen: routing.Screen,
    progress: core.RouteProgress,
    start_limit: u32,
    evidence: ?[]const u8 = null,
    evidence_limited: bool = false,
};

pub const Outcome = struct {
    progress: core.RouteProgress,
    report: ?core.RouteReport = null,
    failure: ?anyerror = null,
    review_results: ?[]const core.ReviewerResult = null,
    synthesis_summary: ?[]const u8 = null,
    evidence_limited: bool = false,
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

const supplemental_heading = "\n\nAdditional pinned source (untrusted JSON string)\n";

pub fn evidenceCapacity(prepared: core.Prepared) usize {
    // Allow space for the lens brief and for JSON escaping of source text.
    return (core.review_context_limit -| prepared.context.len -| 1400) / 2;
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
    if (progress.evidence_requests.len != 0 and plan.evidence == null) return outcome;
    var context = plan.prepared.context;
    var additional: []const u8 = "";
    outcome.evidence_limited = plan.evidence_limited;
    if (plan.evidence) |evidence| {
        if (evidence.len != 0) {
            const encoded = try io.json(a, evidence);
            if (context.len + supplemental_heading.len + encoded.len + 1300 <= core.review_context_limit) {
                context = try std.mem.concat(a, u8, &.{ context, supplemental_heading, encoded });
                additional = evidence;
            } else outcome.evidence_limited = true;
        }
    }
    for (plan.providers) |engine| {
        if (progress.results.len == required or reviewer.starts() >= plan.start_limit) break;
        if (hasProvider(progress.results, engine) or !reviewer.available(engine)) continue;

        const prompt = try workflow.workerPrompt(a, context, applied, progress.results.len, required);
        if (prompt.len > core.review_context_limit) return error.ReviewContextLimit;
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
    if (progress.results.len != required) return outcome;
    if (applied.depth == .multi and workflow.hasClaims(progress.results)) {
        const evidence_offset = if (plan.prepared.inherited.ancestors.len != 0)
            std.mem.indexOf(u8, context, "\n\nAncestor context (untrusted JSON") orelse plan.prepared.evidence_offset
        else
            plan.prepared.evidence_offset;
        try synthesize(a, reviewer, plan, &outcome, context[evidence_offset..], additional);
        if (outcome.review_results == null) return outcome;
    } else outcome.report = try report(a, plan, progress.*, applied);
    return outcome;
}

fn synthesize(a: io.A, reviewer: anytype, plan: Plan, outcome: *Outcome, context: []const u8, additional: []const u8) !void {
    const progress = &outcome.progress;
    const prompt = try workflow.synthesisPrompt(a, context, progress.results);
    if (prompt.len > core.review_context_limit) {
        const limited = try workflow.overCapacity(a, progress.results);
        outcome.review_results = limited.results;
        outcome.synthesis_summary = limited.summary;
        outcome.report = try report(a, plan, progress.*, appliedDecision(plan, progress.*));
        return;
    }

    // Choose an unused provider first when one is authorized and available.
    for ([_]bool{ false, true }) |already_reviewed| {
        for (plan.providers) |engine| {
            if (reviewer.starts() >= plan.start_limit) return;
            if (hasProvider(progress.results, engine) != already_reviewed or !reviewer.available(engine)) continue;
            var timer = try std.time.Timer.start();
            const response = reviewer.routeReview(engine, null, workflow.synthesis_schema, prompt);
            progress.review_ms +|= timer.read() / std.time.ns_per_ms;
            const raw = response catch |err| {
                if (unavailable(err)) continue;
                outcome.failure = err;
                return;
            };
            const checked = workflow.verify(a, raw, progress.results, plan.prepared.snap.evidence, additional) catch |err| {
                outcome.failure = err;
                return;
            };
            outcome.review_results = checked.results;
            outcome.synthesis_summary = checked.summary;
            outcome.report = try report(a, plan, progress.*, appliedDecision(plan, progress.*));
            outcome.report.?.synthesis_provider = engine;
            return;
        }
    }
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
            if (plan.repo.routing_mode == .adaptive) progress.evidence_requests = result.evidence_requests;
            var decision = plan.screen.floor.merge(result.decision);
            if (decision.depth == .light and (plan.repo.reviewSize() > 1 or result.evidence_requests.len != 0 or !core.lightComplete(result.review, plan.prepared)))
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

const screen_requesting_caller =
    \\{"decision":{"depth":"regular","performance":false,"reliability":false,"security":false},"evidence_requests":[{"path":"caller.zig","start_line":10,"end_line":12}],"review":
++ clean_result ++ "}";

const singleton_finding =
    \\{"complete":true,"summary":"One defect.","findings":[{"severity":"P2","path":"work.zig","line":12,"body":"The pending item is lost before retry."}],"existing_open_findings":[],"non_blocking_threads":[]}
;

const verified_singleton =
    \\{"summary":"Retry can lose the pending item.","assessments":[{"claim":0,"disposition":"verified","reason":"The retry path removes the item prematurely.","source_quote":"return pending.pop()","same_root_as":null}]}
;

const MockReviewer = struct {
    calls: [5]core.Engine = undefined,
    prompts: [5][]const u8 = undefined,
    count: u32 = 0,
    unavailable_engine: ?core.Engine = null,
    screen_enabled: bool = true,
    screen_rate_limit: bool = false,
    screen_output: ?[]const u8 = null,
    singleton: bool = false,

    pub fn available(self: *MockReviewer, engine: core.Engine) bool {
        return self.unavailable_engine != engine;
    }

    pub fn starts(self: *MockReviewer) u32 {
        return self.count;
    }

    pub fn routeReview(self: *MockReviewer, engine: core.Engine, model: ?[]const u8, schema: []const u8, prompt: []const u8) ![]const u8 {
        self.calls[self.count] = engine;
        self.prompts[self.count] = prompt;
        self.count += 1;
        if (model != null) {
            try std.testing.expectEqualStrings(core.screen_schema, schema);
            if (self.screen_rate_limit and engine == .codex) return error.CodexRateLimited;
            return if (self.screen_enabled) self.screen_output orelse light_screen else "malformed";
        }
        try std.testing.expect(!std.mem.containsAtLeast(u8, prompt, 1, "Choose review fidelity"));
        if (std.mem.eql(u8, schema, workflow.synthesis_schema)) return verified_singleton;
        if (self.singleton and engine == .codex) return singleton_finding;
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

test "multi review checkpoints the synthesis start and prefers a distinct provider" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan = sample_plan;
    plan.providers = &.{ .codex, .claude, .kimi };
    plan.repo.fallback_engines = &.{ .claude, .kimi };
    plan.screen = .{ .floor = .{ .depth = .multi, .security = true, .reliability = true }, .ask_model = false };
    plan.prepared.snap.evidence = "return pending.pop();";
    plan.start_limit = 2;

    var first: MockReviewer = .{ .singleton = true };
    const pending = try run(a, &first, plan);
    try t.expect(pending.report == null and pending.failure == null);
    try t.expectEqual(@as(usize, 2), pending.progress.results.len);
    try t.expect(std.mem.indexOf(u8, first.prompts[0], "Primary lens: security") != null);
    try t.expect(std.mem.indexOf(u8, first.prompts[1], "Primary lens: reliability") != null);
    plan.progress = try io.parse(a, core.RouteProgress, try io.json(a, pending.progress));

    var resumed: MockReviewer = .{};
    const consolidated = try run(a, &resumed, plan);
    try t.expectEqualSlices(core.Engine, &.{.kimi}, resumed.calls[0..resumed.count]);
    try t.expectEqualSlices(core.Engine, &.{ .codex, .claude }, consolidated.report.?.providers);
    try t.expectEqual(@as(?core.Engine, .kimi), consolidated.report.?.synthesis_provider);
    try t.expectEqual(@as(usize, 1), consolidated.review_results.?[0].review.findings.len);
    try t.expectEqualStrings("Retry can lose the pending item.", consolidated.synthesis_summary.?);
}

test "requested evidence is checkpointed before the full review" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan = sample_plan;
    var first: MockReviewer = .{ .screen_output = screen_requesting_caller };
    const pending = try run(a, &first, plan);
    try t.expect(pending.report == null);
    try t.expectEqual(@as(u32, 1), first.count);
    plan.progress = try io.parse(a, core.RouteProgress, try io.json(a, pending.progress));
    try t.expectEqualStrings("caller.zig", plan.progress.evidence_requests[0].path);
    plan.evidence = "Pinned head file caller.zig, lines 10-12:\nretry(pending);";

    var resumed: MockReviewer = .{};
    const reviewed = try run(a, &resumed, plan);
    try t.expect(reviewed.report != null);
    try t.expect(!reviewed.evidence_limited);
    try t.expectEqual(@as(u32, 1), resumed.count);
    try t.expect(std.mem.indexOf(u8, resumed.prompts[0], "retry(pending);") != null);

    var shadow = sample_plan;
    shadow.repo.routing_mode = .shadow;
    var baseline: MockReviewer = .{ .screen_output = screen_requesting_caller };
    const preview = try run(a, &baseline, shadow);
    try t.expect(preview.report != null);
    try t.expectEqual(@as(usize, 0), preview.progress.evidence_requests.len);
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
