const std = @import("std");
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
    discussion: []const core.Thread = &.{},
    late_discussion: ?[]const core.Thread = null,
    thread_reads: usize = 0,
    result: []const u8 = finding,
    other_results: []const []const u8 = &.{},
    fail_engine: ?core.Engine = null,
    lose_response: bool = false,
    lose_readback: bool = false,
    move_during_review: enum { none, head, base, base_ref } = .none,
    inherited: stack.Context = .{},
    move_ancestor_during_review: bool = false,
    join_native_before_post: bool = false,
    posts: usize = 0,
    reviews_run: usize = 0,
    reviewed_engines: [core.engine_count]core.Engine = undefined,
    readbacks: usize = 0,
    prompt_text: []const u8 = "",
    posted_result: ?core.Payload = null,
    saved_result: ?core.Payload = null,

    pub fn checkIdentity(_: *Fake) !void {}

    pub fn pull(self: *Fake, _: u32) !core.Pull {
        return self.target;
    }

    pub fn reviews(self: *Fake, _: u32) ![]const core.Prior {
        return if (self.offered != null) @as(*const [1]core.Prior, @ptrCast(&self.offered.?)) else &.{};
    }

    pub fn threads(self: *Fake, _: u32) ![]const core.Thread {
        self.thread_reads += 1;
        if (self.thread_reads >= 3) return self.late_discussion orelse self.discussion;
        return self.discussion;
    }

    pub fn snapshot(_: *Fake, _: core.Pull) !core.Snapshot {
        return .{ .merge_base = base, .evidence = "Diff in src/watch.rs" };
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

    pub fn persist(self: *Fake) !void {
        if (self.db) |db| try db.save(self.state.?);
    }

    pub fn saveResult(self: *Fake, _: u32, result: core.Payload) !void {
        self.saved_result = result;
    }
};

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

test "first scan baselines ready PRs, then queues drafts becoming ready, new heads, and explicit selections" {
    var allocator = std.heap.ArenaAllocator.init(t.allocator);
    defer allocator.deinit();
    const a = allocator.allocator();
    var entry = core.Entry{ .repo = repo };
    var draft = fixture_pull;
    draft.number = 43;
    draft.isDraft = true;
    try entry.discover(a, &.{ fixture_pull, draft }, true);
    try t.expectEqual(@as(usize, 1), entry.seen.len);
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
    try entry.discover(a, &.{ updated, draft, new }, false);
    try t.expectEqual(@as(usize, 3), entry.jobs.len);
    try t.expectEqual(@as(u32, 43), entry.jobs[0].number);
    try t.expectEqualStrings(changed, entry.jobs[1].head);
    try t.expectEqual(@as(u32, 44), entry.jobs[2].number);
    try entry.discover(a, &.{ updated, draft, new }, false);
    try t.expectEqual(@as(usize, 3), entry.jobs.len);
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
    try t.expectEqual(@as(usize, 1), payload.comments.len);
    try t.expectEqual(@as(u32, 20), payload.comments[0].line);

    work = .{ .number = fixture_pull.number, .head = head };
    try t.expectEqual(@as(?core.Payload, null), try core.run(a, &fake, repo, &work, .scheduled));
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
    try t.expect(std.mem.indexOf(u8, review.comments[0].body, "**P1.** claude, codex") != null);
    try t.expect(std.mem.indexOf(u8, review.comments[0].body, "The cursor is saved before processing succeeds.") != null);
    try t.expect(std.mem.indexOf(u8, review.body, "src/watch.rs:40") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, review.body, "Existing open finding unresolved"));
    try t.expect(std.mem.indexOf(u8, review.body, "Existing open finding resolved") == null);
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
    for ([_]@FieldType(Fake, "move_during_review"){ .head, .base, .base_ref }) |move| {
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
    var db = try store.Store.open(a, path);
    defer db.dir.close();
    try io.write(db.dir, "state.json",
        \\{"version":1,"entries":[{"repo":{"name":"example/repo","checkout":"/missing/v0/checkout","login":"reviewer","comments":true,"approvals":true},"jobs":[{"number":42,"head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phase":"uncertain","event":"COMMENT","receipt":55}]}]}
    );
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
    const data = try db.dir.readFileAlloc(a, "state.json", 4096);
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
        try t.expect(std.mem.indexOf(u8, review.body, @tagName(case.focus)) != null);
        try t.expectEqual(core.Event.COMMENT, review.event);
    }
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
    \\{"complete":true,"summary":"Static review.","findings":[],"existing_open_findings":[],"non_blocking_threads":[{"id":"thread-1","reason":"The name is a style preference without a behavior change."}]}
;

test "approval with open threads requires every reviewer to give a reason and no reviewer to report an active finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var configured = repo;
    configured.approvals = true;
    configured.additional_engines = &.{.claude};
    const active =
        \\{"complete":true,"summary":"Still actionable.","findings":[],"existing_open_findings":["thread-1"],"non_blocking_threads":[]}
    ;
    const cases = [_]struct { second: []const u8, expected: core.Event }{
        .{ .second = assessed, .expected = .APPROVE },
        .{ .second = clean, .expected = .COMMENT },
        .{ .second = active, .expected = .COMMENT },
    };
    for (cases) |case| {
        var fake: Fake = .{ .a = a, .result = assessed, .other_results = &.{case.second}, .discussion = &.{open_nit} };
        var job: core.Job = .{ .number = fixture_pull.number, .head = head };
        const result = (try core.run(a, &fake, configured, &job, .scheduled)).?;
        try t.expectEqual(case.expected, result.event);
        try t.expectEqual(case.expected, fake.posted_result.?.event);
        try t.expectEqual(case.expected, fake.saved_result.?.event);
        try t.expectEqual(@as(usize, 0), result.comments.len);
        if (case.expected == .APPROVE) {
            try t.expect(std.mem.indexOf(u8, result.body, "Open thread assessed as non-blocking thread-1") != null);
            try t.expectEqual(@as(usize, 2), std.mem.count(u8, result.body, "The name is a style preference"));
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
        try t.expect(std.mem.indexOf(u8, result.body, "perf-maxxing") != null);
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

test "a clean lightweight result publishes a comment under an approval policy" {
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
    _ = (try core.finish(a, &fake, configured, &job, prepared, &.{candidate})).?;
    try t.expectEqual(core.Event.COMMENT, fake.posted_result.?.event);
}
