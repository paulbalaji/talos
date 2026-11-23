const std = @import("std");
const core = @import("core.zig");

pub const jobs_per_repo = 3;
pub const active_repos = 5;
pub const parallel_jobs = jobs_per_repo * active_repos;
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

    fn providerRetry(self: Budget, engine: core.Engine) i64 {
        return switch (engine) {
            inline else => |selected| @field(self, @tagName(selected)).until,
        };
    }

    pub fn canReview(self: Budget, repo: core.Repo, now: i64, limited: u8) bool {
        if (usesLimitedEngine(repo, limited) or self.providerRetry(repo.engine) > now) return false;
        for (repo.additional_engines) |engine| if (self.providerRetry(engine) > now) return false;
        return true;
    }

    fn eligibleAt(self: Budget, entry: core.Entry, job: core.Job) ?i64 {
        if (!job.schedulable() or entry.stackBlocked(job)) return null;
        var at = @max(job.next, self.github.until);
        if (job.phase != .uncertain and job.analysis == null) {
            at = @max(at, self.providerRetry(entry.repo.engine));
            for (entry.repo.additional_engines) |engine| at = @max(at, self.providerRetry(engine));
        }
        return at;
    }

    pub fn nextEligible(self: Budget, entry: core.Entry, now: i64) ?Eligible {
        var next: ?Eligible = null;
        for (entry.jobs) |job| {
            const at = self.eligibleAt(entry, job) orelse continue;
            if (next == null or at < next.?.at) {
                next = .{ .number = job.number, .head = job.head, .at = at, .reviewer_starts = jobCost(entry.repo, job) };
            }
        }
        if (next) |*candidate| candidate.at = @max(now, candidate.at);
        return next;
    }

    pub fn pick(self: Budget, entry: *core.Entry, now: i64, remaining: u32, receipts: u32, selected: []const u32, limited: u8) Pick {
        var result: Pick = .{};
        const provider_limited = usesLimitedEngine(entry.repo, limited);
        for (entry.jobs) |*job| {
            const at = self.eligibleAt(entry.*, job.*) orelse continue;
            if (provider_limited and job.phase != .uncertain and job.analysis == null) continue;
            if (at > now or std.mem.indexOfScalar(u32, selected, job.number) != null) continue;
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
    return @as(u8, 1) << @intCast(@intFromEnum(engine));
}

fn usesLimitedEngine(repo: core.Repo, limited: u8) bool {
    if (engineBit(repo.engine) & limited != 0) return true;
    for (repo.additional_engines) |engine| if (engineBit(engine) & limited != 0) return true;
    return false;
}

pub fn reviewerCost(repo: core.Repo) u32 {
    return @intCast(1 + repo.additional_engines.len);
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
    const cooled = budget.pick(&entry, 100, budget.limit, budget.limit, &.{}, limited);
    try t.expect(!cooled.budget_deferred);
    try t.expectEqual(@as(u32, 2), cooled.job.?.number);
    const receipt = budget.pick(&entry, 100, 0, budget.limit, &.{}, 0);
    try t.expect(receipt.budget_deferred);
    try t.expectEqual(@as(u32, 2), receipt.job.?.number);
    try t.expect(budget.pick(&entry, 100, 0, 0, &.{}, 0).job == null);
    const next = budget.pick(&entry, 100, budget.limit, budget.limit, &.{}, 0);
    try t.expect(!next.budget_deferred);
    try t.expectEqual(@as(u32, 1), next.job.?.number);
    try t.expectEqual(@as(u32, 3), budget.nextEligible(entry, 100).?.reviewer_starts);
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
    const first = budget.pick(&entry, 100, 3, 3, lane.selected(), 0).job.?;
    try std.testing.expectEqualStrings("old", first.head);
    lane.add(first.number);
    const next = budget.pick(&entry, 100, 3, 3, lane.selected(), 0).job.?;
    try std.testing.expectEqual(@as(u32, 2), next.number);
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
    try t.expect(budget.pick(&entry, 130, 2, 2, &.{}, 0).job == null);
    try t.expectEqual(@as(i64, 160), budget.nextEligible(entry, 130).?.at);
    try t.expect(budget.pick(&entry, 160, 2, 2, &.{}, 0).job != null);
    entry.jobs[0].phase = .uncertain;
    try t.expect(budget.pick(&entry, 130, 0, 2, &.{}, 0).job != null);
    budget.noteFailure(130, error.GitHubRateLimited);
    try t.expect(!budget.canScan(131));
    try t.expect(budget.pick(&entry, 131, 0, 2, &.{}, 0).job == null);
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
