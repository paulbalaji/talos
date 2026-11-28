const std = @import("std");
const adaptive = @import("adaptive.zig");
const core = @import("core.zig");
const io = @import("io.zig");
const store = @import("store.zig");
const stack = @import("stack.zig");

const t = std.testing;
const repo = core.Repo{ .name = "example/repo", .login = "reviewer", .comments = true };
const head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const base = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const changed = "cccccccccccccccccccccccccccccccccccccccc";
const fixture_pull = core.Pull{
    .number = 42,
    .headRefOid = head,
    .baseRefOid = base,
    .isDraft = false,
    .statusCheckRollup = &.{},
    .author = .{ .login = "author" },
};
const finding =
    \\{"complete":true,"summary":"Static review.","findings":[{"severity":"P2","path":"src/watch.rs","line":20,"body":"The cursor skips a height."}],"existing_open_findings":[],"non_blocking_threads":[]}
;
const clean =
    \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":[],"non_blocking_threads":[]}
;

const Fake = struct {
    a: io.A,
    db: ?store.Store = null,
    state: ?*const store.State = null,
    target: core.Pull = fixture_pull,
    offered: ?core.Prior = null,
    previous_reviews: []const core.Prior = &.{},
    discussion: []const core.Thread = &.{},
    late_discussion: ?[]const core.Thread = null,
    comments: []const core.Reply = &.{},
    late_comments: ?[]const core.Reply = null,
    snapshot_threads: []const core.Thread = &.{},
    source_limited: bool = false,
    pinned_snapshot: ?core.Snapshot = null,
    optional_source: []const u8 = "",
    previous_delta: []const u8 = "",
    historical_coverage_reasons: []const []const u8 = &.{},
    thread_reads: usize = 0,
    result: []const u8 = finding,
    other_results: []const []const u8 = &.{},
    fail_engine: ?core.Engine = null,
    lose_response: bool = false,
    lose_readback: bool = false,
    lose_inline_readback: bool = false,
    move_during_review: enum { none, head, base, base_ref, draft } = .none,
    inherited: stack.Context = .{},
    move_ancestor_during_review: bool = false,
    join_native_before_post: bool = false,
    posts: usize = 0,
    reviews_run: usize = 0,
    reviewed_engines: [core.engine_count]core.Engine = undefined,
    readbacks: usize = 0,
    inline_readbacks: usize = 0,
    prompt_text: []const u8 = "",
    posted_result: ?core.Payload = null,
    saved_result: ?core.Result = null,

    pub fn checkIdentity(_: *Fake) !void {}

    pub fn pull(self: *Fake, _: u32) !core.Pull {
        return self.target;
    }

    pub fn reviews(self: *Fake, _: u32) ![]const core.Prior {
        if (self.offered) |latest| return std.mem.concat(self.a, core.Prior, &.{ self.previous_reviews, &.{latest} });
        return self.previous_reviews;
    }

    pub fn reviewDiscussion(self: *Fake, _: u32) !core.Discussion {
        self.thread_reads += 1;
        return .{
            .threads = if (self.thread_reads >= 3) self.late_discussion orelse self.discussion else self.discussion,
            .comments = if (self.thread_reads >= 3) self.late_comments orelse self.comments else self.comments,
        };
    }

    pub fn snapshot(self: *Fake, _: core.Pull, threads: []const core.Thread) !core.Snapshot {
        self.snapshot_threads = threads;
        if (self.pinned_snapshot) |snapshot_value| return snapshot_value;
        const required = "Diff in src/watch.rs";
        return .{
            .merge_base = base,
            .evidence = if (self.optional_source.len == 0) required else try std.mem.concat(self.a, u8, &.{ required, self.optional_source }),
            .limited = self.source_limited,
            .optional_evidence_start = if (self.optional_source.len == 0) null else required.len,
        };
    }

    pub fn supplement(self: *Fake, _: core.Pull, _: ?[]const u8, _: []const core.EvidenceRequest) !struct {
        evidence: []const u8,
        coverage_reasons: []const []const u8,
    } {
        return .{ .evidence = self.previous_delta, .coverage_reasons = self.historical_coverage_reasons };
    }

    pub fn stackContext(self: *Fake, _: core.Pull, _: bool) !stack.Context {
        return self.inherited;
    }

    pub fn checkStack(self: *Fake, _: stack.Context) !void {
        if (self.move_ancestor_during_review and self.reviews_run != 0) return error.StackChanged;
    }

    pub fn checkStackBeforePost(self: *Fake, context: stack.Context, _: core.Pull) !void {
        if (self.join_native_before_post) return error.StackChanged;
        try self.checkStack(context);
    }

    pub fn saveStackContext(_: *Fake, _: core.Pull, _: core.Snapshot, _: core.Payload) !void {}

    pub fn anchor(_: *Fake, _: core.Pull, _: core.Snapshot, path: []const u8, line: u32) !bool {
        return std.mem.eql(u8, path, "src/watch.rs") and line == 20;
    }

    pub fn review(self: *Fake, engine: core.Engine, prompt_text: []const u8) ![]const u8 {
        self.prompt_text = prompt_text;
        self.reviewed_engines[self.reviews_run % core.engine_count] = engine;
        self.reviews_run += 1;
        switch (self.move_during_review) {
            .none => {},
            .head => self.target.headRefOid = changed,
            .base => self.target.baseRefOid = changed,
            .base_ref => self.target.baseRefName = "release",
            .draft => self.target.isDraft = true,
        }
        if (engine == self.fail_engine) return error.ClaudeFailed;
        const extra = self.reviews_run -| 2;
        return if (self.reviews_run > 1 and extra < self.other_results.len) self.other_results[extra] else self.result;
    }

    pub fn post(self: *Fake, _: u32, payload: core.Payload) !u64 {
        self.posts += 1;
        self.posted_result = payload;
        self.offered = .{
            .id = 55,
            .commit_id = payload.commit_id,
            .state = if (payload.event == .COMMENT) "COMMENTED" else "APPROVED",
            .body = payload.body,
            .user = .{ .login = repo.login },
        };
        if (self.lose_response) return error.GitHubPostUnconfirmed;
        return 55;
    }

    pub fn readReview(self: *Fake, _: u32, _: u64) !core.Prior {
        self.readbacks += 1;
        if (self.lose_readback) return error.GitHubReadbackFailed;
        return self.offered orelse error.NoReview;
    }

    pub fn verifyReviewComments(self: *Fake, number: u32, id: u64, commit: []const u8, anchors: []const core.Inline) !void {
        self.inline_readbacks += 1;
        if (self.lose_inline_readback) return error.ReviewInlineReadbackMismatch;
        try t.expectEqual(fixture_pull.number, number);
        try t.expectEqual(@as(u64, 55), id);
        const posted = self.posted_result.?;
        try t.expectEqualStrings(posted.commit_id, commit);
        try t.expectEqual(posted.comments.len, anchors.len);
        for (posted.comments, anchors) |comment, actual| {
            try t.expectEqualStrings(comment.path, actual.path);
            try t.expectEqual(comment.line, actual.line);
            try t.expectEqualStrings(comment.side, actual.side);
            try t.expectEqualStrings("", actual.body);
        }
    }

    pub fn persist(self: *Fake) !void {
        if (self.db) |db| try db.save(self.state.?);
    }

    pub fn saveResult(self: *Fake, _: u32, result: core.Result) !void {
        self.saved_result = result;
    }

    pub fn confirmResult(self: *Fake, _: u32, commit: []const u8, followup_id: []const u8, event: core.Event, id: u64) !void {
        if (self.saved_result) |*result| {
            try t.expectEqualStrings(commit, result.commit_id);
            try t.expectEqualStrings(followup_id, result.followupId());
            try t.expectEqual(event, result.event);
            result.explanation.?.publication = .verified;
            result.explanation.?.github_review_id = id;
        }
    }
};

test "same-head discussion changes get one new receipt and survive an ambiguous post" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const own = core.Reply{ .author = .{ .login = repo.login }, .body = "Talos found a problem.", .url = "own" };
    const bot = core.Reply{ .author = .{ .login = "coverage[bot]" }, .body = "Coverage changed.", .url = "bot" };
    const author = core.Reply{ .author = .{ .login = "author" }, .body = "Accepted this tradeoff.", .url = "reply" };
    var thread: core.Thread = .{ .id = "thread", .isResolved = false, .isOutdated = false, .path = "src/watch.rs", .line = 20, .replies = &.{own} };
    var fake: Fake = .{ .a = a };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    _ = (try core.run(a, &fake, repo, &job, .scheduled)).?;
    try t.expectEqual(core.Phase.complete, job.phase);
    try t.expectEqual(@as(usize, 1), fake.posts);
    try t.expect(std.mem.indexOf(u8, fake.posted_result.?.body, "talos:review:v1:") != null);

    fake.discussion = &.{thread};
    fake.comments = &.{bot};
    job.observeReviewInput(try core.ReviewInput.init(a, repo, fixture_pull, base, try fake.reviewDiscussion(42)), false, repo.approvals);
    try t.expectEqual(core.Phase.complete, job.phase);

    thread.isResolved = true;
    thread.replies = &.{ own, author };
    fake.discussion = &.{thread};
    job.observeReviewInput(try core.ReviewInput.init(a, repo, fixture_pull, base, try fake.reviewDiscussion(42)), false, repo.approvals);
    try t.expectEqual(core.Phase.pending, job.phase);
    fake.lose_response = true;
    fake.result = finding;
    try t.expectError(error.GitHubPostUnconfirmed, core.run(a, &fake, repo, &job, .scheduled));
    try t.expectEqual(core.Phase.uncertain, job.phase);
    try t.expectEqual(@as(usize, 2), fake.posts);
    try t.expect(std.mem.indexOf(u8, fake.posted_result.?.body, "talos:review:v2:") != null);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text, "Accepted this tradeoff.") != null);

    var recovered = try io.parse(a, core.Job, try io.json(a, job));
    fake.lose_response = false;
    try t.expect((try core.run(a, &fake, repo, &recovered, .scheduled)) == null);
    try t.expectEqual(core.Phase.complete, recovered.phase);
    try t.expectEqual(@as(usize, 2), fake.posts);
    const first_followup = fake.offered.?;
    const first_id = recovered.followup_id;
    recovered.observeReviewInput(try core.ReviewInput.init(a, repo, fixture_pull, base, try fake.reviewDiscussion(42)), false, repo.approvals);
    try t.expectEqual(core.Phase.complete, recovered.phase);

    thread.isResolved = false;
    fake.discussion = &.{thread};
    recovered.observeReviewInput(try core.ReviewInput.init(a, repo, fixture_pull, base, try fake.reviewDiscussion(42)), false, repo.approvals);
    try t.expectEqual(core.Phase.pending, recovered.phase);
    var entry: core.Entry = .{ .repo = repo, .jobs = (&recovered)[0..1] };
    const pending_id = recovered.followup_id;
    const previous_receipt = recovered.receipt;
    recovered.receipt = null;
    try entry.queue(a, fixture_pull, null);
    try t.expect(recovered.followup);
    try t.expectEqual(pending_id, recovered.followup_id);
    recovered.receipt = previous_receipt;
    recovered.phase = .failed;
    recovered.attempts = 6;
    try entry.queue(a, fixture_pull, null);
    try t.expectEqual(core.Phase.pending, recovered.phase);
    try t.expectEqual(@as(u8, 0), recovered.attempts);
    _ = (try core.run(a, &fake, repo, &recovered, .scheduled)).?;
    thread.isResolved = true;
    fake.discussion = &.{thread};
    recovered.observeReviewInput(try core.ReviewInput.init(a, repo, fixture_pull, base, try fake.reviewDiscussion(42)), false, repo.approvals);
    fake.offered = first_followup;
    _ = (try core.run(a, &fake, repo, &recovered, .scheduled)).?;
    try t.expectEqual(@as(usize, 4), fake.posts);
    try t.expect(!std.mem.eql(u8, &first_id, &recovered.followup_id));
    try t.expect(!std.mem.eql(u8, first_followup.body.?, fake.posted_result.?.body));
}

test "inline readback resumes from a persisted intent without posting again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .lose_inline_readback = true };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    try t.expectError(error.ReviewInlineReadbackMismatch, core.run(a, &fake, repo, &job, .scheduled));
    try t.expectEqual(core.Phase.uncertain, job.phase);
    try t.expectEqual(.pending, fake.saved_result.?.explanation.?.publication);
    try t.expect(fake.saved_result.?.explanation.?.github_review_id == null);
    try t.expectEqual(@as(usize, 1), job.expected_inline.?.len);
    var recovered = try io.parse(a, core.Job, try io.json(a, job));
    fake.lose_inline_readback = false;
    try t.expect((try core.run(a, &fake, repo, &recovered, .scheduled)) == null);
    try t.expectEqual(@as(usize, 1), fake.posts);
    try t.expectEqual(@as(usize, 2), fake.inline_readbacks);
    try t.expectEqual(core.Phase.complete, recovered.phase);
    try t.expect(recovered.expected_inline == null);
    try t.expectEqual(.verified, fake.saved_result.?.explanation.?.publication);
    try t.expectEqual(@as(?u64, 55), fake.saved_result.?.explanation.?.github_review_id);
}

test "a multi-review result identifies the reviewer and exact missing evidence" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const incomplete =
        \\{"complete":true,"coverage_gaps":["The pinned RPC read does not include the ProxyAdmin owner."],"summary":"Static review.","findings":[],"existing_open_findings":[],"non_blocking_threads":[]}
    ;
    var fake: Fake = .{ .a = a, .result = clean, .other_results = &.{incomplete} };
    const configured: core.Repo = .{ .name = repo.name, .login = repo.login, .additional_engines = &.{.claude}, .approvals = true };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    const preview = (try core.run(a, &fake, configured, &job, .{ .preview = .{} })).?;
    const detail = preview.explanation.?;
    try t.expectEqual(.COMMENT, preview.event);
    try t.expect(!detail.coverage.complete);
    try t.expectEqualSlices(std.meta.Child(@FieldType(core.Explanation, "blockers")), &.{.limited_coverage}, detail.blockers);
    try t.expect(detail.coverage.reviewers[0].complete);
    try t.expectEqual(core.Engine.claude, detail.coverage.reviewers[1].engine);
    try t.expectEqualStrings("The pinned RPC read does not include the ProxyAdmin owner.", detail.coverage.reviewers[1].gaps[0]);
    try t.expect(std.mem.indexOf(u8, preview.body, "claude reported incomplete coverage") != null);
    try t.expect(fake.saved_result == null);
    try t.expectEqual(@as(usize, 0), fake.posts);
}

test "persisted findings and pending receipt anchors outlive a review worker" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .lose_response = true };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    const prepared = (try core.prepare(a, &fake, repo, &job, .scheduled)).?;
    {
        var worker = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer worker.deinit();
        const review = try core.parseReview(worker.allocator(), finding);
        try t.expectError(error.GitHubPostUnconfirmed, core.finish(a, &fake, repo, &job, prepared, &.{.{ .engine = .codex, .review = review }}));
    }
    const state = try io.parse(a, core.Job, try io.json(a, job));
    try t.expectEqualStrings("src/watch.rs", state.expected_inline.?[0].path);
    try t.expectEqualStrings("src/watch.rs", state.last_review.?.notes[0].path.?);
    try t.expectEqualStrings("The cursor skips a height.", state.last_review.?.notes[0].reason.?);
}

test "rereview carries forward the previous head and evidence based thread disposition" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .result = assessed, .discussion = &.{open_nit} };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    const local = core.Repo{ .name = repo.name, .login = repo.login };
    _ = (try core.run(a, &fake, local, &job, .scheduled)).?;
    const loaded = try io.parse(a, core.Job, try io.json(a, job));
    var entry: core.Entry = .{ .repo = local, .jobs = try a.dupe(core.Job, &.{loaded}) };
    fake.target.headRefOid = changed;
    fake.previous_delta = "New changeset entry: fee config.";
    try entry.discover(a, &.{fake.target}, false);
    try t.expectEqual(@as(usize, 1), entry.jobs.len);
    try t.expectEqualStrings(head, entry.jobs[0].last_review.?.head);
    const prepared = (try core.prepare(a, &fake, local, &entry.jobs[0], .scheduled)).?;
    try t.expect(std.mem.indexOf(u8, prepared.context, "Start with the previous-to-current delta") != null);
    try t.expect(std.mem.indexOf(u8, prepared.context, fake.previous_delta) != null);
    try t.expect(std.mem.indexOf(u8, prepared.context, "\"disposition\":\"deferred\"") != null);
    try t.expect(std.mem.indexOf(u8, prepared.context, "Duplicate wakeups already coalesce") != null);
    try t.expectEqualStrings(changed, prepared.pr.headRefOid);
}

test "published prose drops dash punctuation and preserves command flags" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const verbose =
        \\{"complete":true,"summary":"Initial static pass.","findings":[{"severity":"P2","path":"src/watch.rs","line":20,"body":"When the cursor is missing — the command exits early. Check --resume and expires_at - 1."}],"existing_open_findings":[],"non_blocking_threads":[]}
    ;
    var fake: Fake = .{ .a = a, .result = verbose };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    const candidate = (try core.run(a, &fake, repo, &job, .{ .preview = .{} })).?;
    try t.expectEqualStrings("**P2.** When the cursor is missing, the command exits early. Check --resume and expires\\_at - 1.", candidate.comments[0].body);
    try t.expect(std.mem.indexOf(u8, candidate.body, "Initial static pass") == null);
}

test "screening keeps evidence requests when a risk lens needs stronger review" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const response = try io.fmt(a,
        \\{{"decision":{{"depth":"regular","performance":false,"reliability":true,"security":false}},"review":{s},"evidence_requests":[{{"path":"src/caller.zig","start_line":null,"end_line":null}}]}}
    , .{clean});
    const screening = try core.parseScreen(a, response);
    try t.expectEqual(.focused, screening.decision.depth);
    try t.expect(screening.decision.reliability);
    try t.expectEqualStrings("src/caller.zig", screening.evidence_requests[0].path);
}

test "truncated discussion withholds approval and new findings flag an earlier approval" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    var fake: Fake = .{
        .a = a,
        .result = clean,
        .comments = &.{.{ .author = .{ .login = "author" }, .body = "Cut short", .url = "note", .truncated = true }},
    };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    const preview = (try core.run(a, &fake, configured, &job, .{ .preview = .{} })).?;
    try t.expectEqual(core.Event.COMMENT, preview.event);
    try t.expect(std.mem.indexOf(u8, preview.body, "Review coverage was limited.") != null);

    fake.comments = &.{};
    fake.result = finding;
    fake.offered = .{ .id = 55, .commit_id = head, .state = "APPROVED", .user = .{ .login = repo.login }, .body = "Prior approval" };
    job.followup = true;
    job.followup_id = @splat(1);
    const result = (try core.run(a, &fake, configured, &job, .scheduled)).?;
    try t.expectEqual(core.Event.COMMENT, result.event);
    try t.expect(std.mem.indexOf(u8, result.body, "Reassess the earlier approval before merging.") != null);
    try t.expect(std.mem.startsWith(u8, fake.posted_result.?.body, "Reassess the earlier approval before merging."));
}

test "coverage-only rereviews and findings already on an open thread stay local" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .source_limited = true, .result = clean };
    var job: core.Job = .{ .number = 42, .head = head, .followup = true, .receipt = 31 };
    const partial = (try core.run(a, &fake, repo, &job, .scheduled)).?;
    try t.expectEqual(.local, partial.explanation.?.publication);
    try t.expect(!partial.explanation.?.coverage.complete);
    try t.expectEqual(@as(?u64, 31), job.receipt);
    try t.expectEqual(@as(usize, 0), fake.posts);

    fake.source_limited = false;
    fake.result = finding;
    var existing = open_nit;
    existing.diffSide = .RIGHT;
    existing.replies = &.{.{ .author = null, .body = "**P2.** The cursor skips a height.", .url = "existing" }};
    fake.discussion = &.{existing};
    job = .{ .number = 42, .head = head, .followup = true };
    const quiet = (try core.run(a, &fake, repo, &job, .scheduled)).?;
    try t.expectEqual(.local, quiet.explanation.?.publication);
    try t.expectEqual(@as(usize, 1), quiet.explanation.?.blockers.len);
    try t.expectEqual(.open_findings, quiet.explanation.?.blockers[0]);
    try t.expectEqual(@as(usize, 0), quiet.comments.len);
    try t.expectEqual(@as(usize, 0), fake.posts);
}

test "dropping optional image patch excerpts does not veto a covered approval" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const extra = try a.alloc(u8, core.review_context_limit);
    @memset(extra, 'Z');
    var fake: Fake = .{ .a = a, .optional_source = extra, .result = clean };
    var job: core.Job = .{ .number = 42, .head = head };
    const review = (try core.run(a, &fake, repo, &job, .{ .preview = .{} })).?;
    try t.expectEqual(.APPROVE, review.event);
    try t.expect(review.explanation.?.coverage.complete);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text, "Diff in src/watch.rs") != null);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text, "ZZZZ") == null);
}

test "a capacity sync requires the proposed value from a pinned resolved module" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const address = "0x1234567890abcdef1234567890abcdef12345678";
    var reading: @import("onchain.zig").Observation = .{
        .request = .{ .chain = "base", .address = address, .operation = .warp_rate_limit, .expected_value = "1500" },
        .block = 42,
        .value = "1500",
        .resolved_address = address,
    };
    var context: []const u8 = "review";
    try t.expect(!try core.appendOnchain(a, &context, &.{reading}));
    reading.value = "1501";
    try t.expect(try core.appendOnchain(a, &context, &.{reading}));
    reading.value = "1500";
    reading.resolved_address = null;
    try t.expect(try core.appendOnchain(a, &context, &.{reading}));
}

test "a same-head approval and its warning are not posted twice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    const approval: core.Prior = .{ .id = 30, .commit_id = head, .state = "APPROVED", .user = .{ .login = repo.login }, .body = null };
    var fake: Fake = .{ .a = a, .result = clean, .previous_reviews = &.{approval} };
    var job: core.Job = .{ .number = 42, .head = head, .followup = true, .receipt = 30 };
    const quiet = (try core.run(a, &fake, configured, &job, .scheduled)).?;
    try t.expectEqual(.APPROVE, quiet.event);
    try t.expectEqual(.local, quiet.explanation.?.publication);
    try t.expectEqual(@as(?u64, 30), job.receipt);

    const warning: core.Prior = .{
        .id = 31,
        .commit_id = head,
        .state = "COMMENTED",
        .user = .{ .login = repo.login },
        .body = "Reassess the earlier approval before merging.",
    };
    fake.previous_reviews = &.{ approval, warning };
    fake.discussion = &.{open_nit};
    fake.result =
        \\{"complete":true,"summary":"Still actionable.","findings":[],"existing_open_findings":["thread-1"],"non_blocking_threads":[]}
    ;
    job = .{ .number = 42, .head = head, .followup = true, .receipt = 31 };
    const unchanged = (try core.run(a, &fake, configured, &job, .scheduled)).?;
    try t.expectEqual(.local, unchanged.explanation.?.publication);
    try t.expectEqual(@as(usize, 0), fake.posts);
}

test "a clean rereview can approve again after the latest approval was dismissed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    const approval: core.Prior = .{ .id = 30, .commit_id = head, .state = "APPROVED", .user = .{ .login = repo.login }, .body = null };
    var dismissed = approval;
    dismissed.id = 31;
    dismissed.state = "DISMISSED";
    var fake: Fake = .{ .a = a, .result = clean, .previous_reviews = &.{ approval, dismissed } };
    var job: core.Job = .{ .number = 42, .head = head, .followup = true };
    const result = (try core.run(a, &fake, configured, &job, .scheduled)).?;
    try t.expectEqual(.APPROVE, result.event);
    try t.expectEqual(.verified, result.explanation.?.publication);
    try t.expectEqual(@as(usize, 1), fake.posts);
}

test "truncated replies only block approval on an open thread" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    for ([_]bool{ false, true }) |resolved| {
        var thread = open_nit;
        thread.isResolved = resolved;
        thread.truncated = true;
        var fake: Fake = .{ .a = a, .result = assessed, .discussion = &.{thread} };
        var job: core.Job = .{ .number = 42, .head = head, .followup = true };
        const result = (try core.run(a, &fake, configured, &job, .scheduled)).?;
        try t.expectEqual(if (resolved) core.Event.APPROVE else .COMMENT, result.event);
        try t.expectEqual(@as(usize, 1), result.explanation.?.coverage.truncated_threads);
        try t.expectEqual(@as(usize, if (resolved) 0 else 1), result.explanation.?.coverage.truncated_open_threads);
        try t.expectEqual(@as(usize, if (resolved) 1 else 0), fake.posts);
    }
}

test "a repeated unanchored finding on the same head stays local" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const unanchored =
        \\{"complete":true,"summary":"Static review.","findings":[{"severity":"P2","path":"src/watch.rs","line":21,"body":"The cursor skips a height."}],"existing_open_findings":[],"non_blocking_threads":[]}
    ;
    var fake: Fake = .{ .a = a, .result = unanchored };
    var job: core.Job = .{ .number = 42, .head = head };
    _ = (try core.run(a, &fake, repo, &job, .scheduled)).?;
    try t.expect(std.mem.startsWith(u8, fake.posted_result.?.body, "src/watch.rs:21."));
    job = .{ .number = 42, .head = head, .followup = true, .followup_id = @splat(1) };
    const result = (try core.run(a, &fake, repo, &job, .scheduled)).?;
    try t.expectEqual(.local, result.explanation.?.publication);
    try t.expectEqual(@as(usize, 1), fake.posts);
}

test "effective diff changes and human conversation comments trigger review" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try core.ReviewInput.init(a, repo, fixture_pull, base, .{});
    var moved = fixture_pull;
    moved.baseRefOid = changed;
    const advanced = try core.ReviewInput.init(a, repo, moved, base, .{});
    try t.expect(first.same(advanced));
    try t.expect(!first.same(try core.ReviewInput.init(a, repo, moved, changed, .{})));
    moved.baseRefName = "release";
    try t.expect(!first.same(try core.ReviewInput.init(a, repo, moved, base, .{})));

    const human = core.Reply{ .author = .{ .login = "author" }, .body = "New rollout information.", .url = "note", .updatedAt = "2026-11-23T15:00:00Z" };
    const own = core.Reply{ .author = .{ .login = repo.login }, .body = "Review", .url = "review", .updatedAt = "2026-11-23T15:00:00Z" };
    const discussion = core.Discussion{ .comments = &.{human} };
    try t.expect(!first.same(try core.ReviewInput.init(a, repo, fixture_pull, base, discussion)));
    try t.expect(discussion.changedAfter(repo.login, "2026-11-23T14:30:00Z"));
    try t.expect(!discussion.changedAfter(repo.login, "2026-11-23T15:30:00Z"));
    try t.expect((core.Discussion{ .comments = &.{own} }).changedAfter(repo.login, "2026-11-23T14:30:00Z"));

    const job: core.Job = .{ .number = fixture_pull.number, .head = head, .receipt = 55, .phase = .complete };
    const earlier = core.Prior{ .id = 55, .commit_id = head, .state = "COMMENTED", .user = .{ .login = repo.login }, .body = "", .submitted_at = "2026-11-23T14:30:00Z" };
    var manual = core.Prior{ .id = 56, .commit_id = head, .state = "APPROVED", .user = .{ .login = repo.login }, .body = "", .submitted_at = "2026-11-23T15:30:00Z" };
    try t.expect(job.legacyDiscussionChanged(repo.login, discussion, &.{earlier}));
    try t.expect(!job.legacyDiscussionChanged(repo.login, discussion, &.{ earlier, manual }));
    manual.commit_id = changed;
    try t.expect(job.legacyDiscussionChanged(repo.login, discussion, &.{ earlier, manual }));
}

test "description-only rereview reuses a proven source plan and suppresses repeat approval" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    const patch = "diff --git a/watch.rs b/watch.rs\n--- a/watch.rs\n+++ b/watch.rs\n@@ -1 +1 @@\n-old source\n+new source\n";
    const evidence = "Merge-base diff:\n" ++ patch;
    var fake: Fake = .{
        .a = a,
        .result = clean,
        .pinned_snapshot = .{
            .merge_base = base,
            .evidence = evidence,
            .diff = .{ .patch = patch, .start = evidence.len - patch.len, .end = evidence.len },
            .source_tree = "d" ** 40,
        },
    };
    var job: core.Job = .{ .number = 42, .head = head };
    const prior = (try core.run(a, &fake, configured, &job, .scheduled)).?;
    try t.expectEqual(.APPROVE, prior.event);
    try t.expectEqual(.verified, job.verdict.?.publication);
    try t.expectEqual(.posted, job.verdict.?.disposition);
    try t.expect(job.last_review.?.clean_source != null);

    fake.target.body = "Clarify deployment sequencing.";
    job.observeReviewInput(try core.ReviewInput.init(a, configured, fake.target, base, .{}), false, configured.approvals);
    try t.expectEqual(.pending, job.phase);
    const followup = (try core.run(a, &fake, configured, &job, .scheduled)).?;
    const plan = followup.explanation.?.coverage.coverage_plan.?;
    try t.expectEqual(.discussion, plan.scope);
    try t.expectEqual(@as(usize, 1), plan.reused_source_units);
    try t.expectEqual(@as(usize, 0), plan.planned_source_units);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text, "Clarify deployment sequencing.") != null);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text, "+new source") == null);
    try t.expectEqual(.already_published, job.verdict.?.disposition);
    try t.expectEqual(@as(usize, 1), fake.posts);

    // A commit message amendment may change the SHA without changing any source.
    fake.target.headRefOid = changed;
    var amended_job: core.Job = .{ .number = 42, .head = changed, .last_review = job.last_review };
    const amended = (try core.prepare(a, &fake, configured, &amended_job, .scheduled)).?;
    try t.expectEqual(.discussion, amended.coverage_plan.?.scope);
    const amended_review = (try core.finish(a, &fake, configured, &amended_job, amended, &.{
        .{ .engine = .codex, .review = try core.parseReview(a, clean) },
    })).?;
    try t.expectEqualStrings(changed, amended_review.commit_id);
    try t.expectEqual(.verified, amended_review.explanation.?.publication);
    try t.expectEqual(@as(usize, 2), fake.posts);

    fake.target.headRefOid = head;
    fake.target.body = "Clarify the new branch's sequence.";
    fake.pinned_snapshot.?.merge_base = changed;
    job.observeReviewInput(try core.ReviewInput.init(a, configured, fake.target, changed, .{}), false, configured.approvals);
    const rebased = (try core.prepare(a, &fake, configured, &job, .scheduled)).?;
    try t.expectEqual(.full, rebased.coverage_plan.?.scope);
    try t.expect(std.mem.indexOf(u8, rebased.context, "+new source") != null);
}

test "standalone thanks neither invalidates an approval nor wakes a finished review" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    const ack: core.Reply = .{ .author = .{ .login = "author" }, .body = "  Thank you!\n", .url = "ack" };
    const conversation = [_]core.Reply{ack} ** 7;
    var fake: Fake = .{ .a = a, .result = clean, .comments = conversation[0..6], .late_comments = &conversation };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    const result = (try core.run(a, &fake, configured, &job, .scheduled)).?;
    try t.expectEqual(core.Event.APPROVE, result.event);
    try t.expectEqual(@as(usize, 1), fake.reviews_run);
    try t.expectEqual(@as(usize, 1), fake.posts);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text, "Thank you!") == null);

    const after = try core.ReviewInput.init(a, configured, fixture_pull, base, .{ .comments = &conversation });
    job.observeReviewInput(after, false, configured.approvals);
    try t.expectEqual(core.Phase.complete, job.phase);

    var meaningful = ack;
    meaningful.body = "Thanks! This deploys to production after all.";
    const edited = try core.ReviewInput.init(a, configured, fixture_pull, base, .{ .comments = &.{meaningful} });
    job.observeReviewInput(edited, false, configured.approvals);
    try t.expectEqual(core.Phase.pending, job.phase);

    var seven: Fake = .{ .a = a, .result = clean, .comments = &conversation };
    var seven_job: core.Job = .{ .number = fixture_pull.number, .head = head };
    try t.expectEqual(core.Event.APPROVE, (try core.run(a, &seven, configured, &seven_job, .scheduled)).?.event);
}

test "an operator reply is material while its own inline root and legacy receipt stay stable" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const own: core.Reply = .{ .author = .{ .login = repo.login }, .body = "Finding", .url = "root" };
    const operator: core.Reply = .{
        .author = .{ .login = repo.login },
        .body = "We tested the rollback. The issue is still valid but we can defer it.",
        .url = "operator",
        .updatedAt = "2026-11-23T15:30:00Z",
    };
    var thread: core.Thread = .{ .id = "thread", .isResolved = false, .isOutdated = false, .path = "src/watch.rs", .line = 20, .replies = &.{own} };
    const first = try core.ReviewInput.init(a, repo, fixture_pull, base, .{});
    const after_post = try core.ReviewInput.init(a, repo, fixture_pull, base, .{ .threads = &.{thread} });
    try t.expect(first.same(after_post));

    var legacy = first;
    legacy.material_discussion = null;
    var job = try io.parse(a, core.Job, try io.json(a, core.Job{
        .number = fixture_pull.number,
        .head = head,
        .phase = .complete,
        .review_input = legacy,
    }));
    job.observeReviewInput(after_post, false, repo.approvals);
    try t.expectEqual(core.Phase.complete, job.phase);
    try t.expectEqual(legacy.discussion, job.review_input.?.discussion);
    try t.expectEqual(after_post.material_discussion, job.review_input.?.material_discussion);

    thread.replies = &.{ own, operator };
    const discussion = core.Discussion{ .threads = &.{thread} };
    const after_reply = try core.ReviewInput.init(a, repo, fixture_pull, base, discussion);
    try t.expectEqual(legacy.discussion, after_reply.discussion);
    job.observeReviewInput(after_reply, false, repo.approvals);
    try t.expectEqual(core.Phase.pending, job.phase);

    job.phase = .complete;
    job.review_input = legacy;
    job.receipt = 55;
    const previous: core.Prior = .{
        .id = 55,
        .commit_id = head,
        .state = "COMMENTED",
        .user = .{ .login = repo.login },
        .body = "",
        .submitted_at = "2026-11-23T14:30:00Z",
    };
    const changed_after_receipt = job.legacyDiscussionChanged(repo.login, discussion, &.{previous});
    try t.expect(changed_after_receipt);
    job.observeReviewInput(after_reply, changed_after_receipt, repo.approvals);
    try t.expectEqual(core.Phase.pending, job.phase);
    try t.expect(job.review_input == null);
}

test "complete clean reviews approve independently of GitHub checks and mergeability" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    const cases = [_]struct {
        checks: @FieldType(core.Pull, "statusCheckRollup"),
        merge_state: []const u8 = "BLOCKED",
    }{
        .{ .checks = &.{.{ .status = "QUEUED" }} },
        .{ .checks = &.{.{ .status = "COMPLETED", .conclusion = "FAILURE" }} },
        .{ .checks = null, .merge_state = "UNKNOWN" },
        .{ .checks = &.{}, .merge_state = "DIRTY" },
    };
    for (cases) |case| {
        var fake: Fake = .{ .a = a, .result = clean };
        fake.target.statusCheckRollup = case.checks;
        fake.target.mergeStateStatus = case.merge_state;
        try t.expect(!core.checksPassed(fake.target));
        var job: core.Job = .{ .number = fixture_pull.number, .head = head };
        const result = (try core.run(a, &fake, configured, &job, .scheduled)).?;
        try t.expectEqual(core.Event.APPROVE, result.event);
        try t.expectEqualStrings(head, result.commit_id);
        try t.expect(std.mem.indexOf(u8, result.body, "Approval checks") == null);
        try t.expect(!job.awaiting_checks);

        fake.target.statusCheckRollup = &.{.{ .status = "COMPLETED", .conclusion = "SUCCESS" }};
        fake.target.mergeStateStatus = "CLEAN";
        job.observeReviewInput(try core.ReviewInput.init(a, configured, fake.target, base, .{}), false, configured.approvals);
        try t.expectEqual(core.Phase.complete, job.phase);
        try t.expectEqual(@as(usize, 1), fake.posts);
    }
}

test "an old approval held for CI is reviewed once even while checks are pending" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    var fake: Fake = .{
        .a = a,
        .result = clean,
        .offered = .{ .id = 55, .commit_id = head, .state = "COMMENTED", .user = .{ .login = repo.login }, .body = "Old review." },
    };
    fake.target.statusCheckRollup = &.{.{ .status = "QUEUED" }};
    const input = try core.ReviewInput.init(a, configured, fake.target, base, .{});
    var job = try io.parse(a, core.Job, try io.json(a, core.Job{
        .number = fixture_pull.number,
        .head = head,
        .phase = .complete,
        .receipt = 55,
        .review_input = input,
        .awaiting_checks = true,
    }));
    job.observeReviewInput(input, false, false);
    try t.expectEqual(core.Phase.complete, job.phase);
    try t.expect(job.awaiting_checks);
    job = try io.parse(a, core.Job, try io.json(a, job));

    job.observeReviewInput(input, false, configured.approvals);
    try t.expectEqual(core.Phase.pending, job.phase);
    const result = (try core.run(a, &fake, configured, &job, .scheduled)).?;
    try t.expectEqual(core.Event.APPROVE, result.event);
    try t.expect(!job.awaiting_checks);
    job.observeReviewInput(input, false, configured.approvals);
    try t.expectEqual(core.Phase.complete, job.phase);
    try t.expectEqual(@as(usize, 1), fake.posts);
}

test "a changed stack ancestor prevents publication and prompt distinguishes inherited evidence" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{
        .a = a,
        .move_ancestor_during_review = true,
        .inherited = .{ .ancestors = &.{.{
            .number = 2,
            .head = changed,
            .base = base,
            .state = "OPEN",
            .diff_excerpt = "Parent diff",
            .review_excerpt = "Parent finding",
        }} },
    };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    try t.expectError(error.StackChanged, core.run(a, &fake, repo, &job, .scheduled));
    try t.expectEqual(@as(usize, 0), fake.posts);
    try t.expectEqual(core.Phase.pending, job.phase);
    const inherited_at = std.mem.indexOf(u8, fake.prompt_text, "Ancestor context (untrusted JSON") orelse
        return error.MissingAncestorContext;
    const own_at = std.mem.indexOf(u8, fake.prompt_text, "Evidence (untrusted JSON)") orelse
        return error.MissingTargetContext;
    try t.expect(inherited_at < own_at);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text[inherited_at..own_at], "Parent diff") != null);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text[inherited_at..own_at], "Parent finding") != null);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text[own_at..], "Diff in src/watch.rs") != null);
}

test "late native stack membership aborts before the durable publication intent" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .join_native_before_post = true };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    try t.expectError(error.StackChanged, core.run(a, &fake, repo, &job, .scheduled));
    try t.expectEqual(@as(usize, 0), fake.posts);
    try t.expectEqual(core.Phase.pending, job.phase);
    try t.expect(job.event == null);
    try t.expect(job.receipt == null);
}

test "discovery baselines open PRs and queues new draft heads and drafts becoming ready" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    var entry = core.Entry{ .repo = repo };
    var draft = fixture_pull;
    draft.number = 43;
    draft.isDraft = true;
    try entry.discover(a, &.{ fixture_pull, draft }, true);
    try t.expectEqual(@as(usize, 2), entry.seen.len);
    try t.expectEqual(@as(usize, 0), entry.jobs.len);

    try entry.queue(a, fixture_pull, null);
    try t.expectEqual(@as(usize, 1), entry.jobs.len);
    draft.isDraft = false;
    try entry.discover(a, &.{ fixture_pull, draft }, false);
    try t.expectEqual(@as(usize, 2), entry.jobs.len);

    var updated = fixture_pull;
    updated.headRefOid = changed;
    var new = fixture_pull;
    new.number = 44;
    new.isDraft = true;
    try entry.discover(a, &.{ updated, draft, new }, false);
    try t.expectEqual(@as(usize, 3), entry.jobs.len);
    try t.expectEqual(@as(u32, 43), entry.jobs[0].number);
    try t.expectEqualStrings(changed, entry.jobs[1].head);
    try t.expectEqual(@as(u32, 44), entry.jobs[2].number);
    try entry.discover(a, &.{ updated, draft, new }, false);
    try t.expectEqual(@as(usize, 3), entry.jobs.len);
}

test "a push preserves an unfinished all-model request without reusing the old head passes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry: core.Entry = .{ .repo = repo };
    try entry.queue(a, fixture_pull, .{ .all_models = true });
    entry.jobs[0].route_progress = .{ .fingerprint = @splat(0), .all_models = true };
    var updated = fixture_pull;
    updated.headRefOid = changed;
    try entry.discover(a, &.{updated}, false);
    try t.expectEqual(@as(usize, 1), entry.jobs.len);
    try t.expectEqualStrings(changed, entry.jobs[0].head);
    try t.expect(entry.jobs[0].options.all_models);
    try t.expect(entry.jobs[0].route_progress == null);
    entry.jobs[0].phase = .complete;
    updated.headRefOid = head;
    try entry.discover(a, &.{updated}, false);
    try t.expect(!entry.jobs[0].options.all_models);
}

test "upgrading baselines existing drafts and reviews their next heads" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = try io.parse(a, core.Entry, "{\"repo\":{\"name\":\"example/repo\",\"login\":\"reviewer\"},\"seen\":[{\"number\":42,\"head\":\"" ++ head ++ "\"}]}");
    var draft = fixture_pull;
    draft.number = 43;
    draft.isDraft = true;
    try entry.discover(a, &.{ fixture_pull, draft }, false);
    try t.expectEqual(@as(usize, 0), entry.jobs.len);
    draft.headRefOid = changed;
    try entry.discover(a, &.{ fixture_pull, draft }, false);
    try t.expectEqual(@as(usize, 1), entry.jobs.len);
    try t.expectEqual(@as(u32, 43), entry.jobs[0].number);
}

test "draft findings publish while clean draft approvals wait until ready" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    var draft = fixture_pull;
    draft.isDraft = true;

    var with_issue: Fake = .{ .a = a, .target = draft };
    var issue_job: core.Job = .{ .number = 42, .head = head };
    _ = try core.run(a, &with_issue, configured, &issue_job, .scheduled);
    try t.expectEqual(@as(usize, 1), with_issue.posts);
    try t.expectEqual(.COMMENT, with_issue.posted_result.?.event);
    try t.expect(!issue_job.awaiting_ready);

    const patch = "diff --git a/watch.rs b/watch.rs\n--- a/watch.rs\n+++ b/watch.rs\n@@ -1 +1 @@\n-old source\n+new source\n";
    const pinned: core.Snapshot = .{
        .merge_base = base,
        .evidence = patch,
        .diff = .{ .patch = patch, .start = 0, .end = patch.len },
        .source_tree = "d" ** 40,
    };
    var covered: Fake = .{ .a = a, .target = draft, .result = clean, .pinned_snapshot = pinned };
    var job: core.Job = .{ .number = 42, .head = head };
    const result = (try core.run(a, &covered, configured, &job, .scheduled)).?;
    try t.expectEqual(.local, result.explanation.?.publication);
    try t.expectEqualSlices(@TypeOf(result.explanation.?.blockers[0]), &.{.draft}, result.explanation.?.blockers);
    try t.expect(job.awaiting_ready);
    try t.expectEqual(@as(usize, 0), covered.posts);
    job.observeReviewInput(try core.ReviewInput.init(a, configured, draft, base, .{}), false, true);
    try t.expectEqual(.complete, job.phase);

    covered.target = fixture_pull;
    const ready_input = try core.ReviewInput.init(a, configured, fixture_pull, base, .{});
    job.observeReviewInput(ready_input, false, true);
    try t.expectEqual(.pending, job.phase);
    const published = (try core.run(a, &covered, configured, &job, .scheduled)).?;
    try t.expectEqual(@as(usize, 1), covered.posts);
    try t.expectEqual(@as(usize, 1), covered.reviews_run);
    try t.expectEqual(.APPROVE, covered.posted_result.?.event);
    const plan = published.explanation.?.coverage.coverage_plan.?;
    try t.expectEqual(.publication, plan.scope);
    try t.expectEqual(@as(usize, 0), plan.planned_sections);
    try t.expectEqual(plan.required_source_units, plan.reused_source_units);
    job.observeReviewInput(ready_input, false, true);
    try t.expectEqual(.complete, job.phase);

    var edited: Fake = .{ .a = a, .target = draft, .result = clean, .pinned_snapshot = pinned };
    var edited_job: core.Job = .{ .number = 42, .head = head };
    _ = try core.run(a, &edited, configured, &edited_job, .scheduled);
    edited.target.isDraft = false;
    edited.target.body = "Updated rollout plan.";
    edited_job.observeReviewInput(try core.ReviewInput.init(a, configured, edited.target, base, .{}), false, true);
    const edited_result = (try core.run(a, &edited, configured, &edited_job, .scheduled)).?;
    try t.expectEqual(.discussion, edited_result.explanation.?.coverage.coverage_plan.?.scope);
    try t.expectEqual(@as(usize, 2), edited.reviews_run);

    // A new thread at publication time invalidates the no-thread proof.
    var late: Fake = .{ .a = a, .target = draft, .result = clean, .pinned_snapshot = pinned };
    var late_job: core.Job = .{ .number = 42, .head = head };
    _ = try core.run(a, &late, configured, &late_job, .scheduled);
    late.target.isDraft = false;
    late.thread_reads = 0;
    late.late_discussion = &.{.{
        .id = "late",
        .isResolved = false,
        .isOutdated = false,
        .path = "watch.rs",
        .line = 1,
        .replies = &.{.{ .author = .{ .login = "automation[bot]" }, .body = "Failure in rollout signal.", .url = "late" }},
    }};
    late_job.observeReviewInput(ready_input, false, true);
    try t.expectError(error.ThreadsChanged, core.run(a, &late, configured, &late_job, .scheduled));
    try t.expectEqual(@as(usize, 0), late.posts);
}

test "overflow source sections retain full diff coverage without claiming to assess threads" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    const header = "diff --git a/watch.rs b/watch.rs\n--- a/watch.rs\n+++ b/watch.rs\n";
    const other = "diff --git a/other.rs b/other.rs\n--- a/other.rs\n+++ b/other.rs\n";
    const first = "@@ -1 +1 @@\n+" ++ "a" ** 22_000 ++ "\n";
    const last = "@@ -20 +20 @@\n+" ++ "b" ** 50_000 ++ "\n";
    const prefix = "Merge-base diff:\n";
    const replies = [_]core.Reply{.{
        .author = .{ .login = "reviewer" },
        .body = "Complete thread context. " ++ "c" ** 2_270,
        .url = "replies",
    }} ** 17;
    const thread: core.Thread = .{ .id = "open-thread", .isResolved = false, .isOutdated = false, .path = "watch.rs", .line = 1, .replies = &replies };
    const ignored =
        \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":[],"non_blocking_threads":[{"id":"open-thread","reason":"An unsupported conclusion from a source-only pass."}]}
    ;
    const verified =
        \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":[],"non_blocking_threads":[{"id":"open-thread","reason":"A checked conclusion from the section that has the thread."}]}
    ;
    const blocked =
        \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":["open-thread"],"non_blocking_threads":[]}
    ;
    const cases = [_]struct { response: []const u8, event: core.Event, early_overflow: bool = false, only_source: bool = false }{
        .{ .response = clean, .event = .COMMENT },
        .{ .response = verified, .event = .APPROVE, .early_overflow = true },
        .{ .response = blocked, .event = .COMMENT },
        .{ .response = verified, .event = .COMMENT, .only_source = true },
    };
    for (cases) |case| {
        const patch = if (case.only_source) header ++ last ++ other ++ last else if (case.early_overflow) other ++ last ++ header ++ first else header ++ first ++ other ++ last;
        const evidence = try std.mem.concat(a, u8, &.{ prefix, patch[0..22_000] });
        var fake: Fake = .{
            .a = a,
            .discussion = &.{thread},
            .pinned_snapshot = .{
                .merge_base = base,
                .evidence = evidence,
                .diff = .{ .patch = patch, .start = prefix.len, .end = evidence.len },
                .limited = true,
                .coverage_reasons = &.{core.diff_byte_limit_reason},
            },
        };
        var job: core.Job = .{ .number = 42, .head = head };
        const prepared = (try core.prepare(a, &fake, configured, &job, .scheduled)).?;
        try t.expectEqual(@as(usize, 2), prepared.sections.len);
        try t.expectEqual(case.only_source, prepared.snap.limited);
        try t.expectEqual(@as(usize, 2), prepared.coverage_plan.?.planned_source_units);
        const thread_index: usize = if (case.early_overflow) 1 else 0;
        const source_index = 1 - thread_index;
        try t.expectEqual(case.only_source, prepared.sections[thread_index].source_only);
        try t.expect(prepared.sections[source_index].source_only);
        try t.expectEqual(!case.only_source, std.mem.indexOf(u8, try core.screenPrompt(a, prepared), "Complete thread context.") != null);
        try t.expect(std.mem.indexOf(u8, prepared.sections[source_index].context, "Complete thread context.") == null);
        if (case.early_overflow) try t.expectEqualStrings(other ++ last, prepared.sections[0].patch);

        const plan: adaptive.Plan = .{
            .repo = configured,
            .providers = prepared.engines,
            .prepared = prepared,
            .screen = .{ .ask_model = false, .floor = .{} },
            .start_limit = 2,
            .progress = .{ .fingerprint = @splat(0), .sections = .{ .finished_mask = 0, .checkpoint = try .capture(a, configured, prepared) } },
        };
        var outcomes: [2]adaptive.SectionOutcome = undefined;
        for (&outcomes, 0..) |*outcome, index| {
            const raw = if (index == thread_index) case.response else ignored;
            const results = try a.dupe(core.ReviewerResult, &.{.{ .engine = .codex, .review = try core.parseReview(a, raw) }});
            const progress: core.RouteProgress = .{ .fingerprint = @splat(0), .results = results };
            outcome.* = .{
                .task = .{ .index = index, .progress = progress },
                .review = .{ .progress = progress, .report = .{
                    .mode = .fixed,
                    .suggested = .{},
                    .applied = .{},
                    .providers = &.{.codex},
                    .screen_ms = 0,
                    .review_ms = 0,
                } },
            };
        }
        const merged = try adaptive.mergeParallelSections(a, plan, &outcomes);
        const result = (try core.finish(a, &fake, configured, &job, prepared, merged.review_results.?)).?;
        try t.expectEqual(case.event, result.event);
        try t.expectEqual(@as(usize, @intFromBool(case.event == .APPROVE)), fake.posts);
    }
}

test "publishes one commit-bound comment, verifies it, and deduplicates a second review" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    var fake: Fake = .{ .a = a };
    var work: core.Job = .{ .number = fixture_pull.number, .head = head };
    _ = try core.run(a, &fake, repo, &work, .scheduled);
    try t.expectEqual(.complete, work.phase);
    try t.expectEqual(@as(?u64, 55), work.receipt);
    try t.expectEqual(@as(usize, 1), fake.posts);
    try t.expectEqual(@as(usize, 1), fake.readbacks);
    const payload = fake.posted_result.?;
    try t.expectEqualStrings(head, payload.commit_id);
    try t.expect(std.mem.startsWith(u8, payload.body, "<!-- talos:review:"));
    try t.expectEqual(@as(usize, 1), payload.comments.len);
    try t.expectEqual(@as(u32, 20), payload.comments[0].line);

    work = .{ .number = fixture_pull.number, .head = head };
    try t.expectEqual(@as(?core.Result, null), try core.run(a, &fake, repo, &work, .scheduled));
    try t.expectEqual(@as(usize, 1), fake.posts);
    try t.expectEqual(@as(usize, 1), fake.reviews_run);
}

test "multiple reviewers produce one verified review with one comment per anchor" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    var configured = repo;
    configured.engine = .claude;
    configured.additional_engines = &.{ .codex, .kimi };
    configured.approvals = true;
    const same_finding =
        \\{"complete":true,"summary":"Second pass.","findings":[{"severity":"P1","path":"src/watch.rs","line":20,"body":"The cursor skips a height."}],"existing_open_findings":["unresolved","resolved"],"non_blocking_threads":[]}
    ;
    const distinct_finding =
        \\{"complete":true,"summary":"Third pass.","findings":[{"severity":"P2","path":"src/watch.rs","line":20,"body":"The cursor is saved before processing succeeds."},{"severity":"P3","path":"src/watch.rs","line":40,"body":"The log omits the cursor."}],"existing_open_findings":["unresolved"],"non_blocking_threads":[]}
    ;
    var fake = Fake{
        .a = a,
        .other_results = &.{ same_finding, distinct_finding },
        .discussion = &.{
            .{ .id = "unresolved", .isResolved = false, .isOutdated = false, .path = "src/watch.rs", .line = 20, .replies = &.{} },
            .{ .id = "resolved", .isResolved = true, .isOutdated = false, .path = "src/watch.rs", .line = 20, .replies = &.{} },
        },
    };
    var job = core.Job{ .number = 42, .head = head };
    const review = (try core.run(a, &fake, configured, &job, .scheduled)).?;
    try t.expectEqualSlices(core.Engine, &.{ .claude, .codex, .kimi }, &fake.reviewed_engines);
    try t.expectEqual(core.Event.COMMENT, review.event);
    try t.expectEqual(@as(usize, 1), review.comments.len);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, review.comments[0].body, "The cursor skips a height."));
    try t.expect(std.mem.indexOf(u8, review.comments[0].body, "**P1.** The cursor skips a height.") != null);
    try t.expect(std.mem.indexOf(u8, review.comments[0].body, "The cursor is saved before processing succeeds.") != null);
    try t.expect(std.mem.indexOf(u8, review.body, "src/watch.rs:40") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, review.body, "1 existing finding still open. unresolved"));
    try t.expect(std.mem.startsWith(u8, fake.posted_result.?.body, "src/watch.rs:40."));
    try t.expect(std.mem.indexOf(u8, fake.posted_result.?.body, "existing finding") == null);
    try t.expect(std.mem.indexOf(u8, review.body, "Second pass.") == null);
    try t.expect(std.mem.indexOf(u8, review.body, "Third pass.") == null);
    try t.expectEqual(@as(usize, 1), fake.posts);
    try t.expectEqual(@as(usize, 1), fake.readbacks);
    var duplicate = core.Job{ .number = 42, .head = head };
    try t.expect((try core.run(a, &fake, configured, &duplicate, .scheduled)) == null);
    try t.expectEqual(@as(usize, 1), fake.posts);
    try t.expectEqual(@as(usize, 3), fake.reviews_run);
}

test "every configured reviewer must succeed and report complete coverage for approval" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    var configured = repo;
    configured.additional_engines = &.{.claude};
    configured.approvals = true;
    const incomplete =
        \\{"complete":false,"summary":"Incomplete coverage.","findings":[],"existing_open_findings":[],"non_blocking_threads":[]}
    ;
    var job = core.Job{ .number = 42, .head = head };
    var failing = Fake{ .a = a, .result = clean, .fail_engine = .claude };
    try t.expectError(error.ClaudeFailed, core.run(a, &failing, configured, &job, .scheduled));
    try t.expectEqual(@as(usize, 0), failing.posts);
    try t.expectEqual(core.Phase.pending, job.phase);
    var invalid = Fake{ .a = a, .result = clean, .other_results = &.{"{}"} };
    try t.expectError(error.InvalidReview, core.run(a, &invalid, configured, &job, .scheduled));
    try t.expectEqual(@as(usize, 0), invalid.posts);
    var partial = Fake{ .a = a, .result = clean, .other_results = &.{incomplete} };
    const preview = (try core.run(a, &partial, configured, &job, .{ .preview = .{} })).?;
    try t.expectEqual(core.Event.COMMENT, preview.event);
    try t.expect(std.mem.indexOf(u8, preview.body, "Review coverage was limited.") != null);
    var unanimous = Fake{ .a = a, .result = clean };
    const approved = (try core.run(a, &unanimous, configured, &job, .scheduled)).?;
    try t.expectEqual(core.Event.APPROVE, approved.event);
    try t.expectEqual(@as(usize, 1), unanimous.posts);
}

test "dry runs never post and comments and approvals are independent" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    var fake: Fake = .{ .a = a };
    var permissions = repo;
    permissions.comments = false;
    permissions.approvals = true;
    var work: core.Job = .{ .number = fixture_pull.number, .head = head };
    _ = try core.run(a, &fake, repo, &work, .{ .preview = .{} });
    try t.expectEqual(.pending, work.phase);
    _ = try core.run(a, &fake, permissions, &work, .scheduled);
    try t.expectEqual(@as(usize, 0), fake.posts);
    work = .{ .number = fixture_pull.number, .head = head };
    fake.result = clean;
    _ = try core.run(a, &fake, permissions, &work, .scheduled);
    try t.expectEqual(core.Event.APPROVE, fake.posted_result.?.event);
}

test "head and base changes during analysis prevent any publication" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    for ([_]@FieldType(Fake, "move_during_review"){ .head, .base, .base_ref, .draft }) |move| {
        var fake: Fake = .{ .a = a, .move_during_review = move };
        var work: core.Job = .{ .number = fixture_pull.number, .head = head };
        try t.expectError(error.TargetChanged, core.run(a, &fake, repo, &work, .scheduled));
        try t.expectEqual(@as(usize, 0), fake.posts);
        try t.expectEqual(.pending, work.phase);
    }
}

test "restart reconciles an ambiguous post or failed readback without sending a duplicate" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    const dir_path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(dir_path) catch {};
    var db = try store.Store.open(a, dir_path);
    defer db.dir.close();

    for ([_]bool{ true, false }) |lose_response| {
        var entry = core.Entry{ .repo = repo };
        try entry.queue(a, fixture_pull, null);
        var state: store.State = .{};
        try state.add(a, entry);
        var remote: Fake = .{
            .a = a,
            .db = db,
            .state = &state,
            .lose_response = lose_response,
            .lose_readback = !lose_response,
        };
        const err = if (lose_response) error.GitHubPostUnconfirmed else error.GitHubReadbackFailed;
        try t.expectError(err, core.run(a, &remote, repo, &state.entries[0].jobs[0], .scheduled));

        var restart = try db.load();
        remote.state = &restart;
        remote.lose_response = false;
        remote.lose_readback = false;
        const job = &restart.entries[0].jobs[0];
        try t.expectEqual(.uncertain, job.phase);
        try t.expectEqual(if (lose_response) @as(?u64, null) else 55, job.receipt);
        _ = try core.run(a, &remote, repo, job, .scheduled);
        try t.expectEqual(@as(usize, 1), remote.posts);
        try t.expectEqual(.complete, (try db.load()).entries[0].jobs[0].phase);
    }
}

test "no visible receipt leaves the intent uncertain and backs off" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    var fake: Fake = .{ .a = a };
    var entry = core.Entry{ .repo = repo };
    try entry.queue(a, fixture_pull, null);
    const job = &entry.jobs[0];
    job.phase = .uncertain;
    job.event = .COMMENT;
    for (0..6) |attempt| {
        const now: i64 = @intCast(attempt * 1000);
        try t.expectError(error.PublicationUnconfirmed, core.run(a, &fake, repo, job, .scheduled));
        try core.recordFailure(&entry, a, job, now, error.PublicationUnconfirmed);
        try t.expect(entry.due(now) == null);
    }
    try t.expect(entry.due(100_000) == null);
    try t.expectEqual(@as(usize, 0), fake.posts);
    try t.expectEqual(.uncertain, job.phase);
    try t.expectEqual(@as(usize, 6), entry.errors.len);
}

test "Hyperlane PR 10122 resolved reorg acceptance reaches the model without resurfacing as an open finding" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    const threads: []const core.Thread = &.{
        .{
            .id = "resolved-reorg",
            .isResolved = true,
            .isOutdated = false,
            .path = "src/watch.rs",
            .line = 20,
            .replies = &.{
                .{ .author = .{ .login = "reviewer" }, .body = "A reorg between polls may be missed.", .url = "https://github.com/hyperlane-xyz/hyperlane-monorepo/pull/10122#discussion_r1" },
                .{ .author = .{ .login = "author" }, .body = "The polling tradeoff is intentional and accepted.", .url = "https://github.com/hyperlane-xyz/hyperlane-monorepo/pull/10122#discussion_r2" },
            },
        },
        .{
            .id = "open-different-finding",
            .isResolved = false,
            .isOutdated = false,
            .path = "src/watch.rs",
            .line = 30,
            .replies = &.{},
        },
    };
    var fixture = fixture_pull;
    fixture.number = 10122;
    var fixture_repo = repo;
    fixture_repo.name = "hyperlane-xyz/hyperlane-monorepo";
    var fake: Fake = .{
        .a = a,
        .target = fixture,
        .discussion = threads,
        .result =
        \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":["resolved-reorg","open-different-finding"],"non_blocking_threads":[]}
        ,
    };
    var work: core.Job = .{ .number = fixture.number, .head = head };
    const payload = (try core.run(a, &fake, fixture_repo, &work, .{ .preview = .{} })).?;
    try t.expect(std.mem.indexOf(u8, fake.prompt_text, "The polling tradeoff is intentional and accepted.") != null);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text, "\"isResolved\":true") != null);
    try t.expect(std.mem.indexOf(u8, payload.body, "open-different-finding") != null);
    try t.expect(std.mem.indexOf(u8, payload.body, "resolved-reorg") == null);
    try t.expectEqual(@as(usize, 0), payload.comments.len);
}

test "strict result validation rejects extra keys and invalid paths" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    try t.expectError(error.InvalidReview, core.parseReview(a,
        \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":[],"non_blocking_threads":[],"command":"test"}
    ));
    try t.expectError(error.InvalidReview, core.parseReview(a,
        \\{"complete":true,"summary":"Static review.","findings":[{"severity":"P2","path":"../secrets","line":20,"body":"x"}],"existing_open_findings":[],"non_blocking_threads":[]}
    ));
}

test "a second process cannot acquire the watcher lock" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var db = try store.Store.open(a, path);
    defer db.dir.close();
    const lock = try db.lock();
    try t.expectError(error.AlreadyRunning, db.lock());
    lock.close();
    const reclaimed = try db.lock();
    reclaimed.close();
}

test "subprocesses return bounded output and time out" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    var env = std.process.EnvMap.init(a);
    const command: io.Command = .{ .a = a, .env = &env, .cwd = path, .dir = dir };
    try t.expectEqualStrings("prompt", try command.run(&.{"/bin/cat"}, "prompt", 2));
    _ = try command.run(&.{ "/bin/sh", "-c", "test \"$$\" -eq \"$(/bin/ps -o pgid= -p \"$$\")\"" }, "", 2);
    try t.expectError(error.SubprocessTimeout, command.run(&.{ "/bin/sleep", "5" }, "", 1));
}

test "v0 registration upgrades without its checkout and preserves publication intent" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    {
        var legacy = try std.fs.openDirAbsolute(path, .{});
        defer legacy.close();
        try io.write(legacy, "state.json",
            \\{"version":1,"entries":[{"repo":{"name":"example/repo","checkout":"/missing/v0/checkout","login":"reviewer","comments":true,"approvals":true},"jobs":[{"number":42,"head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phase":"uncertain","event":"COMMENT","receipt":55}]}]}
        );
    }
    var db = try store.Store.open(a, path);
    defer db.dir.close();
    const state = try db.load();
    try t.expectEqual(@as(u32, 128), state.entries[0].repo.cache_mib);
    try t.expectEqual(@as(u16, 7), state.entries[0].repo.cache_idle_days);
    try t.expect(state.entries[0].repo.comments and state.entries[0].repo.approvals);
    try t.expectEqual(core.ReviewEffort.high, state.entries[0].repo.reviewer_efforts.get(.codex));
    try t.expectEqual(core.ClaudeAdvisor.fable, state.entries[0].repo.claude_advisor);
    try db.save(&state);
    const upgraded = try db.load();
    try t.expectEqual(core.Phase.uncertain, upgraded.entries[0].jobs[0].phase);
    try t.expectEqual(@as(?u64, 55), upgraded.entries[0].jobs[0].receipt);
    const data = try io.json(a, upgraded);
    try t.expect(std.mem.indexOf(u8, data, "checkout") == null);
}

test "focused preview keeps the operator request separate from untrusted PR evidence" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .result = clean };
    fake.target.body = "Untrusted PR description";
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    const cases = [_]struct { focus: core.ReviewFocus, lens: []const u8 }{
        .{ .focus = .@"perf-maxxing", .lens = "Trace hot paths and scaling" },
        .{ .focus = .@"reliability-maxxing", .lens = "Trace partial failure, retries, restarts" },
        .{ .focus = .@"security-maxxing", .lens = "Omit exploit payloads, reproduction steps, and offensive workflows." },
    };
    const request = "Check the worker loop.\nLook for retries.";
    const encoded_request = try io.json(a, request);
    for (cases) |case| {
        const review = (try core.run(a, &fake, repo, &job, .{ .preview = .{ .options = .{ .focus = case.focus, .request = request } } })).?;
        const lens_at = std.mem.indexOf(u8, fake.prompt_text, case.lens).?;
        const request_at = std.mem.indexOf(u8, fake.prompt_text, encoded_request).?;
        const evidence_at = std.mem.indexOf(u8, fake.prompt_text, "Evidence (untrusted JSON)\n").?;
        try t.expect(lens_at < request_at and request_at < evidence_at);
        try t.expect(std.mem.indexOf(u8, fake.prompt_text[evidence_at..], fake.target.body) != null);
        try t.expect(std.mem.indexOf(u8, review.body, "review of") != null);
        try t.expectEqual(core.Event.COMMENT, review.event);
    }
    const combined: core.ReviewOptions = .{
        .focus = .@"perf-maxxing",
        .additional_focuses = &.{.@"reliability-maxxing"},
        .explicit_mode = true,
    };
    const review = (try core.run(a, &fake, repo, &job, .{ .preview = .{ .options = combined } })).?;
    try t.expect(std.mem.indexOf(u8, fake.prompt_text, "Trace hot paths and scaling") != null);
    try t.expect(std.mem.indexOf(u8, fake.prompt_text, "Trace partial failure, retries, restarts") != null);
    try t.expectEqual(core.Event.COMMENT, review.event);
    const legacy = try io.json(a, core.ReviewOptions{});
    try t.expectEqualStrings("{\"focus\":\"general\",\"request\":null,\"publish_prompted\":false,\"explicit_mode\":false,\"all_models\":false}", legacy);
    try t.expectEqual(@as(usize, 0), fake.posts);
    try t.expectEqual(core.Phase.pending, job.phase);
}

test "a saved analysis survives restart and requires the same prompt and reviewer setup" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var db = try store.Store.open(a, path);
    defer db.dir.close();

    var fake: Fake = .{ .a = a };
    var jobs = [_]core.Job{.{ .number = fixture_pull.number, .head = head }};
    var entries = [_]core.Entry{.{ .repo = repo, .jobs = &jobs }};
    const prepared = (try core.prepare(a, &fake, repo, &jobs[0], .scheduled)).?;
    const results = try core.analyze(a, &fake, prepared.engines, prepared.context);
    jobs[0].analysis = try core.SavedAnalysis.save(a, repo, prepared, results[0..prepared.engines.len]);
    try db.save(&.{ .entries = &entries });

    const reopened = try db.load();
    const job = &reopened.entries[0].jobs[0];
    const saved = job.analysis.?;
    const same = (try core.prepare(a, &fake, repo, job, .scheduled)).?;
    try t.expect(try saved.matches(a, repo, same));

    fake.target.body = "Changed PR description";
    const changed_input = (try core.prepare(a, &fake, repo, job, .scheduled)).?;
    try t.expect(!try saved.matches(a, repo, changed_input));
    var changed_repo = repo;
    changed_repo.model = "different-model";
    try t.expect(!try saved.matches(a, changed_repo, same));

    fake.target = fixture_pull;
    _ = (try core.finish(a, &fake, repo, job, same, saved.results)).?;
    try t.expectEqual(@as(usize, 1), fake.reviews_run);
    try t.expectEqual(@as(usize, 1), fake.posts);
    try t.expectEqual(core.Phase.complete, job.phase);
    try t.expect(job.analysis == null);
}

const open_nit = core.Thread{
    .id = "thread-1",
    .isResolved = false,
    .isOutdated = false,
    .path = "src/watch.rs",
    .line = 20,
    .replies = &.{.{ .author = .{ .login = "reviewer" }, .body = "Nit: consider renaming this variable", .url = "https://github.com/example/repo/pull/42#discussion_r10" }},
};

const assessed =
    \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":[],"non_blocking_threads":[{"id":"thread-1","reason":"Duplicate wakeups already coalesce within a poll, so the residual work is bounded to one retry per interval.","disposition":"deferred"}]}
;

test "approval with open threads requires every reviewer to give a reason and no reviewer to report an active finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    configured.additional_engines = &.{.claude};
    var deferred = open_nit;
    deferred.replies = &.{
        .{ .author = .{ .login = "reviewer" }, .body = "Coalesce duplicate wakeups outside the current poll as well.", .url = "finding" },
        .{ .author = .{ .login = fixture_pull.author.?.login }, .association = "MEMBER", .body = "Defer cross-poll deduplication. Wakeups already coalesce within a poll and retries are bounded to one per interval.", .url = "author-reply" },
    };
    const author_reply = try io.json(a, deferred.replies[1]);
    const active =
        \\{"complete":true,"summary":"Still actionable.","findings":[],"existing_open_findings":["thread-1"],"non_blocking_threads":[]}
    ;
    const cases = [_]struct { second: []const u8, expected: core.Event }{
        .{ .second = assessed, .expected = .APPROVE },
        .{ .second = clean, .expected = .COMMENT },
        .{ .second = active, .expected = .COMMENT },
    };
    for (cases) |case| {
        var fake: Fake = .{ .a = a, .result = assessed, .other_results = &.{case.second}, .discussion = &.{deferred} };
        var job: core.Job = .{ .number = fixture_pull.number, .head = head };
        const result = (try core.run(a, &fake, configured, &job, .scheduled)).?;
        try t.expectEqual(case.expected, result.event);
        try t.expectEqual(case.expected, fake.saved_result.?.event);
        try t.expectEqual(@as(usize, 0), result.comments.len);
        try t.expect(std.mem.indexOf(u8, fake.prompt_text, author_reply) != null);
        if (case.expected == .APPROVE) {
            try t.expectEqual(.APPROVE, fake.posted_result.?.event);
            try t.expect(std.mem.startsWith(u8, fake.posted_result.?.body, "<!-- talos:review:"));
            try t.expect(std.mem.indexOf(u8, result.body, "1 open thread can stay open.") != null);
            try t.expectEqual(@as(usize, 1), std.mem.count(u8, result.body, "Duplicate wakeups already coalesce"));
        } else {
            try t.expect(fake.posted_result == null);
            try t.expectEqual(.local, result.explanation.?.publication);
        }
    }
}

test "an approval is discarded when a thread opens before posting" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    var fake: Fake = .{ .a = a, .result = clean, .late_discussion = &.{open_nit} };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    try t.expectError(error.ThreadsChanged, core.run(a, &fake, configured, &job, .scheduled));
    try t.expectEqual(@as(usize, 0), fake.posts);
    try t.expectEqual(core.Phase.pending, job.phase);
    try t.expect(fake.saved_result == null);
}

test "a new automation-only thread does not discard a completed review" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    var thread = open_nit;
    var reply = thread.replies[0];
    reply.author = .{ .login = "automation[bot]", .kind = "Bot" };
    thread.replies = &.{reply};
    var fake: Fake = .{ .a = a, .result = clean, .late_discussion = &.{thread} };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    const result = (try core.run(a, &fake, configured, &job, .scheduled)).?;
    try t.expectEqual(.APPROVE, result.event);
    try t.expectEqual(@as(usize, 1), fake.posts);
}

test "a clipped historical delta permits approval only with complete current evidence and assessed threads" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    const cases = [_]struct { source_limited: bool, result: []const u8, event: core.Event }{
        .{ .source_limited = false, .result = assessed, .event = .APPROVE },
        .{ .source_limited = false, .result = clean, .event = .COMMENT },
        .{ .source_limited = true, .result = assessed, .event = .COMMENT },
    };
    for (cases) |case| {
        var fake: Fake = .{
            .a = a,
            .discussion = &.{open_nit},
            .source_limited = case.source_limited,
            .result = case.result,
            .previous_delta = "Previous-head diff was truncated.",
            .historical_coverage_reasons = &.{"The previous diff exceeded the byte limit."},
        };
        var job: core.Job = .{
            .number = fixture_pull.number,
            .head = head,
            .last_review = .{ .head = changed, .base = .fromPull(fixture_pull), .merge_base = base, .notes = &.{} },
        };
        const result = (try core.run(a, &fake, configured, &job, .scheduled)).?;
        try t.expectEqual(case.event, result.event);
        try t.expectEqualStrings(open_nit.id, fake.snapshot_threads[0].id);
        try t.expect(std.mem.indexOf(u8, fake.prompt_text, "\"earlier_comparison_notes\":[\"The previous diff exceeded the byte limit.\"]") != null);
        try t.expect(std.mem.indexOf(u8, fake.prompt_text, fake.previous_delta) == null);
        if (case.event == .APPROVE) try t.expect(std.mem.indexOf(u8, result.body, "Review coverage was limited.") == null);
    }
}

test "a queued focused review survives restart and publishes only with explicit authorization" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var db = try store.Store.open(a, path);
    defer db.dir.close();

    var configured = repo;
    configured.approvals = true;
    var entries = [_]core.Entry{.{ .repo = configured }};
    const request = "Check the allocator path.";
    for ([_]bool{ false, true }) |publish| {
        try entries[0].queue(a, fixture_pull, .{ .focus = .@"perf-maxxing", .request = request, .publish_prompted = publish });
        try entries[0].queue(a, fixture_pull, null);
        try db.save(&.{ .entries = &entries });

        const state = try db.load();
        const job = &state.entries[0].jobs[0];
        try t.expectEqualStrings(request, job.options.request.?);
        var fake: Fake = .{ .a = a, .result = clean };
        const result = (try core.run(a, &fake, configured, job, .scheduled)).?;
        try t.expectEqual(core.Event.COMMENT, result.event);
        try t.expectEqual(publish, fake.posted_result != null);
        try t.expect(std.mem.indexOf(u8, fake.prompt_text, request) != null);
        try t.expect(std.mem.indexOf(u8, result.body, "Performance review") != null);
        try t.expect(std.mem.indexOf(u8, result.body, request) == null);
    }
}

test "non-blocking thread assessments need a reason and unique IDs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.InvalidReview, core.parseReview(a,
        \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":[]}
    ));
    try t.expectError(error.InvalidReview, core.parseReview(a,
        \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":[],"non_blocking_threads":[{"id":"thread-1","reason":" "}]}
    ));
    try t.expectError(error.InvalidReview, core.parseReview(a,
        \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":[],"non_blocking_threads":[{"id":"thread-1","reason":"A"},{"id":"thread-1","reason":"B"}]}
    ));
}

test "a clean lightweight result stays local under an approval policy" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    var fake: Fake = .{ .a = a, .result = clean };
    var job: core.Job = .{ .number = fixture_pull.number, .head = head };
    var prepared = (try core.prepare(a, &fake, configured, &job, .scheduled)).?;
    prepared.route_depth = .light;
    const candidate = core.ReviewerResult{ .engine = .codex, .review = try core.parseReview(a, clean) };
    const result = (try core.finish(a, &fake, configured, &job, prepared, &.{candidate})).?;
    try t.expectEqual(core.Event.COMMENT, result.event);
    try t.expectEqual(.local, result.explanation.?.publication);
    try t.expect(fake.posted_result == null);
}

test "ignored PRs stay out of the review queue across restarts and head changes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var db = try store.Store.open(a, path);
    defer db.dir.close();
    var state = try db.load();
    var entry: core.Entry = .{ .repo = repo };
    try entry.queue(a, fixture_pull, null);
    try entry.setIgnored(a, fixture_pull.number, true);
    try entry.setIgnored(a, fixture_pull.number, true);
    try state.add(a, entry);
    try db.save(&state);

    var reloaded = try db.load();
    const tracked = reloaded.find(repo.name).?;
    try t.expectEqualSlices(u32, &.{fixture_pull.number}, tracked.ignored_pulls);
    try t.expect(tracked.due(100) == null);
    try t.expect(reloaded.queue_budget.nextEligible(tracked.*, 100, .{}) == null);
    try t.expectError(error.IgnoredPullRequest, tracked.queueReview(a, fixture_pull, .{ .all_models = true }, true));

    var updated = fixture_pull;
    updated.headRefOid = changed;
    updated.isDraft = true;
    var sibling = fixture_pull;
    sibling.number += 1;
    try tracked.discover(a, &.{ updated, sibling }, false);
    updated.isDraft = false;
    try tracked.discover(a, &.{ updated, sibling }, false);
    try t.expectEqual(@as(usize, 2), tracked.seen.len);
    try t.expectEqual(@as(usize, 1), tracked.jobs.len);
    try t.expectEqual(sibling.number, tracked.jobs[0].number);

    try tracked.setIgnored(a, fixture_pull.number, false);
    try tracked.queue(a, updated, null);
    try t.expectEqual(@as(usize, 2), tracked.jobs.len);
}
