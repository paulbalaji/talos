const std = @import("std");
const core = @import("core.zig");
const cache = @import("cache.zig");
const github = @import("github.zig");
const source = @import("source.zig");
const stack = @import("stack.zig");
const runner = @import("runner.zig");
const store = @import("store.zig");
const launchd = @import("launchd.zig");
const log_retention = @import("log_retention.zig");
const io = @import("io.zig");
const repo_config = @import("repo_config.zig");
const queue = @import("queue.zig");
const routing = @import("routing.zig");
const adaptive = @import("adaptive.zig");
const usage_meter = @import("usage.zig");
const followup = @import("followup.zig");
const followup_git = @import("followup_git.zig");

const eq = io.eq;
const A = io.A;
const usage =
    \\Talos tracks ready GitHub pull requests and reviews new commits.
    \\
    \\talos [--home DIR] add OWNER/REPO [options]
    \\talos [--home DIR] defaults [--engine ENGINE[,ENGINE...]]
    \\talos [--home DIR] status [OWNER/REPO] [--json]
    \\talos [--home DIR] result OWNER/REPO PR
    \\talos [--home DIR] queue-budget [STARTS]
    \\talos [--home DIR] usage [ENGINE DAILY_STARTS]
    \\talos [--home DIR] queue OWNER/REPO PR [--mode MODE] [--prompt TEXT [--publish]]
    \\talos [--home DIR] followup THREAD_URL [--dry-run | --merge-when-ready]
    \\talos [--home DIR] followup status [--json]
    \\talos [--home DIR] followup pause|resume THREAD_URL
    \\talos [--home DIR] stack OWNER/REPO STACK_NUMBER
    \\talos [--home DIR] stack OWNER/REPO NAME PR PR [PR ...]
    \\talos [--home DIR] unstack OWNER/REPO NAME
    \\talos [--home DIR] run-once [OWNER/REPO [PR [--mode MODE] [--prompt TEXT]]]
    \\talos [--home DIR] pause|resume OWNER/REPO
    \\talos [--home DIR] install|remove [--label dev.talos.NAME]
    \\talos [--home DIR] tick
    \\
    \\Review modes for queue and numbered previews
    \\  general (default), perf-maxxing, reliability-maxxing, security-maxxing, simplicity
    \\
    \\Registration options
    \\  --interval SECONDS                  Default 180, minimum 15
    \\  --cache-mib MIB                      Default 128, 0 for per-review disposal
    \\  --cache-idle-days DAYS               Default 7
    \\  --engine ENGINE[,ENGINE...]         codex, claude, or kimi
    \\  --model MODEL                        Override the first reviewer's model
    \\  --reviewer-model ENGINE=MODEL        Override a specific reviewer's model, repeatable
    \\  --reviewer-effort ENGINE=LEVEL       Override high effort, or use default for CLI settings
    \\  --claude-advisor fable|off           Default fable
    \\  --routing fixed|shadow|adaptive     Default fixed
    \\  --fallback ENGINE[,ENGINE...]|off   Ordered, authorized replacement providers
    \\  --light-model ENGINE=MODEL|off      Lightweight screening model, repeatable
    \\  --git PATH --gh PATH --codex PATH --claude PATH --kimi PATH
    \\  --comments                           Publish comment reviews
    \\  --approvals                          Publish clean approvals
    \\
;

fn pick(a: A, env: *const std.process.EnvMap, names: []const []const u8) !std.process.EnvMap {
    var result = std.process.EnvMap.init(a);
    for (names) |name| {
        if (env.get(name)) |value| try result.put(name, value);
    }
    return result;
}

const common_env = [_][]const u8{ "HOME", "PATH", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR" };

const Tool = repo_config.Tool;
const Programs = repo_config.Programs;
const Local = struct {
    a: A,
    env: *const std.process.EnvMap,
    scratch: [:0]const u8,
    scratch_dir: std.fs.Dir,
    programs: Programs,
    counts: ?*queue.TickCounts = null,
    meter: ?*usage_meter.Ledger = null,

    fn command(self: Local, env: *const std.process.EnvMap) io.Command {
        return .{ .a = self.a, .env = env, .cwd = self.scratch, .dir = self.scratch_dir };
    }

    fn bin(self: Local, tool: Tool) ![]const u8 {
        const name = switch (tool) {
            inline else => |t| @field(self.programs, @tagName(t)),
        };
        return io.executable(self.a, self.env.get("PATH") orelse "/usr/bin:/bin", name);
    }

    fn githubEnv(self: Local) !std.process.EnvMap {
        var env = try pick(self.a, self.env, &(common_env ++ .{ "GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "HTTPS_PROXY", "NO_PROXY", "SSL_CERT_FILE" }));
        try env.put("GH_PROMPT_DISABLED", "1");
        try env.put("GH_NO_UPDATE_NOTIFIER", "1");
        return env;
    }

    fn gh(self: Local, env: *const std.process.EnvMap, name: []const u8) !github.Client {
        return .{
            .cmd = self.command(env),
            .gh = try self.bin(.gh),
            .repo = name,
            .calls = if (self.counts) |counts| &counts.github_commands else null,
        };
    }

    fn git(self: Local, env: *std.process.EnvMap, db: store.Store, repo: core.Repo) !source.Git {
        try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try env.put("GIT_CONFIG_SYSTEM", "/dev/null");
        try env.put("GIT_TERMINAL_PROMPT", "0");
        return .{
            .cmd = self.command(env),
            .bin = try self.bin(.git),
            .gh = try self.bin(.gh),
            .object_cache = .{ .a = self.a, .root = db.dir, .repo = repo },
        };
    }

    fn reviewerEnv(self: Local, engine: core.Engine, bin_path: []const u8, profile: runner.Profile) !std.process.EnvMap {
        var env = try pick(self.a, self.env, &common_env);
        try runner.configureEnvironment(engine, profile, self.env, &env);
        try env.put("PATH", try io.fmt(self.a, "{s}:{s}", .{
            std.fs.path.dirname(bin_path) orelse "/usr/bin", env.get("PATH") orelse "/usr/bin:/bin",
        }));
        return env;
    }
};

const Adapter = struct {
    db: store.Store,
    state: *const store.State,
    repo: core.Repo,
    entry: *core.Entry,
    github_client: github.Client,
    git_source: source.Git,
    tools: Local,
    files: []const github.File = &.{},

    pub fn checkIdentity(self: *Adapter) !void {
        if (try self.db.paused(self.repo.name)) return error.RepoPaused;
        if (!std.ascii.eqlIgnoreCase(try self.github_client.identity(), self.repo.login)) return error.GitHubIdentityChanged;
    }

    pub fn pull(self: *Adapter, number: u32) !core.Pull {
        return self.github_client.pull(number);
    }

    pub fn reviews(self: *Adapter, number: u32) ![]const core.Prior {
        return self.github_client.reviews(number);
    }

    pub fn reviewDiscussion(self: *Adapter, number: u32) !core.Discussion {
        return self.github_client.discussion(number);
    }

    pub fn snapshot(self: *Adapter, pr: core.Pull) !core.Snapshot {
        self.files = try self.github_client.files(pr.number);
        return self.git_source.snapshot(pr, self.files);
    }

    pub fn supplement(self: *Adapter, pr: core.Pull, previous: ?[]const u8, requests: []const core.EvidenceRequest) !source.Supplement {
        return self.git_source.supplement(pr, previous, requests);
    }

    pub fn stackContext(self: *Adapter, pr: core.Pull, preview: bool) !stack.Context {
        const position = stack.find(self.entry.stacks, pr.number) orelse return .{};
        const item = self.entry.stacks[position.stack_index];
        const prefix = item.members[0 .. position.member_index + 1];
        const pins = if (item.native) |identity|
            (try self.github_client.nativeStack(identity, prefix.len)).pins
        else local: {
            if (prefix.len > stack.max_members) return error.InvalidStackSize;
            var numbers: [stack.max_members]u32 = undefined;
            for (prefix, numbers[0..prefix.len]) |member, *number| number.* = member.pin.number;
            break :local try self.github_client.stackPulls(numbers[0..prefix.len]);
        };
        const target = pins[pins.len - 1];
        if (target.number != pr.number or !target.ready() or !eq(u8, target.headRefOid, pr.headRefOid) or !eq(u8, target.baseRefOid, pr.baseRefOid))
            return error.StackChanged;
        const parent_count = pins.len - 1;
        const detail_start = parent_count -| stack.context_members;
        const ancestors = try self.db.a.alloc(stack.Ancestor, parent_count - detail_start);
        for (prefix, pins, 0..) |member, pin, index| {
            if (member.pin.number != pin.number or (item.native == null and pin.nativeStack != null)) return error.StackChanged;
            if (!preview and !stack.samePin(member.pin, pin)) return error.StackChanged;
            if (pin.state != .MERGED and !pin.ready()) return error.StackChanged;
            if (item.native == null and index > 0 and pin.state != .MERGED and pins[index - 1].state != .MERGED and
                !stack.linked(self.repo.name, pins[index - 1], pin)) return error.StackChanged;
        }
        for (prefix[detail_start..parent_count], pins[detail_start..parent_count], ancestors) |member, pin, *ancestor| {
            const merged_pin = pin.state == .MERGED and eq(u8, pin.headRefOid, member.pin.headRefOid);
            const base = if (merged_pin) member.diff_base else pin.baseRefOid;
            var ancestor_pr = pin.pull();
            ancestor_pr.baseRefOid = base;
            const digest = digest: {
                if (merged_pin or stack.samePin(member.pin, pin)) {
                    if (member.digest) |stored| break :digest stored;
                }
                const snapshot_value = try self.git_source.snapshot(ancestor_pr, &.{});
                break :digest try stack.Digest.make(self.db.a, snapshot_value.evidence, try self.ancestorReview(pin));
            };
            ancestor.* = .{
                .number = pin.number,
                .head = pin.headRefOid,
                .base = base,
                .state = @tagName(pin.state),
                .diff_excerpt = digest.diff,
                .review_excerpt = digest.findings,
            };
        }
        return .{ .pins = pins, .ancestors = ancestors, .native = item.native };
    }

    fn ancestorReview(self: *Adapter, pin: stack.Pin) !?core.Payload {
        const reviews_value = try self.github_client.reviews(pin.number);
        var newest: ?core.Prior = null;
        for (reviews_value) |prior| {
            const user = prior.user orelse continue;
            if (!std.ascii.eqlIgnoreCase(user.login, self.repo.login) or !eq(u8, prior.commit_id, pin.headRefOid) or
                eq(u8, prior.state, "PENDING") or (newest != null and newest.?.id >= prior.id)) continue;
            newest = prior;
        }
        const prior = newest orelse return null;
        return .{ .commit_id = prior.commit_id, .event = .COMMENT, .body = prior.body orelse "", .comments = &.{} };
    }

    pub fn checkStack(self: *Adapter, context: stack.Context) !void {
        if (context.pins.len == 0) return;
        const latest = if (context.native) |identity|
            (try self.github_client.nativeStack(identity, context.pins.len)).pins
        else local: {
            var numbers: [stack.max_members]u32 = undefined;
            for (context.pins, numbers[0..context.pins.len]) |pin, *number| number.* = pin.number;
            break :local try self.github_client.stackPulls(numbers[0..context.pins.len]);
        };
        for (context.pins, latest) |before, after| {
            if (!stack.samePin(before, after)) return error.StackChanged;
        }
    }

    pub fn checkStackBeforePost(self: *Adapter, context: stack.Context, target: core.Pull) !void {
        if (context.pins.len != 0) return self.checkStack(context);
        // A normal PR can join a native stack after the most recent scan.
        // Refuse to publish a standalone review for it before persisting intent.
        const pins = try self.github_client.stackPulls(&.{target.number});
        const pin = pins[0];
        if (pin.nativeStack != null or !pin.ready() or !eq(u8, pin.headRefOid, target.headRefOid) or
            !eq(u8, pin.baseRefOid, target.baseRefOid)) return error.StackChanged;
    }

    pub fn saveStackContext(self: *Adapter, pr: core.Pull, snap: core.Snapshot, payload: core.Payload) !void {
        const position = stack.find(self.entry.stacks, pr.number) orelse return;
        const member = &self.entry.stacks[position.stack_index].members[position.member_index];
        member.digest = try stack.Digest.make(self.db.a, snap.evidence, payload);
    }

    pub fn anchor(self: *Adapter, _: core.Pull, _: core.Snapshot, path: []const u8, line: u32) !bool {
        return source.anchor(self.files, path, line);
    }

    pub fn review(self: *Adapter, engine: core.Engine, prompt: []const u8) ![]const u8 {
        return runReviewer(self.tools, self.repo, engine, prompt);
    }

    pub fn post(self: *Adapter, number: u32, payload: core.Payload) !u64 {
        return self.github_client.post(number, payload);
    }

    pub fn readReview(self: *Adapter, number: u32, id: u64) !core.Prior {
        return self.github_client.readReview(number, id);
    }

    pub fn verifyReviewComments(self: *Adapter, number: u32, id: u64, head: []const u8, anchors: []const core.Inline) !void {
        try self.github_client.verifyReviewComments(number, id, head, anchors);
    }

    pub fn persist(self: *Adapter) !void {
        try self.db.save(self.state);
    }

    pub fn saveResult(self: *Adapter, number: u32, payload: core.Payload) !void {
        try self.db.result(self.repo.name, number, payload);
    }
};

fn runReviewer(tools: Local, repo: core.Repo, engine: core.Engine, prompt: []const u8) ![]const u8 {
    return invokeReviewer(tools, engine, reviewerProfile(repo, engine), core.schema, prompt);
}

fn invokeReviewer(tools: Local, engine: core.Engine, profile: runner.Profile, schema: []const u8, prompt: []const u8) ![]const u8 {
    const bin = try tools.bin(reviewerTool(engine));
    const env = try tools.reviewerEnv(engine, bin, profile);
    const reviewer: runner.Runner = .{
        .cmd = tools.command(&env),
        .bin = bin,
        .engine = engine,
        .profile = profile,
        .schema = schema,
        .meter = tools.meter,
        .starts = if (tools.counts) |counts| &counts.reviewer_starts else null,
    };
    return reviewer.review(prompt);
}

const ReviewBatch = struct {
    starts_left: u32,
    receipts_left: u32,
    meter: ?*usage_meter.Ledger = null,
    deferred_repo: ?usize = null,
    workers: [queue.parallel_jobs]*ReviewWorker = undefined,
    len: usize = 0,
    pending: usize = 0,
    completed: std.Thread.Semaphore = .{},
    limited: std.atomic.Value(u8) = .init(0),

    fn usageSnapshot(self: *const ReviewBatch) usage_meter.Snapshot {
        return if (self.meter) |meter| meter.snapshot() else .{};
    }

    fn deinit(self: *ReviewBatch) void {
        for (self.workers[0..self.len]) |work| {
            if (work.thread) |thread| thread.join();
            work.arena.deinit();
        }
    }

    fn deferRepo(self: *ReviewBatch, index: usize) void {
        if (self.deferred_repo == null) self.deferred_repo = index;
    }
};

const ReviewWorker = struct {
    // Only the coordinator uses adapter, gh_env and job. The worker borrows
    // immutable context and uses its own arena, processes and scratch directory.
    adapter: Adapter = undefined,
    gh_env: std.process.EnvMap = undefined,
    job: *core.Job,
    prepared: core.Prepared = undefined,
    batch: *ReviewBatch,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    counts: queue.TickCounts = .{},
    tools: Local = undefined,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!core.ReviewResults = undefined,
    plan: ?adaptive.Plan = null,
    route_outcome: ?adaptive.Outcome = null,
    policy: queue.Budget = .{},
    rate_limits: u8 = 0,

    pub fn available(self: *ReviewWorker, engine: core.Engine) bool {
        const now = std.time.timestamp();
        const at = self.policy.engineAt(engine, now, self.batch.limited.load(.monotonic), self.batch.usageSnapshot()) orelse return false;
        return at <= now;
    }

    pub fn starts(self: *const ReviewWorker) u32 {
        return self.counts.reviewer_starts;
    }

    pub fn routeReview(self: *ReviewWorker, engine: core.Engine, model: ?[]const u8, schema: []const u8, prompt: []const u8) ![]const u8 {
        const profile = if (model) |light|
            runner.Profile{ .model = light, .effort = .default }
        else
            reviewerProfile(self.adapter.repo, engine);
        return invokeReviewer(self.tools, engine, profile, schema, prompt) catch |err| {
            self.noteRateLimit(engine, err);
            return err;
        };
    }

    fn noteRateLimit(self: *ReviewWorker, engine: core.Engine, err: anyerror) void {
        switch (err) {
            error.CodexRateLimited, error.ClaudeRateLimited, error.KimiRateLimited => {
                const bit = queue.engineBit(engine);
                self.rate_limits |= bit;
                _ = self.batch.limited.fetchOr(bit, .monotonic);
            },
            else => {},
        }
    }

    fn remainingLimited(engines: []const core.Engine, current: core.Engine, limited: u8) bool {
        const offset = std.mem.indexOfScalar(core.Engine, engines, current).?;
        for (engines[offset..]) |engine| {
            if (limited & queue.engineBit(engine) != 0) return true;
        }
        return false;
    }

    pub fn review(self: *ReviewWorker, engine: core.Engine, prompt: []const u8) ![]const u8 {
        if (remainingLimited(self.prepared.engines, engine, self.batch.limited.load(.monotonic)))
            return error.ReviewerCoolingDown;
        return runReviewer(self.tools, self.adapter.repo, engine, prompt) catch |err| {
            self.noteRateLimit(engine, err);
            return err;
        };
    }

    fn analyze(self: *ReviewWorker) void {
        self.result = self.analyzeInScratch();
        self.done.store(true, .release);
        self.batch.completed.post();
    }

    fn analyzeInScratch(self: *ReviewWorker) !core.ReviewResults {
        const a = self.arena.allocator();
        const scratch = try io.temp(a);
        defer std.fs.deleteTreeAbsolute(scratch) catch {};
        var dir = try std.fs.openDirAbsolute(scratch, .{});
        defer dir.close();
        self.tools = .{
            .a = a,
            .env = self.adapter.tools.env,
            .scratch = scratch,
            .scratch_dir = dir,
            .programs = self.adapter.tools.programs,
            .counts = &self.counts,
            .meter = self.batch.meter,
        };
        if (self.plan) |plan| {
            self.route_outcome = try adaptive.run(a, self, plan);
            return undefined;
        }
        return core.analyze(a, self, self.prepared.engines, self.prepared.context);
    }
};

const FollowupService = struct {
    app: Main,
    state: *store.State,
    repo: core.Repo,
    client: github.Client,
    work: followup_git.Work,

    pub fn origin(self: *FollowupService, job: followup.Job) !core.Pull {
        return self.client.pull(job.source.pr);
    }

    pub fn remote(self: *FollowupService, job: followup.Job) !?[]const u8 {
        return self.work.remote(try job.source.branch(self.app.a));
    }

    pub fn baseHead(self: *FollowupService, job: followup.Job) ![]const u8 {
        return (try self.work.remote(job.base)) orelse error.FollowupBaseMissing;
    }

    pub fn draft(self: *FollowupService, job: followup.Job) !?followup.Draft {
        const ref = (try self.client.followupRef(try job.source.branch(self.app.a), job.pr)) orelse return null;
        return .{
            .pull = try self.client.pull(ref.number),
            .branch = ref.head.ref,
            .repo = if (ref.head.repo) |item| item.full_name else "",
        };
    }

    fn verifiedDraft(self: *FollowupService, job: followup.Job) !core.Pull {
        const managed = (try self.draft(job)) orelse return error.FollowupDraftUnconfirmed;
        if (!try followup.matchesDraft(self.app.a, job, managed) or !eq(u8, managed.pull.state, "OPEN") or
            job.head == null or !eq(u8, managed.pull.headRefOid, job.head.?))
            return error.FollowupTargetChanged;
        return managed.pull;
    }

    pub fn feedback(self: *FollowupService, job: followup.Job, pull: core.Pull) !followup.Feedback {
        const reviews = try self.client.reviews(pull.number);
        const discussion = try self.client.discussion(pull.number);
        return followup.collectFeedback(self.app.a, job, pull, reviews, discussion);
    }

    fn checkIdentity(self: *FollowupService, job: followup.Job) !void {
        if (job.paused or try self.app.db.paused(job.source.repo)) return error.RepoPaused;
        if (!std.ascii.eqlIgnoreCase(job.login, self.repo.login) or !std.ascii.eqlIgnoreCase(try self.client.identity(), job.login))
            return error.GitHubIdentityChanged;
    }

    pub fn prepare(self: *FollowupService, job: followup.Job, source_pr: core.Pull, parent: []const u8, input: []const u8) !followup.Prepared {
        const a = self.app.a;
        const now = std.time.timestamp();
        const provider_usage: usage_meter.Snapshot = if (self.app.meter) |meter| meter.snapshot() else .{};
        var selected: ?core.Engine = null;
        for (try self.repo.providers(a)) |engine| {
            const at = self.state.queue_budget.engineAt(engine, now, 0, provider_usage) orelse continue;
            if (at > now) continue;
            selected = engine;
            break;
        }
        const engine = selected orelse return error.ReviewerCoolingDown;
        const discussion = try self.client.discussion(job.source.pr);
        const thread = for (discussion.threads) |thread| {
            if (eq(u8, thread.id, job.thread)) break thread;
        } else return error.FollowupThreadNotFound;
        const author = source_pr.author orelse return error.InvalidFollowupSource;
        const feedback_run = input.len != 0;
        const branch = if (feedback_run) try job.source.branch(a) else job.base;
        try self.work.fetch(branch, parent);
        const file = try self.work.read(parent, job.path);
        var evidence: std.ArrayList(followup.Evidence) = .empty;
        var remaining: usize = 24 * 1024;
        for (job.evidence_paths[0..@min(job.evidence_paths.len, 3)]) |path| {
            var item: followup.Evidence = .{ .path = path, .text = null };
            if (remaining != 0) {
                if (self.work.read(parent, path)) |extra| {
                    const length = core.safePrefix(extra.text, remaining);
                    item.text = extra.text[0..length];
                    item.clipped = length < extra.text.len;
                    remaining -= length;
                } else |err| {
                    if (err == error.OutOfMemory) return err;
                }
            }
            try evidence.append(a, item);
        }
        const prompt = try followup.prompt(a, job, author.login, thread, file.text, input, evidence.items);
        const answer = try invokeReviewer(self.app.local(self.repo), engine, reviewerProfile(self.repo, engine), followup.schema, prompt);
        const change = try followup.proposal(a, answer);
        if (change.action != .fix) return .{ .head = parent, .change = change };
        const revised = try followup.edit(a, file.text, change);
        const title = if (feedback_run) "fix: address followup review feedback" else try io.fmt(a, "fix: {s}", .{change.title});
        const head = try self.work.commit(job, parent, file.mode, revised, title);
        return .{ .head = head, .change = change };
    }

    pub fn persist(self: *FollowupService) !void {
        try self.app.db.save(self.state);
    }

    pub fn push(self: *FollowupService, job: followup.Job, parent: []const u8, head: []const u8) !void {
        try self.checkIdentity(job);
        if (job.pr != null) {
            const pull = try self.verifiedDraft(job);
            const input = try self.feedback(job, pull);
            if (input.needs_human or !eq(u8, &input.key, &job.pending.?.feedback.?)) return error.FollowupFeedbackChanged;
            _ = try self.verifiedDraft(job);
        } else if (!eq(u8, try self.baseHead(job), parent)) return error.FollowupTargetChanged;
        try self.work.push(try job.source.branch(self.app.a), job.head, head);
    }

    pub fn create(self: *FollowupService, job: followup.Job) !void {
        try self.checkIdentity(job);
        const a = self.app.a;
        const head = (try self.remote(job)) orelse return error.FollowupPushUnconfirmed;
        if (!eq(u8, head, job.head.?)) return error.FollowupTargetChanged;
        var body: std.ArrayList(u8) = .empty;
        try core.reviewProse(a, &body, job.summary);
        try body.writer(a).print("\n\nFollowup to <{s}>.\n\n{s}", .{ try job.source.url(a), try followup.marker(a, job.source) });
        try self.client.createFollowup(try job.source.branch(a), job.base, job.title, body.items);
    }

    pub fn ready(self: *FollowupService, job: followup.Job) !void {
        try self.checkIdentity(job);
        const pull = try self.verifiedDraft(job);
        const input = try self.feedback(job, pull);
        if (input.needs_human or (input.text.len != 0 and (job.feedback == null or !eq(u8, &job.feedback.?, &input.key))))
            return error.FollowupFeedbackChanged;
        const latest = try self.verifiedDraft(job);
        if (!latest.isDraft or !core.checksPassed(latest) or !eq(u8, pull.baseRefOid, latest.baseRefOid)) return error.FollowupChecksChanged;
        try self.client.readyFollowup(latest.number);
        if ((try self.verifiedDraft(job)).isDraft) return error.FollowupReadyUnconfirmed;
    }

    pub fn merge(self: *FollowupService, job: followup.Job) !void {
        if (!job.merge) return error.FollowupMergeDisabled;
        try self.checkIdentity(job);
        const pull = try self.verifiedDraft(job);
        const input = try self.feedback(job, pull);
        if (!input.approved or input.needs_human or (input.text.len != 0 and (job.feedback == null or !eq(u8, &job.feedback.?, &input.key))))
            return error.FollowupFeedbackChanged;
        const latest = try self.verifiedDraft(job);
        if (latest.isDraft or !core.checksPassed(latest) or !eq(u8, latest.baseRefOid, pull.baseRefOid)) return error.FollowupChecksChanged;
        try self.client.mergeFollowup(latest.number, latest.headRefOid);
    }
};

const Main = struct {
    a: A,
    env: *const std.process.EnvMap,
    home: []const u8,
    db: store.Store,
    scratch: [:0]const u8,
    scratch_dir: std.fs.Dir,
    output: std.fs.File = std.fs.File.stdout(),
    counts: ?*queue.TickCounts = null,
    meter: ?*usage_meter.Ledger = null,

    fn out(self: Main, comptime pattern: []const u8, args: anytype) !void {
        return io.print(self.output, pattern, args);
    }

    fn local(self: Main, entry: ?core.Repo) Local {
        return .{ .a = self.a, .env = self.env, .scratch = self.scratch, .scratch_dir = self.scratch_dir, .programs = Programs.fromRepo(entry), .counts = self.counts, .meter = self.meter };
    }

    fn objectCache(self: Main, repo: core.Repo) cache.Cache {
        return .{ .a = self.a, .root = self.db.dir, .repo = repo };
    }

    fn add(self: Main, state: *store.State, args: []const []const u8) !void {
        if (args.len == 0) return error.Usage;
        const name = try repoName(self.a, args[0]);
        const previous = if (state.find(name)) |entry| entry.repo else null;
        const config = try repo_config.parse(self.a, name, previous, state.default_engines, args[1..]);
        var repo = config.repo;
        if (queue.reviewerCost(repo) > state.queue_budget.limit) return error.ReviewBudgetTooSmall;
        var programs = config.programs;
        var tools = self.local(null);
        tools.programs = programs;
        repo.git = try tools.bin(.git);
        repo.gh = try tools.bin(.gh);
        for (try repo.providers(self.a)) |engine| {
            const tool = reviewerTool(engine);
            const bin = try tools.bin(tool);
            switch (tool) {
                inline else => |t| @field(programs, @tagName(t)) = bin,
            }
        }
        repo.codex = programs.codex;
        repo.claude = programs.claude;
        repo.kimi = programs.kimi;

        const gh_env = try tools.githubEnv();
        const client = try tools.gh(&gh_env, name);
        repo.login = try client.identity();
        if (state.find(name)) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.repo.login, repo.login)) return error.GitHubIdentityChanged;
            if (!eq(u8, try io.json(self.a, entry.repo), try io.json(self.a, repo))) {
                for (entry.jobs) |*job| {
                    job.route_progress = null;
                    job.analysis = null;
                }
            }
            entry.repo = repo;
            entry.next_scan = 0;
            entry.next_cache_check = 0;
            try self.db.save(state);
            try self.out("Updated {s} as {s}\n", .{ name, repo.login });
        } else {
            const pulls = try client.ready();
            const natives = try client.nativeGroups(pulls);
            var repo_dir = (try self.objectCache(repo).repoDir(true)) orelse return error.RepositoryDirectoryMissing;
            repo_dir.close();
            var entry: core.Entry = .{ .repo = repo };
            try entry.discover(self.a, pulls, true);
            try stack.syncNative(&entry, self.a, natives);
            try stack.autogroup(&entry, self.a, pulls);
            entry.last_scan = std.time.timestamp();
            entry.next_scan = entry.last_scan + repo.interval;
            try state.add(self.a, entry);
            try self.db.save(state);
            try self.out("Added {s} as {s} with {d} ready PRs baselined\n", .{ name, repo.login, entry.seen.len });
        }
    }

    fn defaults(self: Main, state: *store.State, args: []const []const u8) !void {
        if (args.len != 0) {
            if (args.len != 2 or !eq(u8, args[0], "--engine")) return error.Usage;
            state.default_engines = try parseEngines(self.a, args[1]);
            try self.db.save(state);
        }
        try self.out("Default reviewers for new repos {s}\n", .{try engineNames(self.a, state.default_engines)});
    }

    fn adapter(self: Main, entry: *core.Entry, state: *const store.State, gh_env: *std.process.EnvMap) !Adapter {
        const repo = entry.repo;
        const tools = self.local(repo);
        gh_env.* = try tools.githubEnv();
        return .{
            .db = self.db,
            .state = state,
            .repo = repo,
            .entry = entry,
            .github_client = try tools.gh(gh_env, repo.name),
            .git_source = try tools.git(gh_env, self.db, repo),
            .tools = tools,
        };
    }

    fn scan(self: Main, entry: *core.Entry, managed: []const followup.Job) !void {
        const local_tools = self.local(entry.repo);
        const env = try local_tools.githubEnv();
        const client = try local_tools.gh(&env, entry.repo.name);
        if (!std.ascii.eqlIgnoreCase(entry.repo.login, try client.identity())) return error.GitHubIdentityChanged;
        const available = try client.ready();
        const pulls = if (managed.len == 0) available else tracked: {
            var unmatched: std.ArrayList(core.Pull) = .empty;
            pull_loop: for (available) |pull| {
                for (managed) |job| {
                    if (!std.ascii.eqlIgnoreCase(job.source.repo, entry.repo.name)) continue;
                    if (job.pr == pull.number) continue :pull_loop;
                }
                try unmatched.append(self.a, pull);
            }
            break :tracked unmatched.items;
        };
        const natives = try client.nativeGroups(pulls);
        const pins = try client.stackPulls(try stack.numbers(self.a, entry.stacks));
        try entry.discover(self.a, pulls, false);
        try stack.refresh(entry, self.a, pins);
        try stack.syncNative(entry, self.a, natives);
        try stack.autogroup(entry, self.a, pulls);
        try self.scanReviewInputs(entry, client, pulls);
    }

    fn scanReviewInputs(self: Main, entry: *core.Entry, client: github.Client, pulls: []const core.Pull) !void {
        if (entry.jobs.len == 0) return;
        var checked: usize = 0;
        for (0..entry.jobs.len) |_| {
            const index = entry.discussion_cursor % entry.jobs.len;
            entry.discussion_cursor = (index + 1) % entry.jobs.len;
            const job = &entry.jobs[index];
            if (job.phase != .complete) continue;
            for (pulls) |pull| {
                if (pull.number != job.number or !core.isReady(pull) or !eq(u8, pull.headRefOid, job.head)) continue;
                self.refreshReviewInput(entry.repo, client, job, pull) catch |err| {
                    if (err == error.GitHubRateLimited) return err;
                    try entry.problem(self.a, std.time.timestamp(), job.number, @errorName(err));
                };
                checked += 1;
                break;
            }
            // Rotate the starting point so busy repos cannot starve older PRs.
            if (checked == 4) break;
        }
    }

    fn refreshReviewInput(self: Main, repo: core.Repo, client: github.Client, job: *core.Job, pull: core.Pull) !void {
        const target = if (job.awaiting_checks and repo.approvals) try client.pull(pull.number) else pull;
        if (!core.isReady(target) or !eq(u8, pull.headRefOid, target.headRefOid) or
            !eq(u8, pull.baseRefOid, target.baseRefOid) or !eq(u8, pull.baseRefName, target.baseRefName)) return;
        const discussion = try client.discussion(pull.number);
        const saved = job.review_input;
        const merge_base = if (saved != null and eq(u8, saved.?.base.oid, pull.baseRefOid))
            saved.?.merge_base
        else
            try client.mergeBase(pull.baseRefOid, pull.headRefOid);
        const current = try core.ReviewInput.init(self.a, repo, target, merge_base, discussion);
        const legacy_changed = saved == null and job.receipt != null and
            job.legacyDiscussionChanged(repo.login, discussion, try client.reviews(pull.number));
        job.observeReviewInput(current, legacy_changed);
    }

    fn tick(self: Main, state: *store.State) !void {
        var counts: queue.TickCounts = .{ .at = std.time.timestamp() };
        var worker = self;
        worker.counts = &counts;
        for (state.entries) |*entry| {
            const now = std.time.timestamp();
            var changed = false;
            if (entry.next_cache_check <= now) {
                self.objectCache(entry.repo).maintain(now) catch |err| {
                    try entry.problem(self.a, now, null, try io.fmt(self.a, "Git cache: {s}", .{@errorName(err)}));
                };
                entry.next_cache_check = now + cache.check_interval;
                changed = true;
            }
            if (entry.next_scan <= now and state.queue_budget.canScan(now) and !try self.db.paused(entry.repo.name)) {
                if (worker.scan(entry, state.followups)) |_| {
                    entry.last_scan = std.time.timestamp();
                    entry.next_scan = entry.last_scan + entry.repo.interval;
                    entry.scan_attempts = 0;
                } else |err| {
                    state.queue_budget.noteFailure(std.time.timestamp(), err);
                    entry.scan_attempts +|= 1;
                    entry.next_scan = now + core.delay(entry.scan_attempts);
                    try entry.problem(self.a, now, null, @errorName(err));
                }
                changed = true;
            }
            if (changed) {
                if (counts.github_commands != 0) state.queue_budget.last_tick = counts;
                try self.db.save(state);
            }
        }
        if (state.entries.len == 0) return;
        try worker.tickFollowup(state, &counts);
        try worker.reviewBatch(state, &counts);
        if (counts.jobs != 0) {
            state.queue_budget.last_tick = counts;
            try self.db.save(state);
        }
    }

    fn followupService(self: Main, state: *store.State, repo: core.Repo, env: *std.process.EnvMap) !FollowupService {
        const tools = self.local(repo);
        env.* = try tools.githubEnv();
        return .{
            .app = self,
            .state = state,
            .repo = repo,
            .client = try tools.gh(env, repo.name),
            .work = try followup_git.Work.make(try tools.git(env, self.db, repo), self.scratch, repo.name),
        };
    }

    fn followupStatus(self: Main, state: store.State, args: []const []const u8) !void {
        if (args.len != 0) {
            if (args.len != 1 or !eq(u8, args[0], "--json")) return error.Usage;
            return self.out("{s}\n", .{try io.json(self.a, state.followups)});
        }
        if (state.followups.len == 0) return self.out("No followups queued.\n", .{});
        for (state.followups) |job| {
            const source_url = try job.source.url(self.a);
            const draft_url = if (job.pr) |pr| try io.fmt(self.a, "  https://github.com/{s}/pull/{d}", .{ job.source.repo, pr }) else "";
            try self.out("{s}  {s}{s}\n", .{ source_url, if (job.paused) "paused" else @tagName(job.stage), draft_url });
            if (job.note.len != 0) try self.out("  {s}\n", .{job.note});
        }
    }

    fn findFollowup(state: *store.State, target: followup.Target) ?*followup.Job {
        for (state.followups) |*job| if (job.source.same(target)) return job;
        return null;
    }

    fn followupCommand(self: Main, state: *store.State, args: []const []const u8) !void {
        if (args.len == 0 or args.len > 2) return error.Usage;
        if (eq(u8, args[0], "pause") or eq(u8, args[0], "resume")) {
            if (args.len != 2) return error.Usage;
            const job = findFollowup(state, try followup.Target.parse(args[1])) orelse return error.FollowupNotQueued;
            job.paused = eq(u8, args[0], "pause");
            if (!job.paused) {
                job.attempts = 0;
                job.next = 0;
                if (job.stage == .needs_input and job.pr == null) {
                    job.stage = .waiting;
                    job.evidence_paths = &.{};
                }
            }
            try self.db.save(state);
            return self.out("{s} followup\n", .{if (job.paused) "Paused" else "Resumed"});
        }
        const preview = args.len == 2 and eq(u8, args[1], "--dry-run");
        const merge = args.len == 2 and eq(u8, args[1], "--merge-when-ready");
        if (args.len == 2 and !preview and !merge) return error.Usage;
        var target = try followup.Target.parse(args[0]);
        const entry = state.find(target.repo) orelse return error.UnknownRepository;
        target.repo = entry.repo.name;

        var env: std.process.EnvMap = undefined;
        var service = try self.followupService(state, entry.repo, &env);
        const source_pr = try service.client.pull(target.pr);
        const discussion = try service.client.discussion(target.pr);
        var job = try followup.select(self.a, target, entry.repo.login, source_pr, discussion);
        if (!followup_git.allowed(job.path)) return error.FollowupPathDisallowed;
        if (preview) {
            if (!eq(u8, source_pr.state, "MERGED")) return self.out("Waiting for the source PR to merge.\n", .{});
            var ledger: usage_meter.Ledger = .{ .dir = self.db.dir, .data = try usage_meter.load(self.a, self.db.dir, std.time.timestamp()) };
            service.app.meter = &ledger;
            const parent = try service.baseHead(job);
            var prepared = try service.prepare(job, source_pr, parent, "");
            if (prepared.change.action == .request_source) {
                job.evidence_paths = prepared.change.evidence_paths;
                prepared = try service.prepare(job, source_pr, parent, "");
            }
            return self.out("{s}\n", .{try io.json(self.a, .{ .path = job.path, .base = parent, .proposal = prepared.change })});
        }
        if (eq(u8, source_pr.state, "CLOSED")) return error.FollowupSourceClosed;
        if (findFollowup(state, job.source)) |existing| {
            if (merge and !existing.merge) {
                if (!std.ascii.eqlIgnoreCase(try service.client.identity(), existing.login)) return error.GitHubIdentityChanged;
                existing.merge = true;
                try self.db.save(state);
            }
            const url = if (existing.pr) |pr| try io.fmt(self.a, "https://github.com/{s}/pull/{d}", .{ existing.source.repo, pr }) else try existing.source.url(self.a);
            return self.out("Followup already tracked. {s}\n", .{url});
        }
        if (!std.ascii.eqlIgnoreCase(try service.client.identity(), job.login)) return error.GitHubIdentityChanged;
        job.merge = merge;
        state.followups = try std.mem.concat(self.a, followup.Job, &.{ state.followups, &.{job} });
        try self.db.save(state);
        return self.out("Queued followup for {s}\n", .{try job.source.url(self.a)});
    }

    fn tickFollowup(self: Main, state: *store.State, counts: *queue.TickCounts) !void {
        const now = std.time.timestamp();
        if (!state.queue_budget.canScan(now)) return;
        var candidate: ?*followup.Job = null;
        for (state.followups) |*job| {
            if (!job.active() or job.paused or job.next > now or try self.db.paused(job.source.repo)) continue;
            if (candidate == null or job.next < candidate.?.next) candidate = job;
        }
        const job = candidate orelse return;
        const entry = state.find(job.source.repo) orelse return error.UnknownRepository;
        var env: std.process.EnvMap = undefined;
        var service = try self.followupService(state, entry.repo, &env);
        counts.jobs += 1;
        if (followup.advance(self.a, &service, job)) |_| {
            job.attempts = 0;
            job.next = std.time.timestamp() + entry.repo.interval;
        } else |err| {
            state.queue_budget.noteFailure(std.time.timestamp(), err);
            if (err == error.ReviewerCoolingDown or err == error.RepoPaused) {
                job.note = if (err == error.ReviewerCoolingDown) "Waiting for a reviewer." else "The repo is paused.";
                job.next = std.time.timestamp() + entry.repo.interval;
            } else {
                job.attempts +|= 1;
                job.next = std.time.timestamp() + core.delay(job.attempts);
                job.note = @errorName(err);
                if (job.attempts >= 6) job.paused = true;
            }
        }
        try self.db.save(state);
    }

    fn showQueueBudget(self: Main, budget: queue.Budget) !void {
        try self.out("Queue budget {d} reviewer starts and {d} receipt checks per tick\n", .{ budget.limit, budget.limit });
        try self.out("Parallel reviews up to {d} per repo across {d} repos\n", .{ queue.jobs_per_repo, queue.active_repos });
        const counts = budget.last_tick;
        if (counts.at != 0) {
            try self.out("  Last active tick {s}  |  Reviewer starts {d}  |  GitHub CLI calls {d}  |  Jobs {d}  |  Receipt checks {d}\n", .{
                try formatTime(self.a, counts.at), counts.reviewer_starts, counts.github_commands, counts.jobs, counts.receipt_checks,
            });
        }
    }

    fn setQueueBudget(self: Main, state: *store.State, args: []const []const u8) !void {
        if (args.len != 1) return error.Usage;
        var proposed = state.queue_budget;
        proposed.limit = std.fmt.parseUnsigned(u32, args[0], 10) catch return error.InvalidReviewBudget;
        try proposed.validate(state.entries);
        state.queue_budget = proposed;
        try self.db.save(state);
        try self.showQueueBudget(state.queue_budget);
    }

    fn reviewBatch(self: Main, state: *store.State, counts: *queue.TickCounts) !void {
        const limit = state.queue_budget.limit;
        var batch: ReviewBatch = .{ .starts_left = limit -| counts.reviewer_starts, .receipts_left = limit, .meter = self.meter };
        defer batch.deinit();

        var repos: [queue.active_repos]queue.RepoJobs = undefined;
        var active: usize = 0;
        const first = state.queue_budget.next_repo % state.entries.len;
        // Give each eligible repo a turn before filling its second and third slots.
        for (0..state.entries.len) |offset| {
            const index = (first + offset) % state.entries.len;
            var lane: queue.RepoJobs = .{ .index = index };
            if (!try self.admit(state, counts, &batch, &lane, active < repos.len)) continue;
            repos[active] = lane;
            active += 1;
        }
        for (1..queue.jobs_per_repo) |_| {
            for (repos[0..active]) |*lane| _ = try self.admit(state, counts, &batch, lane, true);
        }
        if (batch.deferred_repo) |index| state.queue_budget.next_repo = index;

        while (batch.pending != 0) {
            batch.completed.wait();
            try self.finishReady(state, counts, &batch);
        }
    }

    fn finishReady(self: Main, state: *store.State, counts: *queue.TickCounts, batch: *ReviewBatch) !void {
        for (batch.workers[0..batch.len]) |work| {
            const thread = work.thread orelse continue;
            if (!work.done.load(.acquire)) continue;
            thread.join();
            work.thread = null;
            batch.pending -= 1;
            counts.reviewer_starts += work.counts.reviewer_starts;
            if (work.plan) |plan| batch.starts_left += plan.start_limit - work.counts.reviewer_starts;
            self.finishJob(state, work) catch |err| switch (err) {
                error.ReviewerCoolingDown, error.ProviderBudgetReached => {
                    if (work.plan == null) batch.starts_left += queue.reviewerCost(work.adapter.repo) - work.counts.reviewer_starts;
                },
                else => try self.jobFailed(state, work.adapter.entry, work.job, err),
            };
        }
    }

    fn admit(self: Main, state: *store.State, counts: *queue.TickCounts, batch: *ReviewBatch, lane: *queue.RepoJobs, has_slot: bool) !bool {
        // Reconcile finished jobs and cooldowns before reserving more work.
        try self.finishReady(state, counts, batch);
        const entry = &state.entries[lane.index];
        if (try self.db.paused(entry.repo.name)) return false;
        const allow_fresh_routed = retainedCount(state) + batch.pending < queue.parallel_jobs;
        const decision = state.queue_budget.pick(entry, std.time.timestamp(), batch.starts_left, batch.receipts_left, lane.selected(), batch.limited.load(.monotonic), batch.usageSnapshot(), allow_fresh_routed);
        if (decision.budget_deferred or (!has_slot and decision.job != null)) batch.deferRepo(lane.index);
        const job = decision.job orelse return false;
        if (!has_slot) return false;
        lane.add(job.number);

        // Reserve the full ensemble before touching GitHub. Deduplicated
        // jobs still cost lookups and consume a slot for this tick.
        if (job.phase == .uncertain) {
            batch.receipts_left -= 1;
            counts.receipt_checks += 1;
        } else {
            batch.starts_left -= queue.reviewerCost(entry.repo);
        }
        counts.jobs += 1;
        state.queue_budget.next_repo = batch.deferred_repo orelse (lane.index + 1) % state.entries.len;
        self.startJob(state, entry, job, batch) catch |err| switch (err) {
            // Refund model starts. Keep the PR slot charged for GitHub work.
            error.ReviewerCoolingDown => batch.starts_left += queue.reviewerCost(entry.repo),
            else => try self.jobFailed(state, entry, job, err),
        };
        return true;
    }

    fn startJob(self: Main, state: *store.State, entry: *core.Entry, job: *core.Job, batch: *ReviewBatch) !void {
        // Each adapter keeps its own file anchors. Only the coordinator uses
        // Git and GitHub, so snapshots may share the per-repo cache and refs.
        const work = try self.a.create(ReviewWorker);
        work.* = .{ .job = job, .batch = batch };
        work.adapter = try self.adapter(entry, state, &work.gh_env);
        work.prepared = (try core.prepare(self.a, &work.adapter, entry.repo, job, .scheduled)) orelse return;
        if (job.analysis) |saved| {
            if (try saved.matches(self.a, entry.repo, work.prepared)) {
                if (try self.db.paused(entry.repo.name)) return;
                work.prepared.route_depth = saved.route_depth;
                work.prepared.synthesis_provider = saved.synthesis_provider;
                work.prepared.synthesis_summary = saved.synthesis_summary;
                work.prepared.additional_evidence_limited = saved.additional_evidence_limited;
                _ = try core.finish(self.a, &work.adapter, entry.repo, job, work.prepared, saved.results);
                return;
            }
            job.analysis = null;
            // Persist the invalidation even if the provider holds this job.
            try self.db.save(state);
        }
        work.policy = state.queue_budget;
        if (entry.repo.usesRouting()) {
            const fingerprint = try core.SavedAnalysis.key(self.a, entry.repo, work.prepared);
            var progress: core.RouteProgress = .{ .fingerprint = fingerprint, .base = .fromPull(work.prepared.pr) };
            if (job.route_progress) |saved| {
                if (eq(u8, &saved.fingerprint, &fingerprint)) {
                    progress = saved;
                    progress.base = .fromPull(work.prepared.pr);
                } else job.route_progress = null;
            }
            const automatically_routed = entry.repo.routing_mode != .fixed and work.prepared.options.allowRouting();
            var screen: routing.Screen = if (automatically_routed)
                routing.inspect(work.adapter.files, work.prepared.snap.limited)
            else
                .{ .floor = .{}, .ask_model = false };
            if (automatically_routed and entry.repo.routing_mode == .adaptive and work.prepared.snap.limited) {
                // Keep the risk floor and use screening to request missing source.
                screen.ask_model = true;
            }
            if (automatically_routed and work.prepared.inherited.pins.len > 1) {
                screen.floor = screen.floor.merge(.{ .depth = .focused, .reliability = true });
                screen.ask_model = false;
            }
            var evidence: ?[]const u8 = null;
            var evidence_limited = false;
            if (progress.evidence_requests.len != 0) {
                const capacity = adaptive.evidenceCapacity(work.prepared);
                if (capacity == 0) {
                    evidence = "";
                    evidence_limited = true;
                } else {
                    const supplement = try work.adapter.supplement(work.prepared.pr, null, progress.evidence_requests);
                    const excerpt = supplement.evidence[0..core.safePrefix(supplement.evidence, capacity)];
                    evidence_limited = supplement.limited or excerpt.len < supplement.evidence.len;
                    evidence = if (excerpt.len == supplement.evidence.len) excerpt else excerpt[0..(std.mem.lastIndexOfScalar(u8, excerpt, '\n') orelse 0)];
                }
                var hash = std.crypto.hash.sha2.Sha256.init(.{});
                hash.update(evidence.?);
                hash.update(&.{@intFromBool(evidence_limited)});
                const evidence_key = hash.finalResult();
                if (progress.evidence_key) |prior| {
                    if (!eq(u8, &prior, &evidence_key)) {
                        progress.results = &.{};
                        progress.review_ms = 0;
                    }
                }
                progress.evidence_key = evidence_key;
            }
            work.plan = .{
                .repo = entry.repo,
                .providers = try entry.repo.providers(self.a),
                .prepared = work.prepared,
                .screen = screen,
                .progress = progress,
                .start_limit = queue.reviewerCost(entry.repo),
                .evidence = evidence,
                .evidence_limited = evidence_limited,
            };
        }
        if (!state.queue_budget.canReview(entry.repo, job.route_progress, std.time.timestamp(), batch.limited.load(.monotonic), batch.usageSnapshot()))
            return error.ReviewerCoolingDown;
        work.thread = try std.Thread.spawn(.{}, ReviewWorker.analyze, .{work});
        batch.pending += 1;
        batch.workers[batch.len] = work;
        batch.len += 1;
    }

    fn finishJob(self: Main, state: *store.State, work: *ReviewWorker) !void {
        const results = try work.result;
        if (work.route_outcome) |outcome| {
            for (std.meta.tags(core.Engine)) |engine| {
                if (work.rate_limits & queue.engineBit(engine) != 0) {
                    const err = switch (engine) {
                        .codex => error.CodexRateLimited,
                        .claude => error.ClaudeRateLimited,
                        .kimi => error.KimiRateLimited,
                    };
                    state.queue_budget.noteFailure(std.time.timestamp(), err);
                }
            }
            if (outcome.report) |report| {
                work.prepared.route_depth = report.applied.depth;
                work.prepared.synthesis_provider = report.synthesis_provider;
                work.prepared.synthesis_summary = outcome.synthesis_summary;
                work.prepared.additional_evidence_limited = outcome.evidence_limited;
                work.job.route_report = report;
                work.job.route_report.?.providers = try self.a.dupe(core.Engine, report.providers);
                work.job.route_progress = null;
                return self.finishReviews(state, work, outcome.review_results orelse outcome.progress.results);
            }
            work.job.route_progress = try io.parse(self.a, core.RouteProgress, try io.json(self.a, outcome.progress));
            if (outcome.failure) |err| return err;
            try self.db.save(state);
            return;
        }
        return self.finishReviews(state, work, results[0..work.prepared.engines.len]);
    }

    fn finishReviews(self: Main, state: *store.State, work: *ReviewWorker, reviews: []const core.ReviewerResult) !void {
        if (try self.db.paused(work.adapter.repo.name)) return;
        if (!state.queue_budget.canScan(std.time.timestamp())) {
            try self.keepAnalysis(state, work, reviews);
            try self.db.save(state);
            return;
        }
        _ = core.finish(self.a, &work.adapter, work.adapter.repo, work.job, work.prepared, reviews) catch |err| {
            // An uncertain publication may only be reconciled by its receipt.
            if (err == error.GitHubRateLimited and work.job.phase == .pending) try self.keepAnalysis(state, work, reviews);
            return err;
        };
    }

    fn retainedCount(state: *const store.State) usize {
        var retained: usize = 0;
        for (state.entries) |entry| {
            for (entry.jobs) |job| {
                const has_checkpoint = if (job.route_progress) |progress| !progress.needsAnotherProvider(entry.repo) else false;
                retained += @intFromBool(job.analysis != null or has_checkpoint);
            }
        }
        return retained;
    }

    fn keepAnalysis(self: Main, state: *store.State, work: *ReviewWorker, reviews: []const core.ReviewerResult) !void {
        // Bound transient checkpoints to one full batch, even after repeated rate limits.
        if (retainedCount(state) >= queue.parallel_jobs) return;
        work.job.analysis = try core.SavedAnalysis.save(self.a, work.adapter.repo, work.prepared, reviews);
    }

    fn jobFailed(self: Main, state: *store.State, entry: *core.Entry, job: *core.Job, err: anyerror) !void {
        if (err != error.GitHubRateLimited) job.analysis = null;
        if (err == error.StackChanged or err == error.GitHubStackChanged) entry.next_scan = 0;
        const now = std.time.timestamp();
        state.queue_budget.noteFailure(now, err);
        try core.recordFailure(entry, self.a, job, now, err);
        if (!job.schedulable()) {
            job.analysis = null;
            job.route_progress = null;
        }
        try self.db.save(state);
    }

    fn registerStack(self: Main, state: *store.State, args: []const []const u8) !void {
        if (args.len != 2 and (args.len < 4 or args.len > stack.max_members + 2)) return error.Usage;
        const entry = state.find(args[0]) orelse return error.UnknownRepository;
        const tools = self.local(entry.repo);
        const env = try tools.githubEnv();
        const client = try tools.gh(&env, entry.repo.name);
        if (args.len == 2) {
            const number = try prNumber(args[1]);
            if (!std.ascii.eqlIgnoreCase(entry.repo.login, try client.identity())) return error.GitHubIdentityChanged;
            const group = try client.nativeByNumber(number);
            const count = try stack.queueNative(entry, self.a, group);
            try self.db.save(state);
            return self.out("Queued {s} GitHub stack #{d} with {d} ready PRs\n", .{ entry.repo.name, number, count });
        }
        const name = args[1];
        var members: [stack.max_members]u32 = undefined;
        const numbers = members[0 .. args.len - 2];
        for (args[2..], numbers) |arg, *number| number.* = try prNumber(arg);
        try stack.validateRegistration(entry.*, name, numbers);
        if (!std.ascii.eqlIgnoreCase(entry.repo.login, try client.identity())) return error.GitHubIdentityChanged;
        try stack.register(entry, self.a, name, try client.stackPulls(numbers));
        try self.db.save(state);
        try self.out("Queued {s} stack {s} with {d} PRs\n", .{ entry.repo.name, name, numbers.len });
    }

    fn choose(self: Main, entry: *core.Entry, number: u32) !core.Pull {
        const tools = self.local(entry.repo);
        const env = try tools.githubEnv();
        const gh = try tools.gh(&env, entry.repo.name);
        const pr = try gh.pull(number);
        if (!core.isReady(pr)) return error.PullRequestNotReady;
        if (!core.validOid(pr.headRefOid)) return error.InvalidCommit;
        return pr;
    }

    fn reviewOptions(args: []const []const u8, allow_publish: bool) !core.ReviewOptions {
        var options: core.ReviewOptions = .{};
        var index: usize = 0;
        while (index < args.len) {
            const flag = args[index];
            index += 1;
            if (eq(u8, flag, "--publish") and allow_publish and !options.publish_prompted) {
                options.publish_prompted = true;
                continue;
            }
            if (index == args.len) return error.Usage;
            const value = args[index];
            index += 1;
            if (eq(u8, flag, "--mode") and !options.explicit_mode) {
                options.focus = std.meta.stringToEnum(core.ReviewFocus, value) orelse return error.InvalidReviewMode;
                options.explicit_mode = true;
            } else if (eq(u8, flag, "--prompt") and options.request == null) {
                try core.validateReviewRequest(value);
                options.request = value;
            } else return error.Usage;
        }
        if (options.publish_prompted and options.request == null) return error.Usage;
        return options;
    }

    fn dry(self: Main, state: *store.State, args: []const []const u8) !void {
        var preview: core.Preview = .{
            .options = if (args.len > 2) try reviewOptions(args[2..], false) else null,
        };
        if (args.len >= 1 and !core.validRepoName(args[0])) return error.Usage;
        const number = if (args.len >= 2) try prNumber(args[1]) else null;
        const target = if (args.len > 0) state.find(args[0]) orelse return error.UnknownRepository else null;
        for (state.entries) |*entry| {
            if (target != null and entry != target.?) continue;
            var job: core.Job = undefined;
            if (number) |pr| {
                const pull = try self.choose(entry, pr);
                preview.pull = pull;
                job = .{ .number = pull.number, .head = pull.headRefOid, .last_review = entry.lastReview(pull.number) };
            } else {
                if (try self.db.paused(entry.repo.name)) continue;
                try self.scan(entry, state.followups); // This copy is never written back.
                const queued = entry.due(std.time.timestamp()) orelse continue;
                if (queued.phase != .pending) continue;
                job = queued.*;
            }
            var gh_env: std.process.EnvMap = undefined;
            var live = try self.adapter(entry, state, &gh_env);
            const payload = (try core.run(self.a, &live, entry.repo, &job, .{ .preview = preview })).?;
            try self.out("{s}\n", .{try io.json(self.a, .{ .repo = entry.repo.name, .pr = job.number, .review = payload })});
        }
    }

    fn status(self: Main, state: *store.State, args: []const []const u8) !void {
        var repo: ?[]const u8 = null;
        var json_output = false;
        for (args) |arg| {
            if (eq(u8, arg, "--json") and !json_output) {
                json_output = true;
            } else if (repo == null) {
                repo = arg;
            } else return error.Usage;
        }
        if (repo) |name| if (state.find(name) == null) return error.UnknownRepository;
        if (!json_output) try self.showQueueBudget(state.queue_budget);
        if (state.entries.len == 0 and !json_output) try self.out("No repositories registered\n", .{});
        if (json_output) try self.out("[", .{});
        const now = std.time.timestamp();
        const provider_usage = try usage_meter.load(self.a, self.db.dir, now);
        var first = true;
        for (state.entries) |entry| {
            if (repo != null and !std.ascii.eqlIgnoreCase(repo.?, entry.repo.name)) continue;
            const paused = try self.db.paused(entry.repo.name);
            const measurement = self.objectCache(entry.repo).measure();
            const retained: ?u64 = if (measurement) |bytes| bytes else |_| null;
            const cache_error: ?[]const u8 = if (measurement) |_| null else |err| @errorName(err);
            const stacks = try stack.statuses(self.a, entry);
            const next = if (paused) null else state.queue_budget.nextEligible(entry, now, provider_usage);
            if (json_output) {
                var summary = entry;
                // Show pins and scheduling separately without echoing stored PR text.
                summary.stacks = &.{};
                summary.jobs = try self.a.dupe(core.Job, entry.jobs);
                const PendingRoute = struct { number: u32, head: []const u8, decision: ?routing.Decision, completed_passes: usize };
                var pending: std.ArrayList(PendingRoute) = .empty;
                for (summary.jobs) |*job| {
                    if (job.route_progress) |progress| try pending.append(self.a, .{
                        .number = job.number,
                        .head = job.head,
                        .decision = progress.decision,
                        .completed_passes = progress.results.len,
                    });
                    job.analysis = null;
                    job.route_progress = null;
                    job.last_review = null;
                    job.expected_inline = null;
                    if (job.options.request != null) job.options.request = "(set)";
                }
                try self.out("{s}{s}", .{ if (first) "" else ",", try io.json(self.a, .{
                    .paused = paused,
                    .state = summary,
                    .stacks = stacks,
                    .cache_bytes = retained,
                    .cache_error = cache_error,
                    .queue_budget = state.queue_budget,
                    .provider_usage = provider_usage,
                    .pending_routes = pending.items,
                    .next_eligible = next,
                }) });
                first = false;
                continue;
            }
            try self.out("{s}  {s}  {s}  interval {d}s  comments {s}  approvals {s}\n", .{
                entry.repo.name,     if (paused) "paused" else "active",       try engineNames(self.a, try entry.repo.engines(self.a)),
                entry.repo.interval, if (entry.repo.comments) "on" else "off", if (entry.repo.approvals) "on" else "off",
            });
            if (entry.repo.usesRouting()) {
                try self.out("  Routing {s}  |  Providers {s}\n", .{
                    @tagName(entry.repo.routing_mode), try engineNames(self.a, try entry.repo.providers(self.a)),
                });
            }
            if (next) |item| {
                try self.out("  Next eligible PR #{d} at {s}  |  Reviewer slots {d}\n", .{
                    item.number, try formatTime(self.a, item.at), item.reviewer_starts,
                });
            }
            try self.out("  Last successful scan {s}  |  Next scan {s}  |  Ready PRs {d}\n", .{
                try formatTime(self.a, entry.last_scan), try formatTime(self.a, entry.next_scan), entry.seen.len,
            });
            if (retained) |bytes| {
                try self.out("  Git cache {d} bytes / {d} MiB  |  Idle expiry {d}d\n", .{ bytes, entry.repo.cache_mib, entry.repo.cache_idle_days });
            } else {
                try self.out("  Git cache unavailable ({s})\n", .{cache_error.?});
            }
            var queued: usize = 0;
            for (entry.jobs) |job| {
                if (job.phase == .complete) continue;
                queued += 1;
                try self.out("  #{d} {s} {s}, attempts {d}, next {s}\n", .{
                    job.number,                       job.head[0..@min(job.head.len, 10)], @tagName(job.phase), job.attempts,
                    try formatTime(self.a, job.next),
                });
                if (job.route_progress) |progress| {
                    const depth = if (progress.decision) |decision| @tagName(decision.depth) else "screening";
                    try self.out("    Route {s}, {d} completed independent passes\n", .{ depth, progress.results.len });
                }
            }
            if (queued == 0) try self.out("  Queue empty\n", .{});
            var completed: usize = 0;
            var index = entry.jobs.len;
            while (index > 0 and completed < 5) {
                index -= 1;
                const job = entry.jobs[index];
                if (job.phase != .complete) continue;
                completed += 1;
                try self.out("  #{d} {s} complete. {s}", .{
                    job.number, job.head[0..@min(job.head.len, 10)], job.outcome orelse "review finished",
                });
                if (job.route_report) |report| try self.out("  {s} via {s}", .{
                    @tagName(report.applied.depth), try engineNames(self.a, report.providers),
                });
                if (job.receipt) |id| try self.out("  https://github.com/{s}/pull/{d}#pullrequestreview-{d}", .{
                    entry.repo.name, job.number, id,
                });
                try self.out("\n", .{});
            }
            for (stacks) |item| {
                if (item.native_number) |number| {
                    try self.out("  GitHub stack #{d} (bottom to top)\n", .{number});
                } else {
                    try self.out("  {s} {s} (bottom to top)\n", .{ if (item.automatic) "Auto stack" else "Stack", item.name });
                }
                for (item.members) |member| {
                    try self.out("    #{d} {s} {s}", .{ member.number, member.state, member.review });
                    if (member.blocked_by) |reason|
                        try self.out(" | Blocked by #{d} ({s})", .{ reason.number, reason.reason });
                    try self.out("\n", .{});
                }
            }
            for (entry.errors) |issue| {
                try self.out("  {s}  {s}", .{ try formatTime(self.a, issue.at), issue.detail });
                if (issue.number) |number| try self.out("  PR #{d}", .{number});
                try self.out("\n", .{});
            }
        }
        if (json_output) try self.out("]\n", .{});
    }

    fn showUsage(self: Main, state: *const store.State, current: usage_meter.Snapshot) !void {
        const now = std.time.timestamp();
        var data = current;
        for (std.meta.tags(core.Engine)) |engine| {
            const count = data.get(engine);
            const cap = if (count.limit == 0) "unlimited" else try io.fmt(self.a, "{d}", .{count.limit});
            const cooldown = state.queue_budget.providerRetry(engine);
            try self.out("{s}  {d}/{s} starts today (UTC)  |  {d} tracked total  |  cooldown {s}\n", .{
                @tagName(engine), count.starts, cap, count.total_starts, try formatTime(self.a, if (cooldown > now) cooldown else 0),
            });
        }
    }

    fn withUsage(self: Main, state: *store.State, preview_args: ?[]const []const u8) !void {
        var metered = self;
        var ledger: usage_meter.Ledger = .{
            .dir = self.db.dir,
            .data = try usage_meter.load(self.a, self.db.dir, std.time.timestamp()),
        };
        metered.meter = &ledger;
        if (preview_args) |args| return metered.dry(state, args);
        return metered.tick(state);
    }

    fn scheduledTick(self: Main) !void {
        log_retention.maintain(self.a, self.db.dir, std.time.nanoTimestamp()) catch |err|
            std.log.warn("diagnostic log maintenance failed ({s})", .{@errorName(err)});
        defer log_retention.maintain(self.a, self.db.dir, std.time.nanoTimestamp()) catch |err|
            std.log.warn("diagnostic log maintenance failed ({s})", .{@errorName(err)});
        const result: anyerror!void = tick: {
            var state = self.db.load() catch |err| break :tick err;
            break :tick self.withUsage(&state, null);
        };
        result catch |err| {
            std.log.err("{s}", .{@errorName(err)});
            return error.ScheduledTickFailed;
        };
    }

    fn dispatch(self: Main, args: []const []const u8) !void {
        const cmd = args[0];
        const params = args[1..];
        if (eq(u8, cmd, "followup") and params.len > 0 and eq(u8, params[0], "status"))
            return self.followupStatus(try self.db.load(), params[1..]);
        if (eq(u8, cmd, "status")) {
            var state = try self.db.load();
            return self.status(&state, params);
        }
        if (eq(u8, cmd, "result")) {
            if (params.len != 2) return error.Usage;
            var state = try self.db.load();
            const entry = state.find(params[0]) orelse return error.UnknownRepository;
            const candidate = try self.db.readResult(entry.repo.name, try prNumber(params[1]));
            return self.out("{s}\n", .{candidate});
        }
        if (eq(u8, cmd, "usage") and params.len == 0) {
            const state = try self.db.load();
            return self.showUsage(&state, try usage_meter.load(self.a, self.db.dir, std.time.timestamp()));
        }
        if (eq(u8, cmd, "defaults") and params.len == 0) {
            var state = try self.db.load();
            return self.defaults(&state, params);
        }
        if (eq(u8, cmd, "queue-budget") and params.len == 0) {
            const state = try self.db.load();
            return self.showQueueBudget(state.queue_budget);
        }
        if (eq(u8, cmd, "pause") or eq(u8, cmd, "resume")) {
            if (params.len != 1) return error.Usage;
            var state = try self.db.load();
            const entry = state.find(params[0]) orelse return error.UnknownRepository;
            const pause = eq(u8, cmd, "pause");
            try self.db.setPaused(entry.repo.name, pause);
            return self.out("{s} {s}\n", .{ if (pause) "Paused" else "Resumed", entry.repo.name });
        }
        if (eq(u8, cmd, "install") or eq(u8, cmd, "remove")) {
            const label = if (params.len == 0) launchd.default_label else if (params.len == 2 and eq(u8, params[0], "--label")) params[1] else return error.Usage;
            const env = try pick(self.a, self.env, &common_env);
            return launchd.manage(self.local(null).command(&env), self.home, self.env.get("PATH") orelse "/usr/bin:/bin", self.db.path, label, eq(u8, cmd, "install"));
        }
        const lock = self.db.lock() catch |err| {
            if (err == error.AlreadyRunning and eq(u8, cmd, "tick")) return;
            return err;
        };
        defer lock.close();
        if (eq(u8, cmd, "tick") and params.len == 0) return self.scheduledTick();
        var state = try self.db.load();
        if (eq(u8, cmd, "add")) return self.add(&state, params);
        if (eq(u8, cmd, "followup")) return self.followupCommand(&state, params);
        if (eq(u8, cmd, "defaults")) return self.defaults(&state, params);
        if (eq(u8, cmd, "queue-budget")) return self.setQueueBudget(&state, params);
        if (eq(u8, cmd, "usage") and params.len == 2) {
            const engine = std.meta.stringToEnum(core.Engine, params[0]) orelse return error.UnknownReviewer;
            var current = try usage_meter.load(self.a, self.db.dir, std.time.timestamp());
            current.get(engine).limit = std.fmt.parseUnsigned(u32, params[1], 10) catch return error.InvalidProviderBudget;
            try usage_meter.save(self.db.dir, current);
            return self.showUsage(&state, current);
        }
        if (eq(u8, cmd, "run-once")) return self.withUsage(&state, params);
        if (eq(u8, cmd, "stack")) return self.registerStack(&state, params);
        if (eq(u8, cmd, "unstack") and params.len == 2) {
            const entry = state.find(params[0]) orelse return error.UnknownRepository;
            try stack.remove(entry, self.a, params[1]);
            try self.db.save(&state);
            return self.out("Removed {s} stack {s}\n", .{ entry.repo.name, params[1] });
        }
        if (eq(u8, cmd, "queue") and params.len >= 2) {
            const options = if (params.len > 2) try reviewOptions(params[2..], true) else null;
            const entry = state.find(params[0]) orelse return error.UnknownRepository;
            const pull = try self.choose(entry, try prNumber(params[1]));
            try entry.queue(self.a, pull, options);
            try self.db.save(&state);
            for (entry.jobs) |job| {
                if (job.number != pull.number or !eq(u8, job.head, pull.headRefOid)) continue;
                if (job.phase == .uncertain) return self.out("Queued receipt reconciliation for {s} #{d} at {s}{s}\n", .{
                    entry.repo.name,                                                           job.number, job.head,
                    if (options != null) ". Review options apply only to new reviews" else "",
                });
                if (job.phase == .complete) return self.out("Already reviewed {s} #{d} at {s}\n", .{ entry.repo.name, job.number, job.head });
                break;
            }
            return self.out("Selected {s} #{d} at {s}\n", .{ entry.repo.name, pull.number, pull.headRefOid });
        }
        return error.Usage;
    }
};

fn reviewerTool(engine: core.Engine) Tool {
    return switch (engine) {
        .codex => .codex,
        .claude => .claude,
        .kimi => .kimi,
    };
}

fn reviewerProfile(repo: core.Repo, engine: core.Engine) runner.Profile {
    return .{
        .model = repo.modelFor(engine),
        .effort = repo.reviewer_efforts.get(engine),
        .advisor = if (engine == .claude and repo.claude_advisor == .fable) "fable" else null,
    };
}

const parseEngines = repo_config.parseEngines;

fn engineNames(a: A, engines: []const core.Engine) ![]const u8 {
    var names: [core.engine_count][]const u8 = undefined;
    try core.validateEngines(engines);
    for (engines, 0..) |engine, index| names[index] = @tagName(engine);
    return std.mem.join(a, ",", names[0..engines.len]);
}

fn repoName(a: A, name: []const u8) ![]const u8 {
    if (!core.validRepoName(name)) return error.InvalidRepository;
    return std.ascii.allocLowerString(a, name);
}

fn prNumber(arg: []const u8) !u32 {
    const number = std.fmt.parseUnsigned(u32, arg, 10) catch return error.InvalidPullRequest;
    if (number == 0 or number > std.math.maxInt(i32)) return error.InvalidPullRequest;
    return number;
}

fn formatTime(a: A, timestamp: i64) ![]const u8 {
    if (timestamp <= 0) return "never";
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const day = seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    return io.fmt(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,          month_day.month.numeric(), month_day.day_index + 1,
        time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
    });
}

fn start(a: A) !void {
    _ = std.c.umask(0o077);
    const argv = try std.process.argsAlloc(a);
    var args: []const []const u8 = argv[1..];
    const env = try std.process.getEnvMap(a);
    const home = env.get("HOME") orelse return error.HomeNotSet;
    var root = env.get("TALOS_HOME") orelse try std.fs.path.join(a, &.{ home, ".local", "state", "talos" });
    if (args.len >= 2 and eq(u8, args[0], "--home")) {
        root = args[1];
        args = args[2..];
    }
    if (args.len == 0 or eq(u8, args[0], "--help") or eq(u8, args[0], "-h")) return io.out("{s}\n", .{usage});
    var db = try store.Store.open(a, root);
    defer db.dir.close();
    const scratch = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(scratch) catch {};
    var dir = try std.fs.openDirAbsolute(scratch, .{ .iterate = true });
    defer dir.close();
    const app: Main = .{ .a = a, .env = &env, .home = home, .db = db, .scratch = scratch, .scratch_dir = dir };
    return app.dispatch(args);
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    start(arena.allocator()) catch |err| {
        if (err != error.ScheduledTickFailed) std.log.err("{s}", .{@errorName(err)});
        if (err == error.Usage)
            std.log.err("See talos --help", .{});
        std.process.exit(1);
    };
}

test {
    _ = @import("cache.zig");
    _ = @import("github.zig");
    _ = @import("source.zig");
    _ = @import("runner.zig");
    _ = @import("log_retention.zig");
    _ = @import("tests.zig");
}

test "each reviewer combination registers with only its selected executables" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var db = try store.Store.open(a, path);
    defer db.dir.close();
    const cases = [_]struct { flag: []const u8, engines: []const core.Engine }{
        .{ .flag = "claude", .engines = &.{.claude} },
        .{ .flag = "codex", .engines = &.{.codex} },
        .{ .flag = "kimi", .engines = &.{.kimi} },
        .{ .flag = "claude,codex", .engines = &.{ .claude, .codex } },
        .{ .flag = "codex,kimi", .engines = &.{ .codex, .kimi } },
        .{ .flag = "claude,kimi", .engines = &.{ .claude, .kimi } },
        .{ .flag = "kimi,codex,claude", .engines = &.{ .kimi, .codex, .claude } },
    };
    var env = std.process.EnvMap.init(a);
    const output = try db.dir.createFile("output", .{});
    defer output.close();
    const app: Main = .{ .a = a, .db = db, .env = &env, .home = path, .scratch = path, .scratch_dir = db.dir, .output = output };
    for (cases, 0..) |case, index| {
        const bin_name = try io.fmt(a, "bin-{d}", .{index});
        try db.dir.makeDir(bin_name);
        var bin = try db.dir.openDir(bin_name, .{});
        defer bin.close();
        try env.put("PATH", try bin.realpathAlloc(a, "."));
        try writeExecutable(bin, "git", "#!/bin/sh\nexit 1\n");
        try writeExecutable(bin, "gh",
            \\#!/bin/sh
            \\case "$4" in
            \\  user) printf '%s' '{"login":"test"}' ;;
            \\  graphql) printf '%s' '[{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}]' ;;
            \\  *) exit 1 ;;
            \\esac
            \\
        );
        for (case.engines) |engine| try writeExecutable(bin, @tagName(engine), "#!/bin/sh\nexit 1\n");
        const name = try io.fmt(a, "example/repo-{d}", .{index});
        try app.dispatch(&.{ "defaults", "--engine", case.flag });
        try app.dispatch(&.{ "add", name });
        var state = try db.load();
        try t.expectEqualSlices(core.Engine, case.engines, state.default_engines);

        try app.dispatch(&.{ "defaults", "--engine", "codex,kimi,claude" });
        try app.dispatch(&.{ "add", name, "--interval", "240" });
        state = try db.load();
        const configured = state.find(name).?.repo;
        try t.expectEqualSlices(core.Engine, case.engines, try configured.engines(a));
        const tools = app.local(configured);
        for (case.engines) |engine| {
            try t.expectEqualStrings(try bin.realpathAlloc(a, @tagName(engine)), try tools.bin(reviewerTool(engine)));
        }
        try t.expectEqual(@as(u32, 240), configured.interval);
    }
    try app.dispatch(&.{
        "add",              "example/models",   "--engine",          "claude,codex,kimi",
        "--model",          "primary-model",    "--reviewer-model",  "codex=second-model",
        "--reviewer-model", "kimi=third-model", "--reviewer-effort", "kimi=max",
        "--claude-advisor", "off",
    });
    try app.dispatch(&.{ "add", "example/models", "--reviewer-model", "kimi=new-third-model" });
    var state = try db.load();
    const modeled = state.find("example/models").?.repo;
    try t.expectEqualStrings("primary-model", modeled.modelFor(.claude).?);
    try t.expectEqualStrings("second-model", modeled.modelFor(.codex).?);
    try t.expectEqualStrings("new-third-model", modeled.modelFor(.kimi).?);
    try t.expectEqual(core.ReviewEffort.high, modeled.reviewer_efforts.get(.codex));
    try t.expectEqual(core.ReviewEffort.max, modeled.reviewer_efforts.get(.kimi));
    const tools = app.local(modeled);
    const kimi_env = try tools.reviewerEnv(.kimi, modeled.kimi, reviewerProfile(modeled, .kimi));
    try t.expectEqualStrings("max", kimi_env.get("KIMI_MODEL_THINKING_EFFORT").?);
    try t.expect(kimi_env.get("CLAUDE_CODE_DISABLE_ADVISOR_TOOL") == null);
    const claude_env = try tools.reviewerEnv(.claude, modeled.claude, reviewerProfile(modeled, .claude));
    try t.expectEqualStrings("1", claude_env.get("CLAUDE_CODE_DISABLE_ADVISOR_TOOL").?);
    try t.expectEqualStrings("1", claude_env.get("CLAUDE_CODE_DISABLE_FAST_MODE").?);
    try t.expect(claude_env.get("KIMI_MODEL_THINKING_EFFORT") == null);
    const default_kimi_env = try tools.reviewerEnv(.kimi, modeled.kimi, .{});
    try t.expectEqualStrings("high", default_kimi_env.get("KIMI_MODEL_THINKING_EFFORT").?);
    try t.expectError(error.InvalidReviewerEffort, app.dispatch(&.{
        "add", "example/models", "--reviewer-effort", "kimi=medium",
    }));
    try t.expectError(error.ReviewerModelForUnselectedEngine, app.dispatch(&.{
        "add", "example/models", "--engine", "claude", "--reviewer-model", "kimi=model",
    }));
    try t.expectError(error.DuplicateReviewer, parseEngines(a, "claude,claude"));
    try t.expectError(error.UnknownReviewer, parseEngines(a, "claude,"));
}

fn writeExecutable(dir: std.fs.Dir, name: []const u8, contents: []const u8) !void {
    const file = try dir.createFile(name, .{ .mode = 0o700 });
    defer file.close();
    try file.writeAll(contents);
}

test "a budget-deferred ensemble gets first turn after reload" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var db = try store.Store.open(a, path);
    defer db.dir.close();
    const commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const prior =
        "{\"id\":1,\"commit_id\":\"" ++ commit ++ "\",\"state\":\"COMMENTED\",\"user\":{\"login\":\"test\"},\"body\":null}";
    try writeExecutable(db.dir, "gh", "#!/bin/sh\ncase \"$4\" in\n" ++
        "  user) printf '%s' '{\"login\":\"test\"}' ;;\n" ++
        "  *'/reviews?per_page=100') printf '%s' '[[" ++ prior ++ "]]' ;;\n" ++
        "  *'/reviews/1') printf '%s' '" ++ prior ++ "' ;;\n" ++
        "  *) exit 1 ;;\nesac\n");
    const gh = try db.dir.realpathAlloc(a, "gh");
    const quiet_until = std.math.maxInt(i64);
    var light_jobs = [_]core.Job{
        .{ .number = 1, .head = commit },
        .{ .number = 2, .head = commit },
    };
    var heavy_jobs = [_]core.Job{.{ .number = 3, .head = commit }};
    var tail_jobs = [_]core.Job{.{ .number = 4, .head = commit }};
    const repos = [_]core.Repo{
        .{ .name = "test/light", .login = "test", .gh = gh, .git = "/usr/bin/true", .comments = true },
        .{ .name = "test/heavy", .login = "test", .gh = gh, .git = "/usr/bin/true", .comments = true, .additional_engines = &.{ .claude, .kimi } },
        .{ .name = "test/tail", .login = "test", .gh = gh, .git = "/usr/bin/true", .comments = true },
    };
    var entries = [_]core.Entry{
        .{ .repo = repos[0], .jobs = &light_jobs, .next_scan = quiet_until, .next_cache_check = quiet_until },
        .{ .repo = repos[1], .jobs = &heavy_jobs, .next_scan = quiet_until, .next_cache_check = quiet_until },
        .{ .repo = repos[2], .jobs = &tail_jobs, .next_scan = quiet_until, .next_cache_check = quiet_until },
    };
    const env = std.process.EnvMap.init(a);
    const app: Main = .{ .a = a, .db = db, .env = &env, .home = path, .scratch = path, .scratch_dir = db.dir };
    try db.save(&.{ .entries = &entries, .queue_budget = .{ .limit = 3 } });
    try t.expectError(error.ReviewBudgetTooSmall, app.dispatch(&.{ "queue-budget", "2" }));
    try app.dispatch(&.{"tick"});
    const first = try db.load();
    try t.expectEqual(@as(usize, 1), first.queue_budget.next_repo);
    try t.expectEqual(core.Phase.complete, first.entries[0].jobs[0].phase);
    try t.expectEqual(core.Phase.pending, first.entries[1].jobs[0].phase);
    try t.expectEqual(core.Phase.complete, first.entries[2].jobs[0].phase);
    try t.expectEqual(core.Phase.complete, first.entries[0].jobs[1].phase);
    try t.expectEqual(@as(u32, 9), first.queue_budget.last_tick.github_commands);
    try t.expectEqual(@as(u32, 0), first.queue_budget.last_tick.reviewer_starts);
    try app.dispatch(&.{"tick"});
    const second = try db.load();
    try t.expectEqual(core.Phase.complete, second.entries[1].jobs[0].phase);
    try t.expectEqual(@as(u32, 3), second.queue_budget.last_tick.github_commands);
}

test "numbered preview accepts each mode and one operator prompt" {
    const t = std.testing;
    for (std.meta.tags(core.ReviewFocus)) |mode| {
        const options = try Main.reviewOptions(&.{ "--prompt", "Review the allocator path.", "--mode", @tagName(mode) }, false);
        try t.expectEqual(mode, options.focus);
        try t.expectEqualStrings("Review the allocator path.", options.request.?);
    }
    try t.expectError(error.InvalidReviewMode, Main.reviewOptions(&.{ "--mode", "unknown" }, false));
    try t.expectError(error.Usage, Main.reviewOptions(&.{ "--mode", "general", "--mode", "general" }, false));
    try t.expectError(error.Usage, Main.reviewOptions(&.{"--prompt"}, false));
    try t.expectError(error.InvalidReviewPrompt, Main.reviewOptions(&.{ "--prompt", "  " }, false));
    try t.expectError(error.Usage, Main.reviewOptions(&.{ "--prompt", "Check retries.", "--publish" }, false));
    try t.expectError(error.Usage, Main.reviewOptions(&.{"--publish"}, true));
    try t.expect((try Main.reviewOptions(&.{ "--publish", "--prompt", "Check retries." }, true)).publish_prompted);
}

test "review workers overlap and use separate scratch directories" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    const program =
        \\#!/bin/sh
        \\set -eu
        \\cd -P .
        \\printf '%s' "$PWD" > "$HOME/${0##*/}.cwd"
        \\i=0
        \\while [ ! -s "$HOME/one.cwd" ] || [ ! -s "$HOME/two.cwd" ]; do
        \\    [ "$i" -lt 100 ] || exit 1
        \\    i=$((i + 1))
        \\    sleep 0.05
        \\done
        \\while [ "$1" != "--output-last-message" ]; do shift; done
        \\printf '%s' '{"complete":true,"summary":"Fixture","findings":[],"existing_open_findings":[],"non_blocking_threads":[]}' > "$2"
    ;
    var env = std.process.EnvMap.init(a);
    try env.put("HOME", path);
    try env.put("PATH", "/usr/bin:/bin");
    var batch: ReviewBatch = .{ .starts_left = 2, .receipts_left = 2 };
    var workers: [2]ReviewWorker = undefined;
    defer batch.deinit();
    for (&workers, [_][]const u8{ "one", "two" }) |*work, name| {
        try writeExecutable(dir, name, program);
        const repo: core.Repo = .{ .name = "test/repo", .login = "test", .codex = try dir.realpathAlloc(a, name) };
        work.* = .{ .job = undefined, .batch = &batch };
        work.adapter.repo = repo;
        work.adapter.tools = .{ .a = a, .env = &env, .scratch = path, .scratch_dir = dir, .programs = Programs.fromRepo(repo) };
        work.prepared.engines = &.{.codex};
        work.prepared.context = "review";
        work.thread = try std.Thread.spawn(.{}, ReviewWorker.analyze, .{work});
        batch.workers[batch.len] = work;
        batch.len += 1;
    }
    for (&workers) |*work| {
        work.thread.?.join();
        work.thread = null;
        const results = try work.result;
        try t.expectEqualStrings("Fixture", results[0].review.summary);
        try t.expectEqual(@as(u32, 1), work.counts.reviewer_starts);
    }
    const one = try dir.readFileAlloc(a, "one.cwd", 4096);
    const two = try dir.readFileAlloc(a, "two.cwd", 4096);
    try t.expect(!eq(u8, one, two));
    try t.expectError(error.FileNotFound, std.fs.accessAbsolute(one, .{}));
    try t.expectError(error.FileNotFound, std.fs.accessAbsolute(two, .{}));
}

test "reviewer cooldown applies to the remaining ensemble" {
    const engines = &.{ .codex, .claude, .kimi };
    try std.testing.expect(!ReviewWorker.remainingLimited(engines, .claude, queue.engineBit(.codex)));
    try std.testing.expect(ReviewWorker.remainingLimited(engines, .claude, queue.engineBit(.claude)));
    try std.testing.expect(ReviewWorker.remainingLimited(engines, .claude, queue.engineBit(.kimi)));
}
