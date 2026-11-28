const std = @import("std");
const core = @import("core.zig");
const stack = @import("stack.zig");
const usage = @import("usage.zig");
const workflow = @import("review_workflow.zig");

pub const jobs_per_repo = 3;
pub const active_repos = 5;
pub const parallel_jobs = jobs_per_repo * active_repos;
pub const parallel_sections = 3;
pub const default_budget = parallel_jobs;

pub const RepoJobs = struct {
    index: usize,
    numbers: [jobs_per_repo]u32 = undefined,
    len: usize = 0,

    pub fn add(self: *RepoJobs, number: u32) void {
        self.numbers[self.len] = number;
        self.len += 1;
    }

    pub fn selected(self: *const RepoJobs) []const u32 {
        return self.numbers[0..self.len];
    }
};

pub const TickCounts = struct {
    at: i64 = 0,
    reviewer_starts: u32 = 0,
    github_commands: u32 = 0,
    jobs: u32 = 0,
    receipt_checks: u32 = 0,
};

const Cooldown = struct {
    until: i64 = 0,
    attempts: u8 = 0,

    fn backOff(self: *Cooldown, now: i64) void {
        // Concurrent calls can all hit the same rate limit.
        if (now < self.until) return;
        // A long gap without another rate limit starts a new retry window.
        if (now > self.until +| 960) self.attempts = 0;
        self.attempts = @min(self.attempts +| 1, 5);
        self.until = @max(self.until, now +| (@as(i64, 60) << @intCast(self.attempts - 1)));
    }
};

pub const Eligible = struct {
    number: u32,
    head: []const u8,
    at: i64,
    reviewer_starts: u32,
};

pub const Pick = struct {
    job: ?*core.Job = null,
    budget_deferred: bool = false,
};

pub const Budget = struct {
    limit: u32 = default_budget,
    next_repo: usize = 0,
    github: Cooldown = .{},
    codex: Cooldown = .{},
    claude: Cooldown = .{},
    kimi: Cooldown = .{},
    last_tick: TickCounts = .{},

    pub fn validate(self: Budget, entries: []const core.Entry) !void {
        if (self.limit == 0) return error.InvalidReviewBudget;
        for (entries) |entry| {
            if (self.limit < reviewerCost(entry.repo)) return error.ReviewBudgetTooSmall;
        }
    }

    pub fn noteFailure(self: *Budget, now: i64, err: anyerror) void {
        const domain = switch (err) {
            error.GitHubRateLimited => &self.github,
            error.CodexRateLimited => &self.codex,
            error.ClaudeRateLimited => &self.claude,
            error.KimiRateLimited => &self.kimi,
            else => return,
        };
        domain.backOff(now);
    }

    pub fn canScan(self: Budget, now: i64) bool {
        return self.github.until <= now;
    }

    pub fn providerRetry(self: Budget, engine: core.Engine) i64 {
        return switch (engine) {
            inline else => |selected| @field(self, @tagName(selected)).until,
        };
    }

    pub fn canReview(self: Budget, repo: core.Repo, progress: ?core.RouteProgress, now: i64, limited: u8, current: usage.Snapshot) bool {
        return (self.reviewAt(repo, progress, now, limited, current) orelse return false) <= now;
    }

    fn reviewAt(self: Budget, repo: core.Repo, progress: ?core.RouteProgress, now: i64, limited: u8, current: usage.Snapshot) ?i64 {
        if (progress) |partial| if (partial.readyToPublish()) return 0;
        if (progress) |partial| {
            if (partial.sections.pending.len != 0) {
                var earliest: ?i64 = null;
                for (partial.sections.pending) |task| {
                    if (self.reviewAt(repo, task.progress, now, limited, current)) |at| {
                        earliest = @min(earliest orelse at, at);
                    }
                }
                const count = partial.sections.checkpoint.?.section_count;
                if (partial.sections.pending.len < parallel_sections and partial.sections.index + partial.sections.pending.len < count) {
                    if (self.reviewAt(repo, null, now, limited, current)) |at| return @min(earliest orelse at, at);
                }
                return earliest;
            }
        }
        const can_make_progress = repo.routing_mode != .fixed or repo.fallback_engines.len != 0 or progress != null;
        const synthesizing = if (progress) |partial| workflow.waitsForSynthesis(repo, partial) else false;
        const completed = if (synthesizing) &.{} else if (progress) |partial| partial.results else &.{};
        // The original review can finish even when an optional completion
        // provider has no remaining quota.
        if (progress) |partial| {
            for (partial.results) |pass| if (partial.needsCompletion(pass)) return 0;
        }
        var result: ?i64 = if (can_make_progress) null else 0;
        providers: for (std.meta.tags(core.Engine)) |engine| {
            const primary = engine == repo.engine or std.mem.indexOfScalar(core.Engine, repo.additional_engines, engine) != null;
            if (!primary and std.mem.indexOfScalar(core.Engine, repo.fallback_engines, engine) == null) continue;
            if (progress) |partial| {
                const excluded = if (synthesizing) partial.rejected_synthesizers else partial.malformed_reviewers;
                if (excluded & engineBit(engine) != 0) continue;
            }
            for (completed) |pass| {
                if (pass.engine == engine) continue :providers;
            }
            const at = self.engineAt(engine, now, limited, current);
            if (can_make_progress) {
                if (at) |available| result = @min(result orelse available, available);
            } else {
                result = @max(result.?, at orelse return null);
            }
        }
        return result;
    }

    pub fn engineAt(self: Budget, engine: core.Engine, now: i64, limited: u8, current: usage.Snapshot) ?i64 {
        if (engineBit(engine) & limited != 0) return null;
        const quota_at = current.availableAt(engine, now);
        return @max(if (quota_at > now) quota_at else 0, self.providerRetry(engine));
    }

    pub fn eligibleAt(self: Budget, entry: core.Entry, job: core.Job, now: i64, limited: u8, current: usage.Snapshot) ?i64 {
        if (!job.schedulable() or entry.isIgnored(job.number) or stack.analysisBlocked(entry, job)) return null;
        var at = @max(job.next, self.github.until);
        if (job.phase != .uncertain and job.analysis == null) {
            if (job.route_progress) |progress| {
                if (progress.needsAnotherProvider(entry.repo)) return null;
            }
            at = @max(at, self.reviewAt(entry.repo, job.route_progress, now, limited, current) orelse return null);
        }
        return at;
    }

    pub fn nextEligible(self: Budget, entry: core.Entry, now: i64, current: usage.Snapshot) ?Eligible {
        var next: ?Eligible = null;
        for (entry.jobs) |job| {
            const at = self.eligibleAt(entry, job, now, 0, current) orelse continue;
            if (next == null or at < next.?.at) {
                next = .{ .number = job.number, .head = job.head, .at = at, .reviewer_starts = jobCost(entry.repo, job) };
            }
        }
        if (next) |*candidate| candidate.at = @max(now, candidate.at);
        return next;
    }

    pub fn pick(self: Budget, entry: *core.Entry, now: i64, remaining: u32, receipts: u32, selected: []const u32, limited: u8, current: usage.Snapshot, allow_fresh_routed: bool) Pick {
        var result: Pick = .{};
        for (entry.jobs) |*job| {
            const at = self.eligibleAt(entry.*, job.*, now, limited, current) orelse continue;
            if (at > now or std.mem.indexOfScalar(u32, selected, job.number) != null) continue;
            if (!allow_fresh_routed and entry.repo.usesRouting() and
                job.phase == .pending and job.route_progress == null and job.analysis == null)
            {
                result.budget_deferred = true;
                continue;
            }
            if (jobCost(entry.repo, job.*) > remaining or (job.phase == .uncertain and receipts == 0)) {
                result.budget_deferred = true;
                continue;
            }
            // Keep the existing queue order for jobs with the same deadline.
            if (result.job == null or job.next < result.job.?.next) result.job = job;
        }
        return result;
    }
};

pub fn engineBit(engine: core.Engine) u8 {
    return core.providerBit(engine);
}

pub fn reviewerCost(repo: core.Repo) u32 {
    const full = if (repo.routing_mode == .adaptive) @max(2, repo.reviewSize()) else repo.reviewSize();
    const screen_count = if (repo.routing_mode == .fixed) 0 else repo.light_models.len;
    return @intCast(full + screen_count);
}

fn jobCost(repo: core.Repo, job: core.Job) u32 {
    // Receipt reconciliation uses GitHub only, even after a restart.
    return if (job.phase == .uncertain) 0 else reviewerCost(repo);
}

test "queue selection accounts for reviewer count and leaves receipt lookup eligible" {
    const t = std.testing;
    var jobs = [_]core.Job{
        .{ .number = 1, .head = "new" },
        .{ .number = 2, .head = "old", .phase = .uncertain },
        .{ .number = 3, .head = "waiting", .next = 200 },
    };
    var entry: core.Entry = .{ .repo = .{ .name = "owner/repo", .login = "user", .additional_engines = &.{ .claude, .kimi } }, .jobs = &jobs };
    const budget: Budget = .{};
    try t.expectError(error.ReviewBudgetTooSmall, (Budget{ .limit = 2 }).validate(&.{entry}));
    const limited = engineBit(.claude);
    const cooled = budget.pick(&entry, 100, budget.limit, budget.limit, &.{}, limited, .{}, true);
    try t.expect(!cooled.budget_deferred);
    try t.expectEqual(@as(u32, 2), cooled.job.?.number);
    const receipt = budget.pick(&entry, 100, 0, budget.limit, &.{}, 0, .{}, true);
    try t.expect(receipt.budget_deferred);
    try t.expectEqual(@as(u32, 2), receipt.job.?.number);
    try t.expect(budget.pick(&entry, 100, 0, 0, &.{}, 0, .{}, true).job == null);
    const next = budget.pick(&entry, 100, budget.limit, budget.limit, &.{}, 0, .{}, true);
    try t.expect(!next.budget_deferred);
    try t.expectEqual(@as(u32, 1), next.job.?.number);
    try t.expectEqual(@as(u32, 3), budget.nextEligible(entry, 100, .{}).?.reviewer_starts);
}

test "a batch excludes multiple heads of the same PR" {
    var jobs = [_]core.Job{
        .{ .number = 1, .head = "old", .phase = .uncertain },
        .{ .number = 1, .head = "new" },
        .{ .number = 2, .head = "other" },
    };
    var entry: core.Entry = .{ .repo = .{ .name = "owner/repo", .login = "user" }, .jobs = &jobs };
    var lane: RepoJobs = .{ .index = 0 };
    const budget: Budget = .{};
    const first = budget.pick(&entry, 100, 3, 3, lane.selected(), 0, .{}, true).job.?;
    try std.testing.expectEqualStrings("old", first.head);
    lane.add(first.number);
    const next = budget.pick(&entry, 100, 3, 3, lane.selected(), 0, .{}, true).job.?;
    try std.testing.expectEqual(@as(u32, 2), next.number);
}

test "checkpoint saturation leaves saved passes and receipts selectable" {
    const t = std.testing;
    var jobs = [_]core.Job{
        .{ .number = 1, .head = "fresh" },
        .{ .number = 2, .head = "saved", .route_progress = .{ .fingerprint = @splat(0) } },
        .{ .number = 3, .head = "receipt", .phase = .uncertain },
    };
    var entry: core.Entry = .{
        .repo = .{ .name = "owner/repo", .login = "user", .routing_mode = .adaptive },
        .jobs = &jobs,
    };
    const budget: Budget = .{};
    try t.expectEqual(@as(u32, 1), budget.pick(&entry, 100, 2, 2, &.{}, 0, .{}, true).job.?.number);
    const saturated = budget.pick(&entry, 100, 2, 2, &.{}, 0, .{}, false);
    try t.expect(saturated.budget_deferred);
    try t.expectEqual(@as(u32, 2), saturated.job.?.number);
    try t.expectEqual(@as(u32, 3), budget.pick(&entry, 100, 2, 2, &.{2}, 0, .{}, false).job.?.number);
}

test "a retargeted head can leave a route waiting for more providers" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pull: core.Pull = .{
        .number = 1,
        .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .baseRefOid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .baseRefName = "main",
        .isDraft = false,
    };
    var entry: core.Entry = .{ .repo = .{ .name = "owner/repo", .login = "user", .routing_mode = .adaptive } };
    try entry.queue(a, pull, null);
    const budget: Budget = .{};
    for ([_]core.ReviewBase{
        .{ .oid = pull.baseRefOid, .ref = "release" },
        .{ .oid = "cccccccccccccccccccccccccccccccccccccccc", .ref = "release" },
    }) |retargeted| {
        entry.jobs[0].route_progress = .{
            .base = .fromPull(pull),
            .fingerprint = @splat(0),
            .decision = .{ .depth = .multi, .security = true },
        };
        try entry.discover(a, &.{pull}, false);
        try t.expect(budget.nextEligible(entry, 100, .{}) == null);
        pull.baseRefOid = retargeted.oid;
        pull.baseRefName = retargeted.ref;
        try entry.discover(a, &.{pull}, false);
        try t.expectEqual(@as(usize, 1), entry.jobs.len);
        try t.expectEqual(@as(u32, 1), budget.nextEligible(entry, 100, .{}).?.number);
    }
}

test "transport cooldowns block only affected starts and stay bounded" {
    const t = std.testing;
    var budget: Budget = .{};
    budget.noteFailure(100, error.ClaudeRateLimited);
    budget.noteFailure(101, error.ClaudeRateLimited);
    try t.expectEqual(@as(i64, 160), budget.claude.until);
    try t.expectEqual(@as(i64, 0), budget.codex.until);
    try t.expect(budget.canScan(100));
    var jobs = [_]core.Job{
        .{ .number = 1, .head = "next", .attempts = 1, .next = 130 },
    };
    var entry: core.Entry = .{ .repo = .{ .name = "owner/repo", .login = "user", .additional_engines = &.{.claude} }, .jobs = &jobs };
    try t.expect(budget.pick(&entry, 130, 2, 2, &.{}, 0, .{}, true).job == null);
    try t.expectEqual(@as(i64, 160), budget.nextEligible(entry, 130, .{}).?.at);
    try t.expect(budget.pick(&entry, 160, 2, 2, &.{}, 0, .{}, true).job != null);
    entry.jobs[0].phase = .uncertain;
    try t.expect(budget.pick(&entry, 130, 0, 2, &.{}, 0, .{}, true).job != null);
    budget.noteFailure(130, error.GitHubRateLimited);
    try t.expect(!budget.canScan(131));
    try t.expect(budget.pick(&entry, 131, 0, 2, &.{}, 0, .{}, true).job == null);
    for (0..15) |_| budget.noteFailure(budget.github.until, error.GitHubRateLimited);
    try t.expectEqual(@as(u8, 5), budget.github.attempts);
}

test "large discovery bursts keep ordering and deduplicate exact heads" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const changed = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var seen = [_]core.Seen{.{ .number = 2, .head = old }};
    var jobs = [_]core.Job{
        .{ .number = 2, .head = old, .phase = .uncertain, .receipt = 55 },
        .{ .number = 3, .head = old, .phase = .complete },
        .{ .number = 1, .head = old, .phase = .complete },
    };
    var entry: core.Entry = .{ .repo = .{ .name = "owner/repo", .login = "user" }, .seen = &seen, .jobs = &jobs };
    const pulls = try a.alloc(core.Pull, 2001);
    for (pulls[0..2000], 0..) |*pull, index| {
        pull.* = .{ .number = @intCast(index + 2), .headRefOid = old, .isDraft = false };
    }
    pulls[0].headRefOid = changed;
    pulls[2000] = pulls[0];
    try entry.discover(a, pulls, false);
    try t.expectEqual(@as(usize, 2001), entry.seen.len);
    try t.expectEqual(@as(usize, 2001), entry.jobs.len);
    try t.expectEqual(@as(?u64, 55), entry.jobs[0].receipt);
    try t.expectEqual(@as(u32, 3), entry.jobs[1].number);
    try t.expectEqual(@as(u32, 2), entry.jobs[2].number);
    try t.expectEqualStrings(changed, entry.jobs[2].head);
    try t.expectEqual(@as(u32, 2001), entry.jobs[2000].number);
    try entry.discover(a, pulls, false);
    try t.expectEqual(@as(usize, 2001), entry.jobs.len);
}

test "a fixed ensemble can resume when its completed provider is at the daily cap" {
    const t = std.testing;
    const now = 10 * std.time.s_per_day;
    const repo: core.Repo = .{ .name = "owner/repo", .login = "user", .additional_engines = &.{.claude} };
    const current: usage.Snapshot = .{ .day = 10, .codex = .{ .limit = 1, .starts = 1 } };
    const budget: Budget = .{};
    try t.expect(!budget.canReview(repo, null, now, 0, current));
    const progress: core.RouteProgress = .{
        .fingerprint = @splat(0),
        .results = &.{.{ .engine = .codex, .review = .{ .complete = true, .summary = "Fixture", .findings = &.{}, .existing_open_findings = &.{} } }},
    };
    try t.expect(budget.canReview(repo, progress, now, 0, current));
    try t.expect(!budget.canReview(repo, progress, now, engineBit(.claude), current));
}

test "a completed adaptive ensemble can reuse a provider for synthesis" {
    const t = std.testing;
    const now = 10 * std.time.s_per_day;
    const repo: core.Repo = .{ .name = "owner/repo", .login = "user", .routing_mode = .adaptive, .fallback_engines = &.{.claude} };
    const review: core.Review = .{
        .complete = true,
        .summary = "Fixture",
        .findings = &.{.{ .severity = .P2, .path = "retry.zig", .line = 5, .body = "Drops queued work on retry." }},
        .existing_open_findings = &.{},
    };
    const progress: core.RouteProgress = .{
        .fingerprint = @splat(0),
        .decision = .{ .depth = .multi, .reliability = true },
        .screen_waiting = false,
        .results = &.{ .{ .engine = .codex, .review = review }, .{ .engine = .claude, .review = review } },
    };
    const budget: Budget = .{};
    try t.expect(budget.canReview(repo, progress, now, engineBit(.codex), .{}));
    try t.expect(!budget.canReview(repo, progress, now, engineBit(.codex) | engineBit(.claude), .{}));
}
