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
const onchain = @import("onchain.zig");
const telemetry = @import("telemetry.zig");
const max_metrics_days = 3650;
const dashboard = @import("dashboard.zig");
const dashboard_data = @import("dashboard_data.zig");

const eq = io.eq;
const A = io.A;
const usage =
    \\Talos tracks open GitHub pull requests and reviews new commits.
    \\
    \\talos [--home DIR] add OWNER/REPO [options]
    \\talos [--home DIR] defaults [--engine ENGINE[,ENGINE...]]
    \\talos [--home DIR] status [OWNER/REPO] [--json]
    \\talos [--home DIR] result OWNER/REPO PR
    \\talos [--home DIR] queue-budget [STARTS]
    \\talos [--home DIR] usage [ENGINE DAILY_STARTS]
    \\talos [--home DIR] metrics [--days DAYS] [--offset DAYS]
    \\talos [--home DIR] dashboard [install|remove] [--port PORT]
    \\talos [--home DIR] queue OWNER/REPO PR [--all-maxxing] [--mode MODE ...] [--prompt TEXT [--publish]]
    \\talos [--home DIR] followup THREAD_URL [--dry-run | --merge-when-ready]
    \\talos [--home DIR] followup status [--json]
    \\talos [--home DIR] followup pause|resume THREAD_URL
    \\talos [--home DIR] stack OWNER/REPO STACK_NUMBER [--all-maxxing [--rerun]]
    \\talos [--home DIR] stack OWNER/REPO NAME PR PR [PR ...]
    \\talos [--home DIR] unstack OWNER/REPO NAME
    \\talos [--home DIR] run-once [OWNER/REPO [PR [--mode MODE ...] [--prompt TEXT]]]
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
    telemetry: ?telemetry.Recorder = null,
    pass_store: ?store.Store = null,
    slots: ?*runner.ProviderSlots = null,
    started: ?*std.atomic.Value(u32) = null,

    fn forStage(self: Local, stage: telemetry.Stage, depth: ?routing.Depth) Local {
        var tools = self;
        if (tools.telemetry) |*recorder| {
            recorder.scope.stage = stage;
            recorder.scope.route = depth orelse recorder.scope.route;
        }
        return tools;
    }

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
            .github_calls = if (self.counts) |counts| &counts.github_commands else null,
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
    diff_priority: ?[]const []const u8 = null,

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

    pub fn snapshot(self: *Adapter, pr: core.Pull, threads: []const core.Thread) !core.Snapshot {
        self.files = try self.github_client.files(pr.number);
        var git = self.git_source;
        git.diff_priority = self.diff_priority;
        return git.snapshot(pr, self.files, threads);
    }

    pub fn supplement(self: *Adapter, pr: core.Pull, previous: ?[]const u8, requests: []const core.EvidenceRequest) !source.Supplement {
        return self.git_source.supplement(pr, previous, requests);
    }

    fn reviewEvidence(self: *Adapter, pr: core.Pull, requests: []const core.EvidenceRequest, capacity: usize) !adaptive.PinnedEvidence {
        if (capacity == 0) return .{ .limited = true };
        return fitEvidence(self.db.a, try self.supplement(pr, null, requests), capacity);
    }

    fn fitEvidence(a: A, supplement_result: source.Supplement, capacity: usize) !adaptive.PinnedEvidence {
        var remaining = capacity -| 2; // JSON string delimiters.
        var limited = supplement_result.limited;
        var excerpts: std.ArrayList(u8) = .empty;
        var provided: std.ArrayList(core.EvidenceRequest) = .empty;
        for (supplement_result.excerpts) |provided_excerpt| {
            const excerpt = supplement_result.evidence[provided_excerpt.start_offset..provided_excerpt.end_offset];
            const encoded = try io.json(a, excerpt);
            defer a.free(encoded);
            if (encoded.len - 2 > remaining) {
                limited = true;
                continue;
            }
            remaining -= encoded.len - 2;
            try excerpts.appendSlice(a, excerpt);
            try provided.append(a, provided_excerpt.request);
        }
        if (supplement_result.omissions.len != 0) {
            const encoded = try io.json(a, supplement_result.omissions);
            defer a.free(encoded);
            if (encoded.len - 2 <= remaining) try excerpts.appendSlice(a, supplement_result.omissions);
        }
        return .{
            .source = excerpts.items,
            .provided = provided.items,
            .limited = limited,
        };
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
        if (target.number != pr.number or !target.reviewable() or !eq(u8, target.headRefOid, pr.headRefOid) or !eq(u8, target.baseRefOid, pr.baseRefOid))
            return error.StackChanged;
        const parent_count = pins.len - 1;
        const detail_start = parent_count -| stack.context_members;
        const ancestors = try self.db.a.alloc(stack.Ancestor, parent_count - detail_start);
        for (prefix, pins, 0..) |member, pin, index| {
            if (member.pin.number != pin.number or (item.native == null and pin.nativeStack != null)) return error.StackChanged;
            if (!preview and !stack.samePin(member.pin, pin)) return error.StackChanged;
            if (pin.state != .MERGED and !pin.reviewable()) return error.StackChanged;
            if (item.native == null and index > 0 and pin.state != .MERGED and pins[index - 1].state != .MERGED and
                !stack.linked(self.repo.name, pins[index - 1], pin)) return error.StackChanged;
        }
        for (prefix[detail_start..parent_count], pins[detail_start..parent_count], ancestors) |member, pin, *ancestor| {
            const merged_pin = pin.state == .MERGED and eq(u8, pin.headRefOid, member.pin.headRefOid);
            const base = if (merged_pin) member.diff_base else pin.baseRefOid;
            var ancestor_pr = pin.pull();
            ancestor_pr.baseRefOid = base;
            const stored_digest = if (merged_pin or stack.samePin(member.pin, pin)) member.digest else null;
            const digest = stored_digest orelse digest: {
                const snapshot_value = try self.git_source.snapshot(ancestor_pr, &.{}, &.{});
                break :digest try stack.Digest.make(self.db.a, snapshot_value.evidence, try self.ancestorReview(pin));
            };
            ancestor.* = .{
                .number = pin.number,
                .head = pin.headRefOid,
                .base = base,
                .state = @tagName(pin.state),
                .diff_excerpt = digest.diff,
                .review_excerpt = digest.findings,
                .stored_digest = stored_digest != null,
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
        if (pin.nativeStack != null or !pin.reviewable() or !eq(u8, pin.headRefOid, target.headRefOid) or
            !eq(u8, pin.baseRefOid, target.baseRefOid)) return error.StackChanged;
    }

    pub fn saveStackContext(self: *Adapter, pr: core.Pull, snap: core.Snapshot, payload: core.Payload) !void {
        const position = stack.find(self.entry.stacks, pr.number) orelse return;
        const member = &self.entry.stacks[position.stack_index].members[position.member_index];
        var digest = try stack.Digest.make(self.db.a, snap.evidence, payload);
        digest.diff = try self.db.a.dupe(u8, digest.diff);
        member.digest = digest;
    }

    pub fn anchor(self: *Adapter, _: core.Pull, _: core.Snapshot, path: []const u8, line: u32) !bool {
        return source.anchor(self.files, path, line);
    }

    pub fn review(self: *Adapter, engine: core.Engine, prompt: []const u8) ![]const u8 {
        return runReviewer(self.tools, self.repo, engine, prompt);
    }

    fn onchainReads(self: *Adapter, pr: core.Pull, reads: []const onchain.Request) ![]const onchain.Observation {
        if (reads.len == 0) return &.{};
        return self.git_source.onchainReads(pr, reads, self.tools.env.get("PATH") orelse "/usr/bin:/bin");
    }

    fn previewReads(self: *Adapter, prepared: core.Prepared) ![]const onchain.Observation {
        if (prepared.onchain_available and prepared.snap.onchain_reads.len != 0) return self.onchainReads(prepared.pr, prepared.snap.onchain_reads);
        if (!prepared.onchain_available or self.repo.light_models.len == 0) return &.{};
        const screen = routing.inspect(self.files, prepared.snap.limited);
        if (!screen.ask_model and screen.floor.depth != .multi) return &.{};
        const a = self.db.a;
        const prompt = try core.screenPrompt(a, prepared);
        if (prompt.len > core.review_context_limit) return &.{};
        for (self.repo.light_models) |reviewer| {
            const response = invokeReviewer(self.tools.forStage(.screen, null), reviewer.engine, .{ .model = reviewer.model, .effort = .default }, core.screen_schema, prompt) catch continue;
            const result = core.parseScreen(a, response) catch continue;
            return self.onchainReads(prepared.pr, result.onchain_reads);
        }
        return &.{};
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

    pub fn saveResult(self: *Adapter, number: u32, result: core.Result) !void {
        try self.db.result(self.repo.name, number, result);
    }

    pub fn confirmResult(self: *Adapter, number: u32, head: []const u8, followup_id: []const u8, event: core.Event, id: u64) !void {
        try self.db.confirmResult(self.repo.name, number, head, followup_id, event, id);
    }

    pub fn saveResultAndState(self: *Adapter, number: u32, candidate: core.Result) !void {
        return self.db.saveResultAndState(self.repo.name, number, candidate, self.state);
    }

    pub fn confirmResultAndState(self: *Adapter, number: u32, head: []const u8, followup_id: []const u8, event: core.Event, id: u64) !void {
        return self.db.confirmResultAndState(self.repo.name, number, head, followup_id, event, id, self.state);
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
        .telemetry = tools.telemetry,
        .pass_store = tools.pass_store,
        .slots = tools.slots,
        .starts = if (tools.counts) |counts| &counts.reviewer_starts else null,
        .started = tools.started,
    };
    return reviewer.review(prompt);
}

const ReviewBatch = struct {
    starts_left: u32,
    receipts_left: u32,
    carried_deficit: u32 = 0,
    meter: ?*usage_meter.Ledger = null,
    slots: runner.ProviderSlots = .{},
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
            work.destroy();
        }
    }

    fn deferRepo(self: *ReviewBatch, index: usize) void {
        if (self.deferred_repo == null) self.deferred_repo = index;
    }

    fn renewBudget(self: *ReviewBatch, limit: u32) void {
        var unspent: u32 = 0;
        for (self.workers[0..self.len]) |work| {
            unspent += work.reservation - work.started.load(.monotonic);
        }
        self.starts_left = limit -| unspent;
        self.carried_deficit = unspent -| limit;
        self.receipts_left = limit;
    }

    fn releaseStarts(self: *ReviewBatch, unused: u32) void {
        const retired = @min(self.carried_deficit, unused);
        self.carried_deficit -= retired;
        self.starts_left += unused - retired;
    }
};

const PreviewReviewer = struct {
    adapter: *Adapter,

    pub fn available(_: PreviewReviewer, _: core.Engine) bool {
        return true;
    }

    pub fn starts(_: PreviewReviewer) u32 {
        return 0;
    }

    pub fn routeReview(self: PreviewReviewer, engine: core.Engine, _: ?[]const u8, schema: []const u8, prompt: []const u8) ![]const u8 {
        return invokeReviewer(self.adapter.tools, engine, reviewerProfile(self.adapter.repo, engine), schema, prompt);
    }

    pub fn routePass(self: PreviewReviewer, request: adaptive.FullPass) ![]const u8 {
        const tools = self.adapter.tools.forStage(if (request.completion) .completion else .preview, request.depth);
        return invokeReviewer(tools, request.engine, reviewerProfile(self.adapter.repo, request.engine), core.schema, request.prompt);
    }
};

fn limitedEngine(err: anyerror) ?core.Engine {
    return switch (err) {
        error.CodexRateLimited => .codex,
        error.ClaudeRateLimited => .claude,
        error.KimiRateLimited => .kimi,
        else => null,
    };
}

const ParallelPass = struct {
    worker: *const ReviewWorker,
    request: adaptive.FullPass,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    counts: queue.TickCounts = .{},
    output: anyerror![]const u8 = undefined,

    fn run(self: *ParallelPass) void {
        self.output = self.runInScratch();
        if (self.output) |_| {} else |err| {
            if (limitedEngine(err)) |engine| _ = self.worker.batch.limited.fetchOr(queue.engineBit(engine), .monotonic);
        }
    }

    fn runInScratch(self: *ParallelPass) ![]const u8 {
        var tools = self.worker.tools.forStage(if (self.request.completion) .completion else .review, self.request.depth);
        tools.a = self.arena.allocator();
        tools.counts = &self.counts;
        const name = @tagName(self.request.engine);
        tools.scratch = try std.fs.path.joinZ(tools.a, &.{ tools.scratch, name });
        const parent = tools.scratch_dir;
        tools.scratch_dir = try parent.makeOpenPath(name, .{});
        defer parent.deleteTree(name) catch {};
        defer tools.scratch_dir.close();
        return invokeReviewer(tools, self.request.engine, self.worker.fullProfile(self.request.engine), core.schema, self.request.prompt);
    }
};

const SectionPlan = struct { index: usize, plan: adaptive.Plan };

const ReviewWorker = struct {
    // Only the coordinator uses adapter, gh_env and job. The worker borrows
    // immutable context and uses its own arena, processes and scratch directory.
    adapter: Adapter = undefined,
    gh_env: std.process.EnvMap = undefined,
    job: *core.Job,
    job_key: [32]u8 = undefined,
    prepared: core.Prepared = undefined,
    batch: *ReviewBatch,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    counts: queue.TickCounts = .{},
    tools: Local = undefined,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!core.ReviewResults = undefined,
    plan: ?adaptive.Plan = null,
    section_plans: []const SectionPlan = &.{},
    route_outcome: ?adaptive.Outcome = null,
    policy: queue.Budget = .{},
    rate_limits: u8 = 0,
    reservation: u32 = 0,
    scratch_root: ?[]const u8 = null,
    waiting_for_ancestor: bool = false,
    started: std.atomic.Value(u32) = .init(0),
    parent_started: ?*std.atomic.Value(u32) = null,

    fn destroy(self: *ReviewWorker) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn jobKey(a: A, repo: core.Repo, job: core.Job) ![32]u8 {
        const encoded = try io.json(a, .{ .repo = repo, .job = job });
        defer a.free(encoded);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
        return digest;
    }

    fn rebind(self: *ReviewWorker, a: A, state: *store.State) !bool {
        const entry = state.find(self.adapter.repo.name) orelse return false;
        for (entry.jobs) |*job| {
            if (job.number != self.prepared.pr.number or !eq(u8, job.head, self.prepared.pr.headRefOid)) continue;
            if (!eq(u8, &self.job_key, &(try jobKey(a, entry.repo, job.*)))) return false;
            self.job = job;
            self.adapter.entry = entry;
            self.adapter.state = state;
            self.adapter.db.a = a;
            return true;
        }
        return false;
    }

    fn publicationBlocked(self: *const ReviewWorker, budget: queue.Budget) bool {
        return self.waiting_for_ancestor or stack.blocked(self.adapter.entry.*, self.job.*) or
            stack.ancestorEvidenceChanged(self.adapter.entry.*, self.prepared.inherited) or
            !budget.canScan(std.time.timestamp());
    }

    pub fn available(self: *ReviewWorker, engine: core.Engine) bool {
        const now = std.time.timestamp();
        const at = self.policy.engineAt(engine, now, self.batch.limited.load(.monotonic), self.batch.usageSnapshot()) orelse return false;
        return at <= now;
    }

    pub fn starts(self: *const ReviewWorker) u32 {
        return self.counts.reviewer_starts;
    }

    fn fullProfile(self: *const ReviewWorker, engine: core.Engine) runner.Profile {
        var profile = reviewerProfile(self.adapter.repo, engine);
        if (self.prepared.all_models) {
            profile.effort = .max;
            profile.timeout_seconds = 30 * std.time.s_per_min;
        }
        return profile;
    }

    pub fn routeReview(self: *ReviewWorker, engine: core.Engine, model: ?[]const u8, schema: []const u8, prompt: []const u8) ![]const u8 {
        const profile = if (model) |light|
            runner.Profile{ .model = light, .effort = .default }
        else
            self.fullProfile(engine);
        const tools = if (model != null)
            self.tools.forStage(.screen, null)
        else if (!eq(u8, schema, core.schema))
            self.tools.forStage(.synthesis, .multi)
        else
            self.tools;
        return invokeReviewer(tools, engine, profile, schema, prompt) catch |err| {
            self.noteRateLimit(engine, err);
            return err;
        };
    }

    pub fn routePass(self: *ReviewWorker, request: adaptive.FullPass) ![]const u8 {
        const tools = self.tools.forStage(if (request.completion) .completion else .review, request.depth);
        return invokeReviewer(tools, request.engine, self.fullProfile(request.engine), core.schema, request.prompt) catch |err| {
            self.noteRateLimit(request.engine, err);
            return err;
        };
    }

    pub fn routeParallel(self: *ReviewWorker, requests: []const adaptive.FullPass, outputs: []anyerror![]const u8) !void {
        var tasks: [core.engine_count]ParallelPass = undefined;
        var threads: [core.engine_count]?std.Thread = @splat(null);
        const running = tasks[0..requests.len];
        for (running, requests, threads[0..running.len]) |*task, request, *thread| {
            task.* = .{ .worker = self, .request = request };
            thread.* = std.Thread.spawn(.{}, ParallelPass.run, .{task}) catch fallback: {
                task.run();
                break :fallback null;
            };
        }
        for (threads[0..running.len]) |thread| if (thread) |active| active.join();
        defer for (running) |*task| task.arena.deinit();
        for (running) |task| {
            self.counts.reviewer_starts += task.counts.reviewer_starts;
            if (task.output) |_| {} else |err| self.noteRateLimit(task.request.engine, err);
        }
        for (running, outputs) |task, *output| {
            output.* = if (task.output) |raw| try self.tools.a.dupe(u8, raw) else |err| err;
        }
    }

    fn noteRateLimit(self: *ReviewWorker, engine: core.Engine, err: anyerror) void {
        if (limitedEngine(err) == null) return;
        const bit = queue.engineBit(engine);
        self.rate_limits |= bit;
        _ = self.batch.limited.fetchOr(bit, .monotonic);
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
        if (self.section_plans.len != 0) {
            self.route_outcome = try self.analyzeSections();
            return undefined;
        }
        return self.analyzeSingle();
    }

    fn analyzeSingle(self: *ReviewWorker) !core.ReviewResults {
        const a = self.arena.allocator();
        const scratch = if (self.scratch_root) |root| try io.tempIn(a, root) else try io.temp(a);
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
            .telemetry = self.adapter.tools.telemetry,
            .pass_store = if (self.adapter.tools.telemetry != null) self.adapter.db else null,
            .slots = &self.batch.slots,
            .started = self.parent_started orelse &self.started,
        };
        if (self.plan) |plan| {
            if (self.tools.telemetry) |*recorder| {
                if (plan.prepared.sections.len != 0 and !plan.prepared.context_update)
                    recorder.scope.section = plan.progress.sections.index + 1;
            }
            self.route_outcome = try adaptive.run(a, self, plan);
            return undefined;
        }
        return core.analyze(a, self, self.prepared.engines, self.prepared.context);
    }

    fn analyzeSectionWorker(self: *ReviewWorker) void {
        self.result = self.analyzeSingle();
    }

    fn analyzeSections(self: *ReviewWorker) !adaptive.Outcome {
        var workers: [queue.parallel_sections]ReviewWorker = undefined;
        var threads: [queue.parallel_sections]?std.Thread = @splat(null);
        const count = self.section_plans.len;
        const active = workers[0..count];
        for (active, self.section_plans, threads[0..count]) |*worker, section, *thread| {
            worker.* = .{
                .job = undefined,
                .adapter = self.adapter,
                .batch = self.batch,
                .prepared = section.plan.prepared,
                .plan = section.plan,
                .policy = self.policy,
                .scratch_root = self.scratch_root,
                .parent_started = &self.started,
            };
            if (worker.adapter.tools.telemetry) |*recorder| recorder.scope.section = section.index + 1;
            if (count == 1) {
                worker.analyzeSectionWorker();
            } else {
                thread.* = std.Thread.spawn(.{}, ReviewWorker.analyzeSectionWorker, .{worker}) catch fallback: {
                    worker.analyzeSectionWorker();
                    break :fallback null;
                };
            }
        }
        for (threads[0..count]) |thread| if (thread) |running| running.join();
        defer for (active) |*worker| worker.arena.deinit();
        var results: [queue.parallel_sections]adaptive.SectionOutcome = undefined;
        for (active, self.section_plans, results[0..count]) |worker, section, *result| {
            self.counts.reviewer_starts += worker.counts.reviewer_starts;
            self.rate_limits |= worker.rate_limits;
            result.* = .{
                .task = .{ .index = section.index, .progress = section.plan.progress },
                .review = if (worker.result) |_| worker.route_outcome.? else |err| .{ .progress = section.plan.progress, .failure = err },
            };
        }
        const a = self.arena.allocator();
        var outcome = try adaptive.mergeParallelSections(a, self.plan.?, results[0..count]);
        // Child arenas own raw reviewer output. Keep only the merged state.
        outcome.progress = try io.parse(a, core.RouteProgress, try io.json(a, outcome.progress));
        if (outcome.review_results != null) {
            outcome.review_results = outcome.progress.sections.results;
            outcome.synthesis_summary = outcome.progress.sections.synthesis_gap;
        }
        return outcome;
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
        var tools = self.app.local(self.repo);
        tools.telemetry = .{ .dir = self.app.db.dir, .scope = .{
            .repo = self.repo.name,
            .pr = source_pr.number,
            .head = source_pr.headRefOid,
            .mode = .followup,
            .stage = .followup,
        } };
        const answer = try invokeReviewer(tools, engine, reviewerProfile(self.repo, engine), followup.schema, prompt);
        const change = try followup.proposal(a, answer);
        if (change.action != .fix) return .{ .head = parent, .change = change };
        const revised = try followup.edit(a, file.text, change);
        const title = if (feedback_run) "fix: address followup review feedback" else try io.fmt(a, "fix: {s}", .{change.title});
        const head = self.work.commit(job, parent, file.mode, revised, title) catch |err| switch (err) {
            error.FollowupContextLimit => return .{ .head = parent, .change = .{
                .action = .needs_input,
                .title = "",
                .note = "The edited file would exceed the followup size limit.",
                .before = "",
                .after = "",
            } },
            else => return err,
        };
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

    pub fn mergeActive(self: *FollowupService, number: u32) !bool {
        return self.client.followupMergeActive(number);
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
            const pulls = try client.openPulls();
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
            try self.out("Added {s} as {s} with {d} open PRs baselined\n", .{ name, repo.login, entry.seen.len });
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
        const repo = try io.parse(self.a, core.Repo, try io.json(self.a, entry.repo));
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
        const available = try client.openPulls();
        const pulls = if (managed.len == 0) available else tracked: {
            var unmatched: std.ArrayList(core.Pull) = .empty;
            pull_loop: for (available) |pull| {
                for (managed) |job| {
                    if (!std.ascii.eqlIgnoreCase(job.source.repo, entry.repo.name)) continue;
                    if (job.pr == pull.number) continue :pull_loop;
                    if (job.pr == null and job.stage == .drafting and pull.isDraft) {
                        const head_repo = pull.headRepository orelse continue;
                        if (std.ascii.eqlIgnoreCase(head_repo.nameWithOwner, entry.repo.name) and
                            eq(u8, pull.headRefName, try job.source.branch(self.a))) continue :pull_loop;
                    }
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
        try stack.queueActiveNativeMembers(entry, self.a);
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
                if (pull.number != job.number or !core.isReviewable(pull) or !eq(u8, pull.headRefOid, job.head)) continue;
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
        const discussion = try client.discussion(pull.number);
        const saved = job.review_input;
        const merge_base = if (saved != null and eq(u8, saved.?.base.oid, pull.baseRefOid))
            saved.?.merge_base
        else
            try client.mergeBase(pull.baseRefOid, pull.headRefOid);
        const current = try core.ReviewInput.init(self.a, repo, pull, merge_base, discussion);
        const legacy_changed = (saved == null or saved.?.material_discussion == null) and job.receipt != null and
            job.legacyDiscussionChanged(repo.login, discussion, try client.reviews(pull.number));
        job.observeReviewInput(current, legacy_changed, repo.approvals);
    }

    fn tick(self: Main, state: *store.State, lock: std.fs.File) !void {
        var counts: queue.TickCounts = .{ .at = std.time.timestamp() };
        var worker = self;
        worker.counts = &counts;
        try worker.scanDue(state, &counts);
        if (state.entries.len == 0) return;
        try worker.tickFollowup(state, &counts);
        try worker.reviewBatch(state, &counts, lock);
    }

    fn scanDue(self: Main, state: *store.State, counts: *queue.TickCounts) !void {
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
                if (self.scan(entry, state.followups)) |_| {
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
                if (counts.github_commands != 0) state.queue_budget.last_tick = counts.*;
                try self.db.save(state);
            }
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
                    followup.clearEvidence(job);
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
                job.evidence_head = parent;
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

    fn reviewBatch(self: Main, state: *store.State, counts: *queue.TickCounts, lock: std.fs.File) !void {
        const limit = state.queue_budget.limit;
        var batch: ReviewBatch = .{ .starts_left = limit -| counts.reviewer_starts, .receipts_left = limit, .meter = self.meter };
        defer batch.deinit();
        batch.slots.setLimit(limit);
        var window_limit = limit;
        var window = try std.time.Timer.start();
        const interval = 15 * std.time.ns_per_s;
        try self.admitReady(state, counts, &batch);

        while (batch.pending != 0) {
            lock.unlock();
            batch.completed.timedWait(interval -| window.read()) catch {};
            try lock.lock(.exclusive);

            var cycle = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer cycle.deinit();
            var fresh = self;
            fresh.a = cycle.allocator();
            fresh.db.a = fresh.a;
            var current = try fresh.db.load();
            const pending = batch.pending;
            try fresh.finishReady(&current, counts, &batch);
            try fresh.scanDue(&current, counts);
            batch.slots.setLimit(current.queue_budget.limit);
            const replenish = window.read() >= interval;
            if (replenish) {
                window_limit = current.queue_budget.limit;
                batch.renewBudget(window_limit);
                window.reset();
            }
            if (current.queue_budget.limit < window_limit) {
                batch.starts_left = 0;
                batch.receipts_left = @min(batch.receipts_left, current.queue_budget.limit);
            }
            const finished = pending != batch.pending;
            if (replenish or finished) try fresh.admitReady(&current, counts, &batch);
            if (finished) {
                current.queue_budget.last_tick = counts.*;
                try fresh.db.save(&current);
            }
        }
    }

    fn admitReady(self: Main, state: *store.State, counts: *queue.TickCounts, batch: *ReviewBatch) !void {
        if (state.entries.len == 0) return;
        var repos: [queue.active_repos]queue.RepoJobs = undefined;
        var active: usize = 0;
        for (batch.workers[0..batch.len]) |worker| {
            const index = for (state.entries, 0..) |entry, i| {
                if (std.ascii.eqlIgnoreCase(entry.repo.name, worker.adapter.repo.name)) break i;
            } else continue;
            const lane = for (repos[0..active]) |*prior| {
                if (prior.index == index) break prior;
            } else new: {
                repos[active] = .{ .index = index };
                active += 1;
                break :new &repos[active - 1];
            };
            lane.add(worker.prepared.pr.number);
        }

        batch.deferred_repo = null;
        const before = counts.jobs;
        const first = state.queue_budget.next_repo % state.entries.len;
        // Give each eligible repo a turn before filling its second and third slots.
        each_repo: for (0..state.entries.len) |offset| {
            const index = (first + offset) % state.entries.len;
            for (repos[0..active]) |prior| {
                if (prior.index == index) continue :each_repo;
            }
            var lane: queue.RepoJobs = .{ .index = index };
            if (!try self.admit(state, counts, batch, &lane, active < repos.len)) continue;
            repos[active] = lane;
            active += 1;
        }
        for (1..queue.jobs_per_repo) |_| {
            for (repos[0..active]) |*lane| {
                if (lane.len < queue.jobs_per_repo) _ = try self.admit(state, counts, batch, lane, true);
            }
        }
        if (batch.deferred_repo) |index| state.queue_budget.next_repo = index;
        if (counts.jobs != before) {
            state.queue_budget.last_tick = counts.*;
            try self.db.save(state);
        }
    }

    fn finishReady(self: Main, state: *store.State, counts: *queue.TickCounts, batch: *ReviewBatch) !void {
        var i: usize = 0;
        while (i < batch.len) {
            const work = batch.workers[i];
            if (!work.done.load(.acquire)) {
                i += 1;
                continue;
            }
            const thread = work.thread.?;
            thread.join();
            batch.len -= 1;
            batch.workers[i] = batch.workers[batch.len];
            batch.pending -= 1;
            defer work.destroy();
            counts.reviewer_starts += work.counts.reviewer_starts;
            batch.releaseStarts(work.reservation - work.counts.reviewer_starts);
            for (std.meta.tags(core.Engine)) |engine| {
                if (work.rate_limits & queue.engineBit(engine) == 0) continue;
                const err = switch (engine) {
                    .codex => error.CodexRateLimited,
                    .claude => error.ClaudeRateLimited,
                    .kimi => error.KimiRateLimited,
                };
                state.queue_budget.noteFailure(std.time.timestamp(), err);
            }
            if (!try work.rebind(self.a, state)) continue;
            self.finishJob(state, work) catch |err| switch (err) {
                error.ReviewerBusy, error.ReviewerCoolingDown, error.ProviderBudgetReached => {},
                else => try self.jobFailed(state, work.adapter.entry, work.job, err),
            };
            if (work.counts.reviewer_starts == 0 and work.job.phase == .pending) {
                // A saturated provider or an evidence-only step must not
                // send this job through GitHub preparation in a tight loop.
                work.job.next = @max(work.job.next, std.time.timestamp() + 15);
            }
            // Finish can adopt strings from the pinned snapshot. Keep the
            // current state usable after releasing the worker's arena.
            work.job.* = try io.parse(self.a, core.Job, try io.json(self.a, work.job.*));
        }
    }

    fn admit(self: Main, state: *store.State, counts: *queue.TickCounts, batch: *ReviewBatch, lane: *queue.RepoJobs, has_slot: bool) !bool {
        const entry = &state.entries[lane.index];
        if (try self.db.paused(entry.repo.name)) return false;
        const allow_fresh_routed = retainedCount(state) + batch.pending < queue.parallel_jobs;
        const decision = state.queue_budget.pick(entry, std.time.timestamp(), batch.starts_left, batch.receipts_left, lane.selected(), batch.limited.load(.monotonic), batch.usageSnapshot(), allow_fresh_routed);
        if (decision.budget_deferred or ((!has_slot or batch.len == batch.workers.len) and decision.job != null)) batch.deferRepo(lane.index);
        const job = decision.job orelse return false;
        if (!has_slot or batch.len == batch.workers.len) return false;
        lane.add(job.number);

        // Reserve the full ensemble before touching GitHub. Deduplicated
        // jobs still cost lookups and consume a slot for this tick.
        const reservation = if (job.phase == .uncertain) @as(u32, 0) else queue.reviewerCost(entry.repo);
        if (job.phase == .uncertain) {
            batch.receipts_left -= 1;
            counts.receipt_checks += 1;
        } else {
            batch.starts_left -= reservation;
        }
        counts.jobs += 1;
        state.queue_budget.next_repo = batch.deferred_repo orelse (lane.index + 1) % state.entries.len;
        self.startJob(state, entry, job, batch) catch |err| switch (err) {
            error.ReviewerCoolingDown => batch.starts_left += reservation,
            else => try self.jobFailed(state, entry, job, err),
        };
        return true;
    }

    fn startJob(self: Main, state: *store.State, entry: *core.Entry, job: *core.Job, batch: *ReviewBatch) !void {
        const work = try std.heap.page_allocator.create(ReviewWorker);
        work.* = .{ .job = job, .batch = batch };
        var launched = false;
        defer if (!launched) work.destroy();
        var prep = self;
        prep.a = work.arena.allocator();
        prep.db.a = prep.a;
        const prepared = prep.prepareWorker(self.a, state, entry, job, work);
        launched = work.thread != null;
        if (!launched) job.* = try io.parse(self.a, core.Job, try io.json(self.a, job.*));
        try prepared;
    }

    fn prepareWorker(self: Main, state_allocator: A, state: *store.State, entry: *core.Entry, job: *core.Job, work: *ReviewWorker) !void {
        // Preparation is coordinated, but its inputs and outputs survive
        // loading a new arena for the next scheduling round.
        const batch = work.batch;
        work.adapter = try self.adapter(entry, state, &work.gh_env);
        work.scratch_root = try std.fs.path.join(self.a, &.{ self.db.path, "review-scratch" });
        work.waiting_for_ancestor = stack.blocked(entry.*, job.*);
        const repo = work.adapter.repo;
        if (job.route_progress) |saved| {
            if (saved.sections.checkpoint) |checkpoint| {
                work.adapter.diff_priority = try io.parse(self.a, []const []const u8, try io.json(self.a, checkpoint.diff_priority));
            }
        }
        work.prepared = (try core.prepare(self.a, &work.adapter, repo, job, .scheduled)) orelse return;
        work.prepared.options = try io.parse(self.a, core.ReviewOptions, try io.json(self.a, work.prepared.options));
        if (work.prepared.inherited.pins.len != 0) {
            work.prepared.inherited = try io.parse(self.a, stack.Context, try io.json(self.a, work.prepared.inherited));
        }
        if (work.prepared.reused_results) |results| {
            if (try self.db.paused(repo.name)) return;
            if (work.publicationBlocked(state.queue_budget)) {
                try self.keepAnalysis(state, work, results);
                try self.db.save(state);
                return;
            }
            work.adapter.db.a = state_allocator;
            _ = try core.finish(state_allocator, &work.adapter, entry.repo, job, work.prepared, results);
            return;
        }
        work.prepared.all_models = work.prepared.options.all_models or
            (repo.routing_mode == .adaptive and work.prepared.options.allowRouting() and
                (routing.messageVerificationChanged(repo.name, work.adapter.files) or
                    stack.inheritsAllModels(work.prepared.inherited, entry.jobs)));
        work.adapter.tools.telemetry = .{ .dir = self.db.dir, .scope = .{
            .repo = repo.name,
            .pr = job.number,
            .head = work.prepared.pr.headRefOid,
            .review_id = try core.followupId(self.a, job.*),
            .focus = work.prepared.options.focus,
            .additional_focuses = work.prepared.options.additional_focuses,
            .section_count = if (work.prepared.sections.len != 0) work.prepared.sections.len else null,
        } };
        if (job.analysis) |saved| {
            if (try saved.matches(self.a, repo, work.prepared)) {
                if (try self.db.paused(repo.name) or work.publicationBlocked(state.queue_budget)) return;
                work.prepared.route_depth = saved.route_depth;
                work.prepared.synthesis_provider = saved.synthesis_provider;
                work.prepared.synthesis_summary = saved.synthesis_summary;
                work.prepared.additional_evidence_limited = saved.additional_evidence_limited;
                work.prepared.evidence_requests = saved.evidence_requests;
                work.prepared.onchain_observations = saved.onchain_observations;
                work.adapter.db.a = state_allocator;
                _ = try core.finish(state_allocator, &work.adapter, entry.repo, job, work.prepared, saved.results);
                return;
            }
            job.analysis = null;
            // Persist the invalidation even if the provider holds this job.
            try self.db.save(state);
        }
        work.policy = state.queue_budget;
        {
            var progress = try self.resumeReview(repo, job, &work.prepared);
            progress = try io.parse(self.a, core.RouteProgress, try io.json(self.a, progress));
            if (work.prepared.onchain_available and work.prepared.snap.onchain_reads.len != 0) progress.onchain_reads = work.prepared.snap.onchain_reads;
            const automatically_routed = repo.routing_mode != .fixed and work.prepared.options.allowRouting();
            const scoped_review = (work.prepared.snap.registry_logo_only or work.prepared.snap.relayer_promotion or
                (work.prepared.onchain_available and work.prepared.snap.onchain_reads.len != 0)) and !work.prepared.snap.limited;
            var screen: routing.Screen = if (automatically_routed and !scoped_review)
                routing.inspect(work.adapter.files, work.prepared.snap.limited)
            else
                .{ .floor = .{}, .ask_model = false };
            if (automatically_routed and repo.routing_mode == .adaptive and work.prepared.snap.limited) {
                // Keep the risk floor and use screening to request missing source.
                screen.ask_model = true;
            }
            if (automatically_routed and work.prepared.inherited.pins.len > 1) {
                screen.floor = screen.floor.merge(.{ .depth = .focused, .reliability = true });
                screen.ask_model = false;
            }
            if (work.prepared.onchain_available and screen.floor.depth == .multi) screen.ask_model = true;
            if (work.prepared.all_models) {
                progress.all_models = true;
                screen.floor = routing.all_lenses;
            }
            if (work.prepared.sections.len != 0 and !work.prepared.onchain_available) {
                // Route a rereview once, then reuse the selected depth across its sections.
                screen.ask_model = automatically_routed and work.prepared.rereview and screen.floor.depth != .multi;
            }
            const plan: adaptive.Plan = .{
                .repo = repo,
                .providers = try repo.providers(self.a),
                .prepared = work.prepared,
                .screen = screen,
                .progress = progress,
                .start_limit = queue.reviewerCost(repo),
            };
            const has_section = work.prepared.sections.len == 0 or progress.sections.index < work.prepared.sections.len;
            if (has_section and work.prepared.sections.len > 1 and
                !work.prepared.context_update and !work.prepared.onchain_available and
                (!plan.screen.ask_model or !progress.screen_waiting))
            {
                try self.prepareSectionWindow(work, plan);
            } else {
                const section = if (has_section) work.prepared.section(progress.sections.index) else work.prepared;
                work.plan = try self.prepareReviewEvidence(&work.adapter, plan, section);
            }
        }
        if (!state.queue_budget.canReview(repo, job.route_progress, std.time.timestamp(), batch.limited.load(.monotonic), batch.usageSnapshot()))
            return error.ReviewerCoolingDown;
        work.job_key = try ReviewWorker.jobKey(self.a, repo, job.*);
        work.thread = try std.Thread.spawn(.{}, ReviewWorker.analyze, .{work});
        const extra = work.plan.?.start_limit * @as(u32, @intCast(work.section_plans.len -| 1));
        work.reservation = work.plan.?.start_limit + extra;
        batch.starts_left -= extra;
        batch.pending += 1;
        batch.workers[batch.len] = work;
        batch.len += 1;
    }

    fn prepareSectionWindow(self: Main, work: *ReviewWorker, initial: adaptive.Plan) !void {
        var root = initial;
        root.progress.screen_waiting = false;
        if (root.progress.decision == null) {
            root.progress.decision = if (root.screen.floor.depth == .light) .{} else root.screen.floor;
        }
        const sections = &root.progress.sections;
        if (sections.finished_mask == null) {
            // Older checkpoints have a contiguous prefix and one active section.
            sections.finished_mask = adaptive.sectionBit(sections.index) - 1;
            var active = root.progress;
            active.sections = .{};
            active.review_ms = 0;
            sections.pending = try self.a.dupe(core.SectionTask, &.{.{ .index = sections.index, .progress = active }});
            adaptive.resetSection(&root.progress);
        }

        const window = @min(queue.parallel_sections, 1 + work.batch.starts_left / root.start_limit);
        var plans: std.ArrayList(SectionPlan) = .empty;
        var occupied = sections.pending.len;
        const now = std.time.timestamp();
        const limited = work.batch.limited.load(.monotonic);
        const provider_usage = work.batch.usageSnapshot();
        for (0..root.prepared.sections.len) |index| {
            if (sections.finished_mask.? & adaptive.sectionBit(index) != 0) continue;
            if (plans.items.len == window) break;
            var scoped = root;
            scoped.progress = for (sections.pending) |saved| {
                if (saved.index == index) break saved.progress;
            } else new: {
                if (occupied == queue.parallel_sections) continue;
                occupied += 1;
                break :new .{
                    .fingerprint = root.progress.fingerprint,
                    .all_models = root.progress.all_models,
                    .decision = root.progress.decision,
                    .screen_waiting = false,
                };
            };
            if (!work.policy.canReview(root.repo, scoped.progress, now, limited, provider_usage)) continue;
            scoped.prepared = root.prepared.section(index);
            scoped.prepared.sections = &.{};
            try plans.append(self.a, .{
                .index = index,
                .plan = try self.prepareReviewEvidence(&work.adapter, scoped, scoped.prepared),
            });
        }
        if (plans.items.len == 0) return error.ReviewerCoolingDown;
        work.plan = root;
        work.section_plans = plans.items;
    }

    fn prepareReviewEvidence(self: Main, live: *Adapter, initial: adaptive.Plan, section: core.Prepared) !adaptive.Plan {
        var plan = initial;
        const progress = &plan.progress;
        if (progress.onchain_reads.len != 0 and progress.onchain_observations == null) {
            progress.onchain_observations = try live.onchainReads(plan.prepared.pr, progress.onchain_reads);
        }
        if (progress.evidence_requests.len != 0) {
            const pinned = try live.reviewEvidence(plan.prepared.pr, progress.evidence_requests, adaptive.evidenceCapacity(section));
            plan.evidence = pinned.source;
            plan.evidence_limited = pinned.limited;
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(pinned.source);
            hash.update(&.{@intFromBool(pinned.limited)});
            const evidence_key = hash.finalResult();
            if (progress.evidence_key) |prior| {
                if (!eq(u8, &prior, &evidence_key)) {
                    const requests = progress.evidence_requests;
                    adaptive.resetSection(progress);
                    progress.evidence_requests = requests;
                    progress.review_ms = 0;
                }
            }
            progress.evidence_key = evidence_key;
        }
        if (progress.completion_requests) |requests| {
            if (requests.len != 0) {
                const capacity = try adaptive.completionCapacity(section, plan.evidence orelse "", progress.onchain_observations orelse &.{}, self.a);
                plan.completion_evidence = try live.reviewEvidence(plan.prepared.pr, requests, capacity);
            }
        }
        return plan;
    }

    fn resumeReview(self: Main, repo: core.Repo, job: *core.Job, prepared: *core.Prepared) !core.RouteProgress {
        const saved = job.route_progress;
        const prior_checkpoint = if (saved) |prior| prior.sections.checkpoint else null;
        var checkpoint: ?core.SectionCheckpoint = if (prepared.sections.len != 0) try .capture(self.a, repo, prepared.*) else null;
        const same_source = if (prior_checkpoint) |prior|
            if (checkpoint) |current| prior.sameSource(current) else false
        else
            false;
        const fingerprint = if (same_source) saved.?.fingerprint else try core.SavedAnalysis.key(self.a, repo, prepared.*);
        var progress: core.RouteProgress = .{ .fingerprint = fingerprint };
        if (saved) |prior| {
            if (same_source or (prior_checkpoint == null and eq(u8, &prior.fingerprint, &fingerprint))) {
                progress = prior;
            } else job.route_progress = null;
        }
        progress.base = .fromPull(prepared.pr);
        if (same_source) {
            const changed = !eq(u8, &checkpoint.?.discussion, &prior_checkpoint.?.discussion);
            checkpoint.?.update_discussion = changed or prior_checkpoint.?.update_discussion;
            if (progress.sections.index == prepared.sections.len and checkpoint.?.update_discussion) {
                if (changed) adaptive.resetSection(&progress);
                if (!try core.appendDiscussionUpdate(self.a, prepared, repo, progress.sections.results)) {
                    progress.sections.evidence_limited = true;
                }
            }
        }
        progress.sections.checkpoint = checkpoint;
        return progress;
    }

    fn finishJob(self: Main, state: *store.State, work: *ReviewWorker) !void {
        const results = try work.result;
        if (work.route_outcome) |outcome| {
            if (outcome.report) |report| {
                work.prepared.route_depth = report.applied.depth;
                work.prepared.synthesis_provider = report.synthesis_provider;
                work.prepared.synthesis_summary = outcome.synthesis_summary;
                work.prepared.additional_evidence_limited = outcome.evidence_limited;
                work.prepared.evidence_requests = if (report.diff_sections != 0)
                    outcome.progress.sections.evidence_requests
                else
                    try std.mem.concat(self.a, core.EvidenceRequest, &.{
                        outcome.progress.evidence_requests, outcome.progress.completion_requests orelse &.{},
                    });
                work.prepared.onchain_observations = report.onchain_observations;
                work.job.route_report = report;
                work.job.route_report.?.providers = try self.a.dupe(core.Engine, report.providers);
                work.job.route_progress = null;
                if (report.diff_sections != 0 and work.publicationBlocked(state.queue_budget)) {
                    return self.keepSectionReview(state, work, outcome.progress, report.diff_sections);
                }
                return self.finishReviews(state, work, outcome.review_results orelse outcome.progress.results) catch |err| {
                    if (report.diff_sections != 0 and work.job.phase == .pending) {
                        if (err == error.ThreadsChanged or err == error.TargetChanged or err == error.GitHubRateLimited) {
                            try self.keepSectionReview(state, work, outcome.progress, report.diff_sections);
                            if (err == error.ThreadsChanged) return;
                        }
                    }
                    return err;
                };
            }
            work.job.route_progress = try io.parse(self.a, core.RouteProgress, try io.json(self.a, outcome.progress));
            if (outcome.progress.sections.index > work.plan.?.progress.sections.index) {
                work.job.attempts = 0;
                work.job.next = 0;
            }
            if (outcome.failure) |err| return err;
            try self.db.save(state);
            return;
        }
        return self.finishReviews(state, work, results[0..work.prepared.engines.len]);
    }

    fn keepSectionReview(self: Main, state: *store.State, work: *ReviewWorker, finished: core.RouteProgress, count: usize) !void {
        var progress = finished;
        progress.sections.index = count;
        if (progress.sections.checkpoint) |*checkpoint| checkpoint.update_discussion = false;
        adaptive.resetSection(&progress);
        work.job.analysis = null;
        work.job.route_report = null;
        work.job.route_progress = try io.parse(self.a, core.RouteProgress, try io.json(self.a, progress));
        try self.db.save(state);
    }

    fn finishReviews(self: Main, state: *store.State, work: *ReviewWorker, reviews: []const core.ReviewerResult) !void {
        if (try self.db.paused(work.adapter.repo.name)) return;
        if (work.publicationBlocked(state.queue_budget)) {
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
        const rerun = args.len == 4 and eq(u8, args[2], "--all-maxxing") and eq(u8, args[3], "--rerun");
        const all_models = rerun or (args.len == 3 and eq(u8, args[2], "--all-maxxing"));
        if (!all_models and args.len != 2 and (args.len < 4 or args.len > stack.max_members + 2)) return error.Usage;
        const entry = state.find(args[0]) orelse return error.UnknownRepository;
        if (all_models or args.len == 2) {
            const number = try prNumber(args[1]);
            const count = try self.enqueueStack(state, entry, number, all_models, rerun);
            return self.out("Queued {s} GitHub stack #{d} with {d} open PRs{s}\n", .{ entry.repo.name, number, count, if (all_models) " for all-model review" else "" });
        }
        const name = args[1];
        var members: [stack.max_members]u32 = undefined;
        const numbers = members[0 .. args.len - 2];
        for (args[2..], numbers) |arg, *number| number.* = try prNumber(arg);
        try stack.validateRegistration(entry.*, name, numbers);
        const tools = self.local(entry.repo);
        const env = try tools.githubEnv();
        const client = try tools.gh(&env, entry.repo.name);
        if (!std.ascii.eqlIgnoreCase(entry.repo.login, try client.identity())) return error.GitHubIdentityChanged;
        try stack.register(entry, self.a, name, try client.stackPulls(numbers));
        try self.db.save(state);
        try self.out("Queued {s} stack {s} with {d} PRs\n", .{ entry.repo.name, name, numbers.len });
    }

    fn enqueueStack(self: Main, state: *store.State, entry: *core.Entry, number: u32, all_models: bool, rerun: bool) !usize {
        const group = try self.fetchNativeStack(entry.repo, number);
        const count = try stack.queueNative(entry, self.a, group, if (all_models) .{ .all_models = true } else null, rerun);
        try self.db.save(state);
        return count;
    }

    fn fetchNativeStack(self: Main, repo: core.Repo, number: u32) !stack.NativeGroup {
        const tools = self.local(repo);
        const env = try tools.githubEnv();
        const client = try tools.gh(&env, repo.name);
        if (!std.ascii.eqlIgnoreCase(repo.login, try client.identity())) return error.GitHubIdentityChanged;
        return client.nativeByNumber(number);
    }

    fn enqueuePull(self: Main, state: *store.State, entry: *core.Entry, number: u32, options: ?core.ReviewOptions) !core.Job {
        const pull = try self.choose(entry, number);
        return self.enqueuePinnedPull(state, entry, pull, options);
    }

    fn enqueuePinnedPull(self: Main, state: *store.State, entry: *core.Entry, pull: core.Pull, options: ?core.ReviewOptions) !core.Job {
        if (options == null) {
            for (entry.jobs) |job| {
                if (job.number != pull.number or !eq(u8, job.head, pull.headRefOid)) continue;
                if (job.phase == .complete or (job.phase == .pending and job.attempts == 0)) return job;
            }
        }
        try entry.queue(self.a, pull, options);
        try self.db.save(state);
        for (entry.jobs) |job| {
            if (job.number == pull.number and eq(u8, job.head, pull.headRefOid)) return job;
        }
        unreachable;
    }

    fn choose(self: Main, entry: *core.Entry, number: u32) !core.Pull {
        const tools = self.local(entry.repo);
        const env = try tools.githubEnv();
        const gh = try tools.gh(&env, entry.repo.name);
        const pr = try gh.pull(number);
        if (!core.isReviewable(pr)) return error.PullRequestNotReady;
        if (!core.validOid(pr.headRefOid)) return error.InvalidCommit;
        return pr;
    }

    fn reviewOptions(a: A, args: []const []const u8, allow_publish: bool) !core.ReviewOptions {
        var options: core.ReviewOptions = .{};
        var focuses: core.ReviewFocusSet = .initEmpty();
        var index: usize = 0;
        while (index < args.len) {
            const flag = args[index];
            index += 1;
            if (eq(u8, flag, "--publish") and allow_publish and !options.publish_prompted) {
                options.publish_prompted = true;
                continue;
            }
            if (eq(u8, flag, "--all-maxxing") and allow_publish and !options.all_models) {
                options.all_models = true;
                continue;
            }
            if (index == args.len) return error.Usage;
            const value = args[index];
            index += 1;
            if (eq(u8, flag, "--mode")) {
                try addReviewFocus(&focuses, value);
            } else if (eq(u8, flag, "--prompt") and options.request == null) {
                try core.validateReviewRequest(value);
                options.request = value;
            } else return error.Usage;
        }
        if (options.publish_prompted and options.request == null) return error.Usage;
        try options.setFocuses(a, focuses);
        return options;
    }

    fn dry(self: Main, state: *store.State, args: []const []const u8) !void {
        var preview: core.Preview = .{
            .options = if (args.len > 2) try reviewOptions(self.a, args[2..], false) else null,
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
            var prepared = (try core.prepare(self.a, &live, entry.repo, &job, .{ .preview = preview })).?;
            var preview_id: [16]u8 = undefined;
            std.crypto.random.bytes(&preview_id);
            live.tools.telemetry = .{ .dir = self.db.dir, .scope = .{
                .repo = entry.repo.name,
                .pr = job.number,
                .head = job.head,
                .mode = .preview,
                .stage = .preview,
                .review_id = try self.a.dupe(u8, &std.fmt.bytesToHex(preview_id, .lower)),
                .focus = prepared.options.focus,
                .additional_focuses = prepared.options.additional_focuses,
            } };
            const observations = try live.previewReads(prepared);
            var context = prepared.context;
            prepared.additional_evidence_limited = try core.appendOnchain(self.a, &context, observations);
            prepared.onchain_observations = observations;
            const results = try core.analyze(self.a, &live, prepared.engines, context);
            const reviewed = try self.completePreview(&live, &prepared, results[0..prepared.engines.len]);
            const payload = (try core.finish(self.a, &live, entry.repo, &job, prepared, reviewed)).?;
            if (observations.len == 0) {
                try self.out("{s}\n", .{try io.json(self.a, .{ .repo = entry.repo.name, .pr = job.number, .review = payload })});
            } else {
                try self.out("{s}\n", .{try io.json(self.a, .{ .repo = entry.repo.name, .pr = job.number, .review = payload, .onchain_observations = observations })});
            }
        }
    }

    fn completePreview(self: Main, adapter_: *Adapter, prepared: *core.Prepared, results: []const core.ReviewerResult) ![]const core.ReviewerResult {
        const requests = try adaptive.completionRequests(self.a, results, &.{});
        if (requests.len == 0) return results;
        const capacity = try adaptive.completionCapacity(prepared.*, "", prepared.onchain_observations, self.a);
        const evidence = try adapter_.reviewEvidence(prepared.pr, requests, capacity);
        var repo = adapter_.repo;
        repo.routing_mode = .fixed;
        const preview = try adaptive.run(self.a, PreviewReviewer{ .adapter = adapter_ }, .{
            .repo = repo,
            .providers = prepared.engines,
            .prepared = prepared.*,
            .screen = .{ .floor = .{}, .ask_model = false },
            .progress = .{
                .fingerprint = @splat(0),
                .screen_waiting = false,
                .results = results,
                .completion_requests = requests,
                .onchain_observations = prepared.onchain_observations,
            },
            .start_limit = @intCast(results.len),
            .completion_evidence = evidence,
        });
        prepared.additional_evidence_limited = prepared.additional_evidence_limited or preview.evidence_limited;
        prepared.evidence_requests = requests;
        return preview.progress.results;
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
                const PendingRoute = struct { number: u32, head: []const u8, decision: ?routing.Decision, completed_passes: usize, completed_sections: usize, all_models: bool };
                var pending: std.ArrayList(PendingRoute) = .empty;
                for (summary.jobs) |*job| {
                    if (job.route_progress) |progress| try pending.append(self.a, .{
                        .number = job.number,
                        .head = job.head,
                        .decision = progress.decision,
                        .completed_passes = progress.results.len,
                        .completed_sections = progress.sections.index,
                        .all_models = progress.all_models,
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
                    try self.out("    #{d} {s}{s} {s}", .{ member.number, member.state, if (member.is_draft) " (draft)" else "", member.review });
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

    fn withUsage(self: Main, state: *store.State, lock: std.fs.File, preview_args: ?[]const []const u8) !void {
        var metered = self;
        var ledger: usage_meter.Ledger = .{
            .dir = self.db.dir,
            .data = try usage_meter.load(self.a, self.db.dir, std.time.timestamp()),
        };
        metered.meter = &ledger;
        if (preview_args) |args| return metered.dry(state, args);
        return metered.tick(state, lock);
    }

    fn scheduledTick(self: Main, lock: std.fs.File) !void {
        log_retention.maintain(self.a, self.db.dir, std.time.nanoTimestamp()) catch |err|
            std.log.warn("diagnostic log maintenance failed ({s})", .{@errorName(err)});
        defer log_retention.maintain(self.a, self.db.dir, std.time.nanoTimestamp()) catch |err|
            std.log.warn("diagnostic log maintenance failed ({s})", .{@errorName(err)});
        const result: anyerror!void = tick: {
            self.cleanReviewScratch() catch |err| break :tick err;
            self.db.recoverPasses(std.time.timestamp()) catch |err| break :tick err;
            var state = self.db.load() catch |err| break :tick err;
            break :tick self.withUsage(&state, lock, null);
        };
        result catch |err| {
            std.log.err("{s}", .{@errorName(err)});
            return error.ScheduledTickFailed;
        };
    }

    fn cleanReviewScratch(self: Main) !void {
        self.db.dir.makeDir("review-scratch") catch |err| if (err != error.PathAlreadyExists) return err;
        var dir = try self.db.dir.openDir("review-scratch", .{ .iterate = true, .no_follow = true });
        defer dir.close();
        var paths = dir.iterate();
        while (try paths.next()) |entry| {
            // The provider batch lock covers the whole tick, so these
            // private directories can only belong to an interrupted tick.
            if (entry.kind == .directory and entry.name.len == "pass-XXXXXX".len and
                std.mem.startsWith(u8, entry.name, "pass-")) try dir.deleteTree(entry.name);
        }
    }

    fn dashboardCommand(self: Main, args: []const []const u8) !void {
        const manage = args.len != 0 and (eq(u8, args[0], "install") or eq(u8, args[0], "remove"));
        const options = if (manage) args[1..] else args;
        const port = switch (options.len) {
            0 => dashboard.default_port,
            2 => if (eq(u8, options[0], "--port")) std.fmt.parseUnsigned(u16, options[1], 10) catch return error.Usage else return error.Usage,
            else => return error.Usage,
        };
        if (port == 0) return error.Usage;
        if (!manage) return dashboard.serve(port, self);
        const env = try pick(self.a, self.env, &common_env);
        return launchd.manageDashboard(self.local(null).command(&env), self.home, self.env.get("PATH") orelse "/usr/bin:/bin", self.db.path, eq(u8, args[0], "install"), port);
    }

    pub fn api(context: Main, a: A, request: dashboard.Request) !dashboard.Response {
        var self = context;
        self.a = a;
        self.db.a = a;
        const body = self.dashboardRequest(request) catch |err| {
            const failure: struct { status: std.http.Status, message: []const u8 } = switch (err) {
                error.InvalidDashboardQuery => .{ .status = .bad_request, .message = "Invalid or repeated query parameter." },
                error.BadQueueRequest => .{ .status = .bad_request, .message = "Select a repository and a valid PR or stack number." },
                error.InvalidReviewMode => .{ .status = .bad_request, .message = "Select distinct review focuses. General is selected on its own." },
                error.InvalidMetricsDays => .{ .status = .bad_request, .message = std.fmt.comptimePrint("Choose a range from 1 to {d} days.", .{max_metrics_days}) },
                error.UnknownRepository => .{ .status = .not_found, .message = "Talos does not track that repository." },
                error.AlreadyRunning => .{ .status = .conflict, .message = "Talos is saving queue changes. Try again in a moment." },
                error.DashboardTargetChanged => .{ .status = .conflict, .message = "The repository or PR changed during lookup. Try again." },
                error.DashboardStackMemberChanged, error.GitHubStackChanged => .{ .status = .conflict, .message = "The stack changed during lookup. Check the PR again." },
                error.PublicationUnconfirmed => .{ .status = .conflict, .message = "Talos is confirming an existing GitHub review." },
                error.PullRequestNotReady, error.NoOpenStackMembers => .{ .status = .unprocessable_entity, .message = "There are no open PR heads to queue." },
                error.GitHubPullFailed, error.GitHubStackFailed, error.GitHubTargetMismatch => .{ .status = .bad_gateway, .message = "GitHub could not load that PR or stack." },
                error.GitHubIdentityChanged => .{ .status = .conflict, .message = "The GitHub account differs from the one configured for this repository." },
                error.GitHubRateLimited => .{ .status = .too_many_requests, .message = "GitHub is rate limiting requests. Try again later." },
                else => return err,
            };
            return .{ .status = failure.status, .body = try io.json(a, .{ .@"error" = failure.message }) };
        };
        return .{ .body = body };
    }

    fn dashboardRequest(self: Main, request: dashboard.Request) ![]const u8 {
        const now = std.time.timestamp();
        const query = try parseDashboardQuery(self.a, request.query);
        switch (request.route) {
            .state => {
                if (query.repo != null or query.number != null or query.days != null) return error.InvalidDashboardQuery;
                return dashboard_data.stateJson(self.a, self.db, query.history orelse false, now);
            },
            .metrics => {
                if (query.repo != null or query.number != null or query.history != null) return error.InvalidDashboardQuery;
                return dashboard_data.metricsJson(self.a, self.db, query.days orelse 30, 0, now);
            },
            .review => {
                if (query.days != null or query.history != null) return error.InvalidDashboardQuery;
                const name = query.repo orelse return error.InvalidDashboardQuery;
                if (!core.validRepoName(name)) return error.InvalidDashboardQuery;
                return dashboard_data.reviewJson(self.a, self.db, name, query.number orelse return error.InvalidDashboardQuery, now);
            },
            .queue_target => {
                if (query.days != null or query.history != null) return error.InvalidDashboardQuery;
                const name = query.repo orelse return error.InvalidDashboardQuery;
                if (!core.validRepoName(name)) return error.InvalidDashboardQuery;
                return self.dashboardQueueTarget(name, query.number orelse return error.InvalidDashboardQuery);
            },
            .queue => {
                if (request.query.len != 0) return error.InvalidDashboardQuery;
                return self.dashboardQueue(request.body);
            },
        }
    }

    fn dashboardQueueTarget(self: Main, name: []const u8, number: u32) ![]const u8 {
        var state = try self.db.load();
        const entry = state.find(name) orelse return error.UnknownRepository;
        var request_app = try self.dashboardLookup();
        defer std.fs.deleteTreeAbsolute(request_app.scratch) catch {};
        defer request_app.scratch_dir.close();
        const tools = request_app.local(entry.repo);
        const env = try tools.githubEnv();
        const client = try tools.gh(&env, entry.repo.name);
        const pin = try client.stackPullSuggestion(number);
        if (!pin.reviewable()) return error.PullRequestNotReady;
        const stack_number: ?u32 = if (pin.nativeStack) |native| result: {
            if (!validPrNumber(native.number)) return error.GitHubTargetMismatch;
            break :result native.number;
        } else null;
        return io.json(self.a, .{ .stack_number = stack_number });
    }

    fn dashboardLookup(self: Main) !Main {
        var request_app = self;
        request_app.scratch = try io.temp(self.a);
        errdefer std.fs.deleteTreeAbsolute(request_app.scratch) catch {};
        request_app.scratch_dir = try std.fs.openDirAbsolute(request_app.scratch, .{});
        return request_app;
    }

    fn dashboardQueue(self: Main, body: []const u8) ![]const u8 {
        const input = try DashboardQueueRequest.parse(self.a, body);
        const options = try input.reviewOptions(self.a);
        var observed = try self.db.load();
        const earlier = observed.find(input.repo) orelse return error.UnknownRepository;
        var request_app = try self.dashboardLookup();
        defer std.fs.deleteTreeAbsolute(request_app.scratch) catch {};
        defer request_app.scratch_dir.close();
        const target: union(enum) { pr: core.Pull, stack: stack.NativeGroup } = switch (input.kind) {
            .pr => .{ .pr = try request_app.choose(earlier, input.number) },
            .stack => .{ .stack = try request_app.fetchNativeStack(earlier.repo, input.number) },
        };
        // Remote lookups can take seconds. Only the local queue transaction
        // needs the same lock the CLI and watcher use.
        const lock = try self.db.lock();
        defer lock.close();
        var state = try self.db.load();
        const entry = state.find(input.repo) orelse return error.UnknownRepository;
        if (!eq(u8, try io.json(self.a, earlier.repo), try io.json(self.a, entry.repo))) return error.DashboardTargetChanged;
        const rescanned = entry.last_scan != earlier.last_scan;
        switch (target) {
            .pr => |pull| {
                if (rescanned and dashboardHeadChanged(entry.*, pull.number, pull.headRefOid)) return error.DashboardTargetChanged;
                const job = try self.enqueuePinnedPull(&state, entry, pull, options);
                const message = switch (job.phase) {
                    .complete => "This head already has a review.",
                    .uncertain => "Queued GitHub receipt reconciliation.",
                    .pending, .failed => "Review queued.",
                };
                return io.json(self.a, .{ .repo = entry.repo.name, .number = input.number, .kind = input.kind, .head = job.head, .message = message });
            },
            .stack => |group| {
                if (input.member) |number| {
                    for (group.pins) |pin| {
                        if (pin.number == number and pin.reviewable()) break;
                    } else return error.DashboardStackMemberChanged;
                }
                if (rescanned) for (group.pins) |pin| {
                    if (pin.reviewable() and dashboardHeadChanged(entry.*, pin.number, pin.headRefOid)) return error.DashboardTargetChanged;
                };
                const count = try stack.queueNative(entry, self.a, group, options, false);
                try self.db.save(&state);
                return io.json(self.a, .{
                    .repo = entry.repo.name,
                    .number = input.number,
                    .kind = input.kind,
                    .count = count,
                    .message = try io.fmt(self.a, "Queued stack #{d} with {d} open PRs.", .{ input.number, count }),
                });
            },
        }
    }

    fn dispatch(self: Main, args: []const []const u8) !void {
        const cmd = args[0];
        const params = args[1..];
        if (eq(u8, cmd, "metrics")) {
            var days: ?u32 = null;
            var offset: ?u32 = null;
            if (params.len % 2 != 0) return error.Usage;
            var i: usize = 0;
            while (i < params.len) : (i += 2) {
                if (eq(u8, params[i], "--days") and days == null) {
                    days = try metricsDays(params[i + 1]);
                } else if (eq(u8, params[i], "--offset") and offset == null) {
                    offset = std.fmt.parseUnsigned(u32, params[i + 1], 10) catch return error.Usage;
                } else return error.Usage;
            }
            return self.out("{s}\n", .{try dashboard_data.metricsJson(self.a, self.db, days orelse 30, offset orelse 0, std.time.timestamp())});
        }
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
        const is_tick = eq(u8, cmd, "tick") and params.len == 0;
        const followup_preview = eq(u8, cmd, "followup") and params.len == 2 and eq(u8, params[1], "--dry-run");
        const uses_providers = is_tick or followup_preview or eq(u8, cmd, "run-once") or eq(u8, cmd, "usage");
        const batch_lock = if (uses_providers) self.db.batchLock() catch |err| {
            if (err == error.AlreadyRunning and is_tick) return;
            return err;
        } else null;
        defer if (batch_lock) |file| file.close();
        const lock = self.db.lock() catch |err| {
            if (err == error.AlreadyRunning and is_tick) return;
            return err;
        };
        defer lock.close();
        if (is_tick) return self.scheduledTick(lock);
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
        if (eq(u8, cmd, "run-once")) return self.withUsage(&state, lock, params);
        if (eq(u8, cmd, "stack")) return self.registerStack(&state, params);
        if (eq(u8, cmd, "unstack") and params.len == 2) {
            const entry = state.find(params[0]) orelse return error.UnknownRepository;
            try stack.remove(entry, self.a, params[1]);
            try self.db.save(&state);
            return self.out("Removed {s} stack {s}\n", .{ entry.repo.name, params[1] });
        }
        if (eq(u8, cmd, "queue") and params.len >= 2) {
            const options = if (params.len > 2) try reviewOptions(self.a, params[2..], true) else null;
            const entry = state.find(params[0]) orelse return error.UnknownRepository;
            const job = try self.enqueuePull(&state, entry, try prNumber(params[1]), options);
            if (job.phase == .uncertain) return self.out("Queued receipt reconciliation for {s} #{d} at {s}{s}\n", .{
                entry.repo.name,                                                           job.number, job.head,
                if (options != null) ". Review options apply only to new reviews" else "",
            });
            if (job.phase == .complete) return self.out("Already reviewed {s} #{d} at {s}\n", .{ entry.repo.name, job.number, job.head });
            return self.out("Selected {s} #{d} at {s}\n", .{ entry.repo.name, job.number, job.head });
        }
        return error.Usage;
    }
};

const DashboardQuery = struct { repo: ?[]const u8 = null, number: ?u32 = null, days: ?u32 = null, history: ?bool = null };

fn addReviewFocus(selected: *core.ReviewFocusSet, name: []const u8) !void {
    const focus = std.meta.stringToEnum(core.ReviewFocus, name) orelse return error.InvalidReviewMode;
    if (selected.contains(focus)) return error.Usage;
    if (selected.contains(.general) or (focus == .general and selected.count() != 0)) return error.InvalidReviewMode;
    selected.insert(focus);
}

const DashboardQueueRequest = struct {
    repo: []const u8,
    number: u32,
    kind: enum { pr, stack },
    all_models: bool = false,
    mode: ?[]const u8 = null,
    modes: ?[]const []const u8 = null,
    member: ?u32 = null,

    fn parse(a: A, body: []const u8) !DashboardQueueRequest {
        const input = std.json.parseFromSliceLeaky(DashboardQueueRequest, a, body, .{ .allocate = .alloc_always }) catch return error.BadQueueRequest;
        if (!core.validRepoName(input.repo) or !validPrNumber(input.number)) return error.BadQueueRequest;
        if (input.member) |member| {
            if (input.kind != .stack or !validPrNumber(member)) return error.BadQueueRequest;
        }
        return input;
    }

    fn reviewOptions(self: DashboardQueueRequest, a: A) !?core.ReviewOptions {
        var selected: core.ReviewFocusSet = .initEmpty();
        if (self.mode) |mode| {
            if (self.modes != null) return error.InvalidReviewMode;
            try addReviewFocus(&selected, mode);
        }
        for (self.modes orelse &.{}) |mode| addReviewFocus(&selected, mode) catch return error.InvalidReviewMode;
        if (selected.count() == 0 and !self.all_models) return null;
        var options: core.ReviewOptions = .{ .all_models = self.all_models };
        try options.setFocuses(a, selected);
        return options;
    }
};

fn dashboardHeadChanged(entry: core.Entry, number: u32, head: []const u8) bool {
    for (entry.seen) |pull| {
        if (pull.number == number) return !eq(u8, pull.head, head);
    }
    return false;
}

fn metricsDays(input: []const u8) !u32 {
    const days = std.fmt.parseUnsigned(u32, input, 10) catch return error.InvalidMetricsDays;
    if (days == 0 or days > max_metrics_days) return error.InvalidMetricsDays;
    return days;
}

fn parseDashboardQuery(a: A, raw: []const u8) !DashboardQuery {
    var query: DashboardQuery = .{};
    if (raw.len == 0) return query;
    var args = std.mem.splitScalar(u8, raw, '&');
    while (args.next()) |arg| {
        const equal = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidDashboardQuery;
        const key = arg[0..equal];
        const value = arg[equal + 1 ..];
        if (eq(u8, key, "repo") and query.repo == null) {
            query.repo = try decodeDashboardValue(a, value);
        } else if (eq(u8, key, "number") and query.number == null) {
            query.number = prNumber(value) catch return error.InvalidDashboardQuery;
        } else if (eq(u8, key, "days") and query.days == null) {
            query.days = try metricsDays(value);
        } else if (eq(u8, key, "history") and query.history == null) {
            query.history = if (eq(u8, value, "1")) true else if (eq(u8, value, "0")) false else return error.InvalidDashboardQuery;
        } else return error.InvalidDashboardQuery;
    }
    return query;
}

fn decodeDashboardValue(a: A, raw: []const u8) ![]const u8 {
    const value = try a.alloc(u8, raw.len);
    var input: usize = 0;
    var output: usize = 0;
    while (input < raw.len) : (output += 1) {
        switch (raw[input]) {
            '%' => {
                if (raw.len - input < 3) return error.InvalidDashboardQuery;
                const high = std.fmt.charToDigit(raw[input + 1], 16) catch return error.InvalidDashboardQuery;
                const low = std.fmt.charToDigit(raw[input + 2], 16) catch return error.InvalidDashboardQuery;
                value[output] = high * 16 + low;
                input += 3;
            },
            else => {
                value[output] = raw[input];
                input += 1;
            },
        }
    }
    return value[0..output];
}

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
    if (!validPrNumber(number)) return error.InvalidPullRequest;
    return number;
}

fn validPrNumber(number: u32) bool {
    return number != 0 and number <= std.math.maxInt(i32);
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
    if (eq(u8, args[0], "dashboard")) {
        // HTTP queue requests own their scratch. The long-lived server can
        // exit through launchd without leaving an empty process directory.
        const app: Main = .{ .a = a, .env = &env, .home = home, .db = db, .scratch = try a.dupeZ(u8, db.path), .scratch_dir = db.dir };
        return app.dashboardCommand(args[1..]);
    }
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
    _ = @import("dashboard.zig");
    _ = @import("dashboard_data.zig");
    _ = @import("tests.zig");
}

test "dashboard query accepts encoded repository names and rejects repeated or malformed parameters" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const query = try parseDashboardQuery(a, "repo=example%2Frepo&number=42");
    try t.expectEqualStrings("example/repo", query.repo.?);
    try t.expectEqual(@as(?u32, 42), query.number);
    try t.expectError(error.InvalidDashboardQuery, parseDashboardQuery(a, "number=1&number=2"));
    try t.expectError(error.InvalidDashboardQuery, parseDashboardQuery(a, "repo=example%2"));
    try t.expectEqual(@as(?u32, 365), (try parseDashboardQuery(a, "days=365")).days);
    try t.expectEqual(@as(?u32, max_metrics_days), (try parseDashboardQuery(a, "days=3650")).days);
    try t.expectError(error.InvalidMetricsDays, parseDashboardQuery(a, "days=3651"));
}

test "dashboard queue accepts explicit modes with all models and keeps the default adaptive" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = DashboardQueueRequest.parse;
    const default = try parse(a, "{\"repo\":\"example/repo\",\"number\":42,\"kind\":\"pr\"}");
    try t.expectEqual(@as(?core.ReviewOptions, null), try default.reviewOptions(a));
    const all_models = try parse(a, "{\"repo\":\"example/repo\",\"number\":42,\"kind\":\"pr\",\"all_models\":true}");
    try t.expect((try all_models.reviewOptions(a)).?.allowRouting());
    for (std.meta.tags(core.ReviewFocus)) |mode| {
        const body = try io.json(a, .{ .repo = "example/repo", .number = 42, .kind = "stack", .member = 12, .mode = @tagName(mode), .all_models = true });
        const queued = try parse(a, body);
        const options = (try queued.reviewOptions(a)).?;
        try t.expectEqual(@as(?u32, 12), queued.member);
        try t.expectEqual(mode, options.focus);
        try t.expect(options.all_models and options.explicit_mode and !options.allowRouting());
        try t.expect(options.request == null and !options.publish_prompted);
    }
    const invalid_mode = try parse(a, "{\"repo\":\"example/repo\",\"number\":42,\"kind\":\"pr\",\"mode\":\"unknown\"}");
    try t.expectError(error.InvalidReviewMode, invalid_mode.reviewOptions(a));
    const combined = try parse(a, "{\"repo\":\"example/repo\",\"number\":42,\"kind\":\"stack\",\"modes\":[\"reliability-maxxing\",\"perf-maxxing\"],\"all_models\":true}");
    const combined_options = (try combined.reviewOptions(a)).?;
    try t.expect(combined_options.all_models and !combined_options.allowRouting());
    try t.expectEqual(.@"perf-maxxing", combined_options.focus);
    try t.expectEqualSlices(core.ReviewFocus, &.{.@"reliability-maxxing"}, combined_options.additional_focuses.?);
    const conflicting = try parse(a, "{\"repo\":\"example/repo\",\"number\":42,\"kind\":\"pr\",\"modes\":[\"general\",\"simplicity\"]}");
    try t.expectError(error.InvalidReviewMode, conflicting.reviewOptions(a));
    try t.expectError(error.BadQueueRequest, parse(a, "{\"repo\":\"example/repo\",\"number\":42,\"kind\":\"pr\",\"mode\":0}"));
    try t.expectError(error.BadQueueRequest, parse(a, "{\"repo\":\"example/repo\",\"number\":42,\"kind\":\"pr\",\"member\":12}"));
    try t.expectError(error.BadQueueRequest, parse(a, "{\"repo\":\"example/repo\",\"number\":42,\"kind\":\"stack\",\"member\":0}"));
    try t.expectError(error.BadQueueRequest, parse(a, "{\"repo\":\"example/repo\",\"number\":42,\"kind\":\"pr\",\"publish_prompted\":true}"));
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
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (std.meta.tags(core.ReviewFocus)) |mode| {
        const options = try Main.reviewOptions(a, &.{ "--prompt", "Review the allocator path.", "--mode", @tagName(mode) }, false);
        try t.expectEqual(mode, options.focus);
        try t.expectEqualStrings("Review the allocator path.", options.request.?);
    }
    try t.expectError(error.InvalidReviewMode, Main.reviewOptions(a, &.{ "--mode", "unknown" }, false));
    const combined = try Main.reviewOptions(a, &.{ "--mode", "reliability-maxxing", "--mode", "perf-maxxing" }, false);
    try t.expect(combined.selectedFocuses().contains(.@"reliability-maxxing"));
    try t.expect(combined.selectedFocuses().contains(.@"perf-maxxing"));
    try t.expect(!combined.allowRouting());
    try t.expectError(error.InvalidReviewMode, Main.reviewOptions(a, &.{ "--mode", "simplicity", "--mode", "general" }, false));
    try t.expectError(error.Usage, Main.reviewOptions(a, &.{ "--mode", "general", "--mode", "general" }, false));
    try t.expectError(error.Usage, Main.reviewOptions(a, &.{"--prompt"}, false));
    try t.expectError(error.InvalidReviewPrompt, Main.reviewOptions(a, &.{ "--prompt", "  " }, false));
    try t.expectError(error.Usage, Main.reviewOptions(a, &.{ "--prompt", "Check retries.", "--publish" }, false));
    try t.expectError(error.Usage, Main.reviewOptions(a, &.{"--publish"}, true));
    try t.expect((try Main.reviewOptions(a, &.{ "--publish", "--prompt", "Check retries." }, true)).publish_prompted);
    try t.expect((try Main.reviewOptions(a, &.{"--all-maxxing"}, true)).all_models);
    try t.expectError(error.Usage, Main.reviewOptions(a, &.{"--all-maxxing"}, false));
    try t.expectError(error.Usage, Main.reviewOptions(a, &.{ "--all-maxxing", "--all-maxxing" }, true));
}

test "completion fits encoded excerpts and leaves room for later small requests" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const large = "\t\t\t\t\t\t\t\t";
    const small = "\nkeep();";
    const fitted = try Adapter.fitEvidence(a, .{
        .evidence = large ++ small,
        .excerpts = &.{
            .{ .request = .{ .path = "large.zig", .start_line = null, .end_line = null }, .start_offset = 0, .end_offset = large.len },
            .{ .request = .{ .path = "small.zig", .start_line = null, .end_line = null }, .start_offset = large.len, .end_offset = large.len + small.len },
        },
    }, 11);
    try t.expect(fitted.limited);
    try t.expectEqualStrings(small, fitted.source);
    try t.expectEqual(@as(usize, 1), fitted.provided.len);
    try t.expectEqualStrings("small.zig", fitted.provided[0].path);
}

test "an in-flight review binds to the reloaded job and discards a superseded job" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "a" ** 40;
    const repo: core.Repo = .{ .name = "example/review", .login = "reviewer" };
    var original: core.Job = .{ .number = 42, .head = head };
    var work: ReviewWorker = .{ .job = &original, .batch = undefined };
    work.adapter.repo = repo;
    work.prepared.pr = .{ .number = 42, .headRefOid = head, .isDraft = true };
    work.job_key = try ReviewWorker.jobKey(a, repo, original);

    var reloaded = [_]core.Job{ original, .{ .number = 43, .head = head } };
    var entries = [_]core.Entry{.{ .repo = repo, .jobs = &reloaded }};
    var state: store.State = .{ .entries = &entries };
    try t.expect(try work.rebind(a, &state));
    try t.expect(work.job == &reloaded[0]);
    reloaded[0].options.focus = .simplicity;
    try t.expect(!try work.rebind(a, &state));
}

test "same-source review keeps checkpoints after bot threads and queues a focused pass for human input" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const app: Main = .{ .a = a, .env = undefined, .home = undefined, .db = undefined, .scratch = undefined, .scratch_dir = undefined };
    const repo: core.Repo = .{ .name = "example/review", .login = "reviewer" };
    const pr: core.Pull = .{ .number = 42, .headRefOid = "a" ** 40, .baseRefOid = "b" ** 40, .isDraft = false };
    const thread: core.Thread = .{
        .id = "new-thread",
        .isResolved = false,
        .isOutdated = false,
        .path = "work.zig",
        .line = 17,
        .replies = &.{.{ .author = .{ .login = "coderabbitai", .kind = "Bot" }, .body = "Bot suggestion", .url = "bot" }},
    };
    const bot: core.Discussion = .{ .threads = &.{thread} };
    const review: core.ReviewerResult = .{
        .engine = .codex,
        .review = .{ .complete = true, .summary = "Previous scoped review", .findings = &.{}, .existing_open_findings = &.{} },
    };
    var prepared: core.Prepared = .{
        .pr = pr,
        .snap = .{ .merge_base = pr.baseRefOid, .evidence = "Pinned diff", .diff_priority = &.{"work.zig"}, .thread_evidence = "Latest pinned excerpt" },
        .threads = &.{},
        .inherited = .{},
        .engines = &.{.codex},
        .context = "Original prompt",
        .options = .{},
        .evidence_offset = 0,
        .dry = false,
        .review_input = try core.ReviewInput.init(a, repo, pr, pr.baseRefOid, .{}),
        .sections = &.{.{ .context = "Section", .evidence = "Pinned diff", .patch = "Pinned diff" }},
    };
    var job: core.Job = .{
        .number = 42,
        .head = pr.headRefOid,
        .route_progress = .{
            .fingerprint = try core.SavedAnalysis.key(a, repo, prepared),
            .sections = .{ .index = 1, .results = &.{review} },
        },
    };
    job.route_progress = try app.resumeReview(repo, &job, &prepared);
    try t.expect(job.route_progress.?.readyToPublish());

    prepared.context = "New prompt with bot suggestion";
    prepared.threads = bot.threads;
    prepared.review_input = try core.ReviewInput.init(a, repo, pr, pr.baseRefOid, bot);
    const unchanged = try app.resumeReview(repo, &job, &prepared);
    try t.expect(unchanged.readyToPublish());
    try t.expectEqual(@as(usize, 1), unchanged.sections.results.len);

    var changed_source = prepared;
    changed_source.sections = &.{.{ .context = "Same prompt", .evidence = "Other source", .patch = "Other source" }};
    var other_job = job;
    try t.expectEqual(@as(usize, 0), (try app.resumeReview(repo, &other_job, &changed_source)).sections.index);

    prepared.comments = &.{.{ .author = .{ .login = "author", .kind = "User" }, .body = "Please verify the startup case.", .url = "human" }};
    prepared.review_input = try core.ReviewInput.init(a, repo, pr, pr.baseRefOid, .{ .comments = prepared.comments, .threads = bot.threads });
    const resumed = try app.resumeReview(repo, &job, &prepared);
    try t.expect(resumed.sections.checkpoint.?.update_discussion);
    try t.expectEqual(@as(usize, 1), resumed.sections.index);
    try t.expectEqual(@as(usize, 1), resumed.sections.results.len);
    try t.expect(prepared.context_update);
    try t.expectEqual(@as(usize, 2), prepared.sections.len);
    try t.expect(std.mem.indexOf(u8, prepared.sections[1].context, "Please verify the startup case.") != null);
    try t.expect(std.mem.indexOf(u8, prepared.sections[1].context, "Latest pinned excerpt") != null);
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
    var workers: [2]*ReviewWorker = undefined;
    defer batch.deinit();
    for (&workers, [_][]const u8{ "one", "two" }) |*slot, name| {
        try writeExecutable(dir, name, program);
        const repo: core.Repo = .{ .name = "test/repo", .login = "test", .codex = try dir.realpathAlloc(a, name) };
        const work = try std.heap.page_allocator.create(ReviewWorker);
        work.* = .{ .job = undefined, .batch = &batch };
        slot.* = work;
        work.adapter.repo = repo;
        work.adapter.tools = .{ .a = a, .env = &env, .scratch = path, .scratch_dir = dir, .programs = Programs.fromRepo(repo) };
        work.prepared.engines = &.{.codex};
        work.prepared.context = "review";
        batch.workers[batch.len] = work;
        batch.len += 1;
        work.thread = try std.Thread.spawn(.{}, ReviewWorker.analyze, .{work});
    }
    for (workers) |work| {
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

test "finishing workers repay outstanding reservations after a budget reduction" {
    const t = std.testing;
    var batch: ReviewBatch = .{ .starts_left = 0, .receipts_left = 0 };
    var worker: ReviewWorker = .{ .job = undefined, .batch = &batch, .reservation = 6 };
    worker.started.store(2, .monotonic);
    batch.workers[0] = &worker;
    batch.len = 1;

    batch.renewBudget(2);
    try t.expectEqual(0, batch.starts_left);
    batch.releaseStarts(1);
    try t.expectEqual(0, batch.starts_left);
    batch.releaseStarts(2);
    try t.expectEqual(1, batch.starts_left);
}

test "providers in one review overlap and clean up their own scratch" {
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
        \\while [ ! -s "$HOME/fake-codex.cwd" ] || [ ! -s "$HOME/fake-claude.cwd" ]; do
        \\    [ "$i" -lt 100 ] || exit 1
        \\    i=$((i + 1))
        \\    sleep 0.05
        \\done
        \\review='{"complete":true,"summary":"Fixture","findings":[],"existing_open_findings":[],"non_blocking_threads":[]}'
        \\case "${0##*/}" in
        \\  fake-codex)
        \\    while [ "$1" != "--output-last-message" ]; do shift; done
        \\    printf '%s' "$review" > "$2" ;;
        \\  fake-claude) printf '{"is_error":false,"structured_output":%s}' "$review" ;;
        \\esac
    ;
    try writeExecutable(dir, "fake-codex", program);
    try writeExecutable(dir, "fake-claude", program);
    var env = std.process.EnvMap.init(a);
    try env.put("HOME", path);
    try env.put("PATH", "/usr/bin:/bin");
    const repo: core.Repo = .{
        .name = "test/repo",
        .login = "test",
        .codex = try dir.realpathAlloc(a, "fake-codex"),
        .claude = try dir.realpathAlloc(a, "fake-claude"),
    };
    var batch: ReviewBatch = .{ .starts_left = 2, .receipts_left = 0 };
    var worker: ReviewWorker = .{ .job = undefined, .batch = &batch };
    worker.adapter.repo = repo;
    worker.prepared.all_models = false;
    try t.expectEqual(@as(u32, 15 * 60), worker.fullProfile(.codex).timeout_seconds);
    worker.prepared.all_models = true;
    try t.expectEqual(@as(u32, 30 * 60), worker.fullProfile(.codex).timeout_seconds);
    worker.tools = .{ .a = a, .env = &env, .scratch = path, .scratch_dir = dir, .programs = Programs.fromRepo(repo) };
    var results: [2]anyerror![]const u8 = undefined;
    try worker.routeParallel(&.{
        .{ .engine = .codex, .prompt = "One", .lens_index = 0 },
        .{ .engine = .claude, .prompt = "Two", .lens_index = 1 },
    }, &results);
    for (results) |result| try t.expectEqualStrings("Fixture", (try core.parseReview(a, try result)).summary);
    try t.expectEqual(@as(u32, 2), worker.counts.reviewer_starts);
    try t.expectError(error.FileNotFound, dir.access("codex", .{}));
    try t.expectError(error.FileNotFound, dir.access("claude", .{}));
}

test "reviewer cooldown applies to the remaining ensemble" {
    const engines = &.{ .codex, .claude, .kimi };
    try std.testing.expect(!ReviewWorker.remainingLimited(engines, .claude, queue.engineBit(.codex)));
    try std.testing.expect(ReviewWorker.remainingLimited(engines, .claude, queue.engineBit(.claude)));
    try std.testing.expect(ReviewWorker.remainingLimited(engines, .claude, queue.engineBit(.kimi)));
}
