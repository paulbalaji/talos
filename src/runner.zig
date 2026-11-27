const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");
const codex = @import("reviewers/codex.zig");
const claude = @import("reviewers/claude.zig");
const kimi = @import("reviewers/kimi.zig");
const shared = @import("reviewers/shared.zig");
const usage = @import("usage.zig");
const metrics = @import("telemetry.zig");
const store = @import("store.zig");
pub const Profile = shared.Profile;

pub const ProviderSlots = struct {
    const max_calls = 3;
    counts: [core.engine_count]std.atomic.Value(u8) = @splat(.init(0)),
    total: std.atomic.Value(u32) = .init(0),
    limit: std.atomic.Value(u32) = .init(std.math.maxInt(u32)),

    fn take(comptime T: type, count: *std.atomic.Value(T), cap: T) !void {
        var current = count.load(.monotonic);
        while (current < cap) {
            current = count.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) orelse return;
        }
        return error.ReviewerBusy;
    }

    fn acquire(self: *ProviderSlots, engine: core.Engine) !void {
        const count = &self.counts[@intFromEnum(engine)];
        try take(u8, count, max_calls);
        errdefer _ = count.fetchSub(1, .monotonic);
        try take(u32, &self.total, self.limit.load(.monotonic));
    }

    pub fn setLimit(self: *ProviderSlots, limit: u32) void {
        self.limit.store(limit, .monotonic);
    }

    fn release(self: *ProviderSlots, engine: core.Engine) void {
        _ = self.total.fetchSub(1, .monotonic);
        _ = self.counts[@intFromEnum(engine)].fetchSub(1, .monotonic);
    }
};

fn adapter(comptime engine: core.Engine) type {
    return switch (engine) {
        .codex => codex,
        .claude => claude,
        .kimi => kimi,
    };
}

pub fn configureEnvironment(engine: core.Engine, profile: Profile, parent: *const std.process.EnvMap, child: *std.process.EnvMap) !void {
    switch (engine) {
        inline else => |selected| {
            const reviewer = adapter(selected);
            for (reviewer.auth_env) |name| {
                if (parent.get(name)) |value| try child.put(name, value);
            }
            try reviewer.configureEnv(child, profile);
        },
    }
}

const FailedOutput = struct {
    a: io.A,
    engine: core.Engine,
    report: *shared.Report,

    fn capture(ptr: *anyopaque, file: std.fs.File) void {
        const self: *FailedOutput = @ptrCast(@alignCast(ptr));
        const end = file.getEndPos() catch return;
        const size: usize = @intCast(@min(end, 512 * 1024));
        if (size == 0) return;
        const buffer = self.a.alloc(u8, size) catch return;
        defer self.a.free(buffer);
        const count = file.preadAll(buffer, end - size) catch return;
        self.report.* = switch (self.engine) {
            inline else => |engine| adapter(engine).report(self.a, buffer[0..count]),
        };
    }
};

fn attemptOutcome(err: anyerror) metrics.Outcome {
    return switch (err) {
        error.ReviewerTimedOut => .timed_out,
        error.CodexRateLimited, error.ClaudeRateLimited, error.KimiRateLimited => .rate_limited,
        else => .failed,
    };
}

test "provider saturation leaves capacity available for another CLI" {
    const t = std.testing;
    var slots: ProviderSlots = .{};
    for (0..ProviderSlots.max_calls) |_| try slots.acquire(.codex);
    try t.expectError(error.ReviewerBusy, slots.acquire(.codex));
    try slots.acquire(.claude);
    slots.release(.codex);
    try slots.acquire(.codex);
    try t.expectError(error.ReviewerBusy, slots.acquire(.codex));
}

test "a validated scheduled response survives an interrupted coordinator" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var db = try store.Store.open(a, path);
    defer db.dir.close();
    const raw = "{\"complete\":true,\"summary\":\"Verified fixture.\",\"findings\":[],\"existing_open_findings\":[],\"non_blocking_threads\":[]}";
    {
        const executable = try db.dir.createFile("fixture", .{ .mode = 0o700 });
        defer executable.close();
        try executable.writeAll("#!/bin/sh\nprintf '%s' '" ++ raw ++ "' > result.json\n");
    }
    const env = std.process.EnvMap.init(a);
    var starts: u32 = 0;
    var runner: Runner = .{
        .cmd = .{ .a = a, .env = &env, .cwd = path, .dir = db.dir },
        .bin = try std.fs.path.join(a, &.{ path, "fixture" }),
        .engine = .codex,
        .profile = .{},
        .pass_store = db,
        .telemetry = .{ .dir = db.dir, .scope = .{ .repo = "fixture/repo", .pr = 42, .head = "a" ** 40 } },
        .starts = &starts,
    };
    try t.expectEqualStrings(raw, try runner.review("Pinned input"));
    try db.recoverPasses(std.time.timestamp());
    try t.expectEqualStrings(raw, try runner.review("Pinned input"));
    try t.expectEqual(@as(u32, 1), starts);
    try t.expectEqualStrings(raw, try runner.review("Changed input"));
    runner.telemetry.?.scope.review_id = "manual-rereview";
    try t.expectEqualStrings(raw, try runner.review("Pinned input"));
    try t.expectEqual(@as(u32, 3), starts);
}

pub const Runner = struct {
    cmd: io.Command,
    bin: []const u8,
    engine: core.Engine,
    profile: Profile,
    starts: ?*u32 = null,
    started: ?*std.atomic.Value(u32) = null,
    meter: ?*usage.Ledger = null,
    telemetry: ?metrics.Recorder = null,
    schema: []const u8 = core.schema,
    pass_store: ?store.Store = null,
    slots: ?*ProviderSlots = null,

    fn passKey(self: Runner, scope: metrics.Scope, prompt: []const u8) ![32]u8 {
        const metadata = try io.json(self.cmd.a, .{
            .scope = scope,
            .engine = self.engine,
            .profile = self.profile,
        });
        defer self.cmd.a.free(metadata);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("talos-pass-v2\x00");
        hash.update(metadata);
        hash.update("\x00");
        hash.update(self.schema);
        hash.update("\x00");
        hash.update(prompt);
        return hash.finalResult();
    }

    fn validateResponse(self: Runner, raw: []const u8) !bool {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        if (io.eq(u8, self.schema, core.schema)) {
            _ = try core.parseReview(scratch.allocator(), raw);
            return true;
        }
        if (io.eq(u8, self.schema, core.screen_schema)) {
            _ = try core.parseScreen(scratch.allocator(), raw);
            return true;
        }
        return false;
    }

    const Pass = struct { db: store.Store, key: [32]u8, lease: [16]u8 };

    pub fn review(self: Runner, prompt: []const u8) ![]const u8 {
        if (self.profile.model) |model| try shared.requireStandardModel(model);
        // Keep the same bound for all reviewers. Kimi passes the prompt as
        // one argument, so it must fit below Linux's per-argument limit.
        if (prompt.len > core.review_context_limit) return error.ReviewContextLimit;
        var pass: ?Pass = null;
        if (self.pass_store) |configured| if (self.telemetry) |recorder| {
            if (recorder.scope.mode == .scheduled and
                (io.eq(u8, self.schema, core.schema) or io.eq(u8, self.schema, core.screen_schema)))
            {
                var db = configured;
                db.a = self.cmd.a;
                const key = try self.passKey(recorder.scope, prompt);
                const now = std.time.timestamp();
                switch (try db.claimPass(key, now, now + @as(i64, self.profile.timeout_seconds) + 60)) {
                    .cached => |raw| return raw,
                    .claimed => |lease| pass = .{ .db = db, .key = key, .lease = lease },
                    .busy => return error.ReviewerBusy,
                }
            }
        };
        errdefer if (pass) |lease| {
            _ = lease.db.finishPass(lease.key, lease.lease, null, std.time.timestamp()) catch false;
        };
        if (self.slots) |slots| try slots.acquire(self.engine);
        defer if (self.slots) |slots| slots.release(self.engine);
        switch (self.engine) {
            inline else => |engine| {
                const reviewer = adapter(engine);
                const invocation = try reviewer.prepare(self.cmd, self.bin, self.profile, prompt, self.schema);
                if (self.meter) |meter| try meter.start(engine, std.time.timestamp());
                if (self.starts) |count| count.* +|= 1;
                if (self.started) |count| _ = count.fetchAdd(1, .monotonic);
                const recorder = self.telemetry orelse return self.run(engine, invocation, null);
                var random: [16]u8 = undefined;
                std.crypto.random.bytes(&random);
                const id = std.fmt.bytesToHex(random, .lower);
                var event: metrics.Event = .{
                    .id = &id,
                    .at = std.time.timestamp(),
                    .kind = .started,
                    .scope = recorder.scope,
                    .engine = engine,
                    .model = shared.modelLabel(self.profile.model orelse reviewer.default_model),
                    .effort = self.profile.effort,
                    .pid = @intCast(std.c.getpid()),
                };
                recorder.write(self.cmd.a, event);
                var timer = std.time.Timer.start() catch null;
                var report: shared.Report = .{};
                const returned = self.run(engine, invocation, &report);
                event.kind = .finished;
                event.at = std.time.timestamp();
                event.duration_ms = if (timer) |*clock| clock.read() / std.time.ns_per_ms else null;
                event.tokens = report.tokens;
                event.model_usage = report.model_usage;
                if (report.model_usage.len == 1) event.model = report.model_usage[0].model;
                var accepted: ?[]const u8 = null;
                if (returned) |raw| {
                    event.outcome = .success;
                    validated: {
                        const valid = self.validateResponse(raw) catch |err| {
                            event.outcome = .failed;
                            event.error_name = @errorName(err);
                            break :validated;
                        };
                        if (valid) accepted = raw;
                    }
                } else |err| {
                    event.outcome = attemptOutcome(err);
                    event.error_name = @errorName(err);
                }
                recorder.write(self.cmd.a, event);
                if (pass) |lease| {
                    if (!try lease.db.finishPass(lease.key, lease.lease, accepted, event.at))
                        return error.ReviewLeaseLost;
                    pass = null;
                }
                return returned;
            },
        }
    }

    fn run(self: Runner, comptime engine: core.Engine, invocation: shared.Invocation, report: ?*shared.Report) ![]const u8 {
        const reviewer = adapter(engine);
        var cmd = self.cmd;
        cmd.transport = @field(io.Transport, @tagName(engine));
        var failed: FailedOutput = undefined;
        if (engine != .kimi) {
            if (report) |capture| {
                failed = .{ .a = cmd.a, .engine = engine, .report = capture };
                cmd.failure_stdout = .{ .context = &failed, .observe = FailedOutput.capture };
            }
        }
        const output = cmd.run(invocation.args, invocation.stdin, self.profile.timeout_seconds) catch |err| return switch (err) {
            error.SubprocessTimeout => error.ReviewerTimedOut,
            error.CodexRateLimited, error.ClaudeRateLimited, error.KimiRateLimited => err,
            else => reviewer.failure,
        };
        if (report) |capture| capture.* = reviewer.report(cmd.a, output);
        return reviewer.result(self.cmd, output);
    }
};

test "reviewer envelope decoding preserves strict validation downstream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = std.process.EnvMap.init(a);
    const cmd: io.Command = .{ .a = a, .env = &env, .cwd = ".", .dir = std.fs.cwd() };
    try std.testing.expectEqualStrings("{\"complete\":true}", try kimi.result(cmd, "{\"role\":\"assistant\",\"content\":\"{\\\"complete\\\":true}\"}\n{\"role\":\"meta\",\"type\":\"session.resume_hint\"}\n"));
    try std.testing.expectEqualStrings("{\"complete\":true}", try claude.result(cmd, "{\"is_error\":false,\"structured_output\":{\"complete\":true}}"));
}

test "provider metadata preserves token semantics and does not interpret response text" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reported = codex.report(a,
        \\{"type":"turn.completed","usage":{"input_tokens":140,"output_tokens":40,"cached_input_tokens":80,"cache_write_input_tokens":7,"reasoning_output_tokens":21}}
        \\{"type":"item.completed","usage":{"input_tokens":999}}
    );
    try t.expectEqual(@as(?u64, 140), reported.tokens.?.input);
    try t.expectEqual(@as(?u64, 80), reported.tokens.?.cached_input);
    try t.expectEqual(@as(?u64, 7), reported.tokens.?.cache_write_input);
    try t.expectEqual(@as(?u64, 21), reported.tokens.?.reasoning_output);
    try t.expect(codex.report(a, "{\"type\":\"turn.failed\",\"usage\":{\"input_tokens\":9}}").tokens == null);
    const claude_report = claude.report(a,
        \\{"type":"result","is_error":false,"usage":{"input_tokens":30,"output_tokens":14,"cache_read_input_tokens":100,"cache_creation_input_tokens":8},
        \\"modelUsage":{"claude-opus":{"inputTokens":20,"outputTokens":10,"cacheReadInputTokens":80,"cacheCreationInputTokens":8},
        \\"claude-fable":{"inputTokens":10,"outputTokens":4,"cacheReadInputTokens":20,"cacheCreationInputTokens":0}}}
    );
    try t.expectEqual(@as(?u64, 138), claude_report.tokens.?.input);
    try t.expectEqual(@as(?u64, 14), claude_report.tokens.?.output);
    try t.expectEqual(@as(usize, 2), claude_report.model_usage.len);
    try t.expectEqualStrings("claude-opus", claude_report.model_usage[0].model);
    try t.expectEqual(@as(?u64, 108), claude_report.model_usage[0].tokens.input);
    try t.expectEqual(@as(?u64, 30), claude_report.model_usage[1].tokens.input);
    const partial = claude.report(a, "{\"type\":\"result\",\"is_error\":true,\"usage\":{\"input_tokens\":3,\"output_tokens\":0}}");
    try t.expectEqual(@as(?u64, null), partial.tokens.?.input);
    try t.expectEqual(@as(?u64, 0), partial.tokens.?.output);
    try t.expect(kimi.report(a, "{\"role\":\"assistant\",\"content\":\"1234 tokens\"}").tokens == null);
}

test "reviewer attempts retain terminal usage through failure and timeout without persisting content" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var workspace = t.tmpDir(.{});
    defer workspace.cleanup();
    const cwd = try a.dupeZ(u8, try workspace.dir.realpathAlloc(a, "."));
    const env = std.process.EnvMap.init(a);
    const cmd: io.Command = .{ .a = a, .env = &env, .cwd = cwd, .dir = workspace.dir };
    const recorder: metrics.Recorder = .{
        .dir = workspace.dir,
        .scope = .{ .repo = "example/repo", .pr = 15, .head = "0123456789abcdef", .section = 1, .section_count = 3, .stage = .completion },
    };
    const valid_review = "{\"complete\":true,\"summary\":\"private-response-content\",\"findings\":[],\"existing_open_findings\":[],\"non_blocking_threads\":[]}";
    const script =
        \\#!/bin/sh
        \\printf '%s' '
    ++ valid_review ++ "' > result.json\n" ++
        \\if [ "${0##*/}" = invalid ]; then printf '%s' 'private-response-content' > result.json; fi
        \\printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":5,"output_tokens":8}}'
        \\case "${0##*/}" in
        \\    fail) exit 1;;
        \\    timeout) /bin/sleep 10;;
        \\esac
    ;
    const cases = [_]struct { name: []const u8, outcome: metrics.Outcome, err: ?anyerror }{
        .{ .name = "success", .outcome = .success, .err = null },
        .{ .name = "invalid", .outcome = .failed, .err = null },
        .{ .name = "fail", .outcome = .failed, .err = error.CodexFailed },
        .{ .name = "timeout", .outcome = .timed_out, .err = error.ReviewerTimedOut },
    };
    for (cases, 1..) |case, count| {
        const bin = try workspace.dir.createFile(case.name, .{ .mode = 0o700 });
        try bin.writeAll(script);
        bin.close();
        const runner: Runner = .{
            .cmd = cmd,
            .bin = try workspace.dir.realpathAlloc(a, case.name),
            .engine = .codex,
            .profile = .{ .effort = .max, .timeout_seconds = 1 },
            .telemetry = recorder,
        };
        const reply = runner.review("private-review-prompt");
        if (case.err) |expected| {
            try t.expectError(expected, reply);
        } else {
            try t.expectEqualStrings(if (io.eq(u8, case.name, "invalid")) "private-response-content" else valid_review, try reply);
        }
        const events = try metrics.read(a, workspace.dir, .{ .since = std.time.timestamp() - std.time.s_per_day, .pr = 15 });
        try t.expectEqual(count * 2, events.len);
        try t.expectEqualStrings(events[1].id, events[0].id);
        try t.expectEqual(metrics.Stage.completion, events[0].scope.stage);
        try t.expectEqual(@as(?metrics.Outcome, case.outcome), events[0].outcome);
        if (io.eq(u8, case.name, "invalid")) try t.expectEqualStrings("InvalidReview", events[0].error_name.?);
        try t.expect(events[0].duration_ms != null);
        try t.expectEqual(@as(?u64, 12), events[0].tokens.?.input);
        try t.expectEqual(@as(?u64, 8), events[0].tokens.?.output);
        const stored = try io.json(a, events);
        try t.expect(std.mem.indexOf(u8, stored, "private-review-prompt") == null);
        try t.expect(std.mem.indexOf(u8, stored, "private-response-content") == null);
    }
}

test "reviewer command profiles pin default models and preserve explicit overrides" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = std.process.EnvMap.init(a);
    const scratch = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(scratch) catch {};
    var dir = try std.fs.openDirAbsolute(scratch, .{});
    defer dir.close();
    const cmd: io.Command = .{ .a = a, .env = &env, .cwd = scratch, .dir = dir };
    const cases = [_]struct {
        engine: core.Engine,
        profile: Profile = .{},
        expected_tail: []const []const u8,
        stdin: []const u8 = "prompt",
    }{
        .{ .engine = .codex, .expected_tail = &.{ "-m", "gpt-6.2-sol", "-c", "model_reasoning_effort=\"high\"", "-" } },
        .{ .engine = .claude, .profile = .{ .advisor = "fable" }, .expected_tail = &.{ "--model", "opus", "--effort", "high", "--advisor", "fable" } },
        .{ .engine = .kimi, .expected_tail = &.{ "-m", "kimi-code/k3.1-pro", "-p", "prompt" }, .stdin = "" },
        .{ .engine = .codex, .profile = .{ .model = "custom-model", .effort = .default }, .expected_tail = &.{ "-m", "custom-model", "-" } },
        .{ .engine = .claude, .profile = .{ .model = "sonnet", .effort = .medium }, .expected_tail = &.{ "--model", "sonnet", "--effort", "medium" } },
    };
    inline for (cases) |case| {
        const invocation = try adapter(case.engine).prepare(cmd, @tagName(case.engine), case.profile, "prompt", core.schema);
        try t.expectEqualStrings(case.stdin, invocation.stdin);
        try t.expect(invocation.args.len >= case.expected_tail.len);
        const tail = invocation.args[invocation.args.len - case.expected_tail.len ..];
        for (case.expected_tail, tail) |expected, actual| try t.expectEqualStrings(expected, actual);
        if (case.engine == .codex) {
            var standard = false;
            for (invocation.args) |arg| standard = standard or io.eq(u8, arg, "service_tier=\"default\"");
            try t.expect(standard);
        }
    }
}

test "reviewers cannot launch a saved high-speed model" {
    const reviewer: Runner = .{
        .cmd = undefined,
        .bin = "kimi",
        .engine = .kimi,
        .profile = .{ .model = "kimi-code/k3.1-pro-highspeed[1m]" },
    };
    try std.testing.expectError(error.PremiumSpeedModelDisabled, reviewer.review("prompt"));
}
