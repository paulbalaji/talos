const std = @import("std");
const core = @import("core.zig");
const cache = @import("cache.zig");
const github = @import("github.zig");
const source = @import("source.zig");
const runner = @import("runner.zig");
const store = @import("store.zig");
const launchd = @import("launchd.zig");
const io = @import("io.zig");

const c = @cImport(@cInclude("sys/stat.h"));
const eq = io.eq;
const A = io.A;
const usage =
    \\Talos tracks ready GitHub pull requests and reviews new commits.
    \\
    \\talos [--home DIR] add OWNER/REPO [options]
    \\talos [--home DIR] status [OWNER/REPO] [--json]
    \\talos [--home DIR] queue OWNER/REPO PR
    \\talos [--home DIR] run-once [OWNER/REPO [PR]]
    \\talos [--home DIR] pause|resume OWNER/REPO
    \\talos [--home DIR] install|remove [--label dev.talos.NAME]
    \\talos [--home DIR] tick
    \\
    \\Registration options
    \\  --interval SECONDS                  Default 180, minimum 15
    \\  --cache-mib MIB                      Default 128, 0 for per-review disposal
    \\  --cache-idle-days DAYS               Default 7
    \\  --engine codex|claude|kimi           Default codex
    \\  --model MODEL                        Override reviewer model
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

const Tool = enum { git, gh, codex, claude, kimi };
const Programs = struct {
    git: []const u8 = "git",
    gh: []const u8 = "gh",
    codex: []const u8 = "codex",
    claude: []const u8 = "claude",
    kimi: []const u8 = "kimi",
};
const Local = struct {
    a: A,
    env: *const std.process.EnvMap,
    scratch: [:0]const u8,
    scratch_dir: std.fs.Dir,
    programs: Programs,

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
        return .{ .cmd = self.command(env), .gh = try self.bin(.gh), .repo = name };
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

    fn reviewerEnv(self: Local, engine: core.Engine, bin_path: []const u8) !std.process.EnvMap {
        var env = try pick(self.a, self.env, &common_env);
        const key_names: []const []const u8 = switch (engine) {
            .codex => &.{ "CODEX_HOME", "OPENAI_API_KEY" },
            .claude => &.{ "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN" },
            .kimi => &.{ "KIMI_CODE_HOME", "KIMI_API_KEY" },
        };
        for (key_names) |key| {
            if (self.env.get(key)) |value| try env.put(key, value);
        }
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
    github_client: github.Client,
    git_source: source.Git,
    reviewer: runner.Runner,
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

    pub fn threads(self: *Adapter, number: u32) ![]const core.Thread {
        return self.github_client.threads(number);
    }

    pub fn snapshot(self: *Adapter, pr: core.Pull) !core.Snapshot {
        self.files = try self.github_client.files(pr.number);
        return self.git_source.snapshot(pr, self.files);
    }

    pub fn anchor(self: *Adapter, _: core.Pull, _: core.Snapshot, path: []const u8, line: u32) !bool {
        return source.anchor(self.files, path, line);
    }

    pub fn review(self: *Adapter, prompt: []const u8) ![]const u8 {
        self.reviewer.cmd.dir.deleteFile("result.json") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return self.reviewer.review(prompt);
    }

    pub fn post(self: *Adapter, number: u32, payload: core.Payload) !u64 {
        return self.github_client.post(number, payload);
    }

    pub fn readReview(self: *Adapter, number: u32, id: u64) !core.Prior {
        return self.github_client.readReview(number, id);
    }

    pub fn persist(self: *Adapter) !void {
        try self.db.save(self.state);
    }

    pub fn saveResult(self: *Adapter, number: u32, payload: core.Payload) !void {
        try self.db.result(self.repo.name, number, payload);
    }
};

const Main = struct {
    a: A,
    env: *const std.process.EnvMap,
    home: []const u8,
    db: store.Store,
    scratch: [:0]const u8,
    scratch_dir: std.fs.Dir,

    fn local(self: Main, entry: ?core.Repo) Local {
        var result: Local = .{ .a = self.a, .env = self.env, .scratch = self.scratch, .scratch_dir = self.scratch_dir, .programs = .{} };
        if (entry) |repo| {
            result.programs = .{
                .git = repo.git,
                .gh = repo.gh,
                .codex = repo.codex,
                .claude = repo.claude,
                .kimi = repo.kimi,
            };
        }
        return result;
    }

    fn objectCache(self: Main, repo: core.Repo) cache.Cache {
        return .{ .a = self.a, .root = self.db.dir, .repo = repo };
    }

    fn add(self: Main, state: *store.State, args: []const []const u8) !void {
        if (args.len == 0) return error.Usage;
        const name = try repoName(self.a, args[0]);
        var repo: core.Repo = .{
            .name = name,
            .login = "",
        };
        var programs: Programs = .{};
        var options = args[1..];
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
                    repo.engine = std.meta.stringToEnum(core.Engine, value) orelse return error.UnknownReviewer;
                } else if (eq(u8, opt, "--model")) {
                    if (value.len == 0 or value[0] == '-' or value.len > 200) return error.InvalidModel;
                    repo.model = value;
                } else if (std.mem.startsWith(u8, opt, "--")) {
                    const tool = std.meta.stringToEnum(Tool, opt[2..]) orelse return error.Usage;
                    switch (tool) {
                        inline else => |t| @field(programs, @tagName(t)) = value,
                    }
                } else return error.Usage;
            }
        }
        var tools = self.local(null);
        tools.programs = programs;
        const reviewer_tool = std.meta.stringToEnum(Tool, @tagName(repo.engine)).?;
        const reviewer_bin = try tools.bin(reviewer_tool);
        repo.git = try tools.bin(.git);
        repo.gh = try tools.bin(.gh);
        repo.codex = if (repo.engine == .codex) reviewer_bin else programs.codex;
        repo.claude = if (repo.engine == .claude) reviewer_bin else programs.claude;
        repo.kimi = if (repo.engine == .kimi) reviewer_bin else programs.kimi;

        const gh_env = try tools.githubEnv();
        const client = try tools.gh(&gh_env, name);
        repo.login = try client.identity();
        if (state.find(name)) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.repo.login, repo.login)) return error.GitHubIdentityChanged;
            entry.repo = repo;
            entry.next_scan = 0;
            entry.next_cache_check = 0;
            try self.db.save(state);
            try io.out("Updated {s} as {s}\n", .{ name, repo.login });
        } else {
            const pulls = try client.ready();
            var repo_dir = (try self.objectCache(repo).repoDir(true)) orelse return error.RepositoryDirectoryMissing;
            repo_dir.close();
            var entry: core.Entry = .{ .repo = repo };
            try entry.discover(self.a, pulls, true);
            entry.last_scan = std.time.timestamp();
            entry.next_scan = entry.last_scan + repo.interval;
            try state.add(self.a, entry);
            try self.db.save(state);
            try io.out("Added {s} as {s} with {d} ready PRs baselined\n", .{ name, repo.login, entry.seen.len });
        }
    }

    fn adapter(self: Main, entry: *core.Entry, state: *const store.State, gh_env: *std.process.EnvMap, reviewer_env: *std.process.EnvMap) !Adapter {
        const repo = entry.repo;
        const tools = self.local(repo);
        gh_env.* = try tools.githubEnv();
        const bin = try tools.bin(std.meta.stringToEnum(Tool, @tagName(repo.engine)).?);
        reviewer_env.* = try tools.reviewerEnv(repo.engine, bin);
        return .{
            .db = self.db,
            .state = state,
            .repo = repo,
            .github_client = try tools.gh(gh_env, repo.name),
            .git_source = try tools.git(gh_env, self.db, repo),
            .reviewer = .{ .cmd = tools.command(reviewer_env), .bin = bin, .engine = repo.engine, .model = repo.model },
        };
    }

    fn scan(self: Main, entry: *core.Entry) !void {
        const local_tools = self.local(entry.repo);
        const env = try local_tools.githubEnv();
        const client = try local_tools.gh(&env, entry.repo.name);
        if (!std.ascii.eqlIgnoreCase(entry.repo.login, try client.identity())) return error.GitHubIdentityChanged;
        try entry.discover(self.a, try client.ready(), false);
    }

    fn tick(self: Main, state: *store.State) !void {
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
            if (entry.next_scan <= now and !try self.db.paused(entry.repo.name)) {
                if (self.scan(entry)) |_| {
                    entry.last_scan = std.time.timestamp();
                    entry.next_scan = entry.last_scan + entry.repo.interval;
                    entry.scan_attempts = 0;
                } else |err| {
                    entry.scan_attempts +|= 1;
                    entry.next_scan = now + core.delay(entry.scan_attempts);
                    try entry.problem(self.a, now, null, @errorName(err));
                }
                changed = true;
            }
            if (changed) try self.db.save(state);
        }
        for (state.entries) |*entry| {
            const now = std.time.timestamp();
            if (try self.db.paused(entry.repo.name)) continue;
            const job = entry.due(now) orelse continue;
            self.runJob(state, entry, job) catch |err| {
                try core.recordFailure(entry, self.a, job, std.time.timestamp(), err);
                try self.db.save(state);
            };
        }
    }

    fn runJob(self: Main, state: *const store.State, entry: *core.Entry, job: *core.Job) !void {
        var gh_env: std.process.EnvMap = undefined;
        var reviewer_env: std.process.EnvMap = undefined;
        var live = try self.adapter(entry, state, &gh_env, &reviewer_env);
        _ = try core.run(self.a, &live, entry.repo, job, .scheduled);
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

    fn dry(self: Main, state: *store.State, args: []const []const u8) !void {
        if (args.len > 2) return error.Usage;
        const target = if (args.len > 0) state.find(args[0]) orelse return error.UnknownRepository else null;
        for (state.entries) |*entry| {
            if (target != null and entry != target.?) continue;
            var job: core.Job = undefined;
            var initial: ?core.Pull = null;
            if (args.len == 2) {
                const pull = try self.choose(entry, try prNumber(args[1]));
                initial = pull;
                job = .{ .number = pull.number, .head = pull.headRefOid };
            } else {
                if (try self.db.paused(entry.repo.name)) continue;
                try self.scan(entry); // This copy is never written back.
                const queued = entry.due(std.time.timestamp()) orelse continue;
                if (queued.phase != .pending) continue;
                job = queued.*;
            }
            var gh_env: std.process.EnvMap = undefined;
            var reviewer_env: std.process.EnvMap = undefined;
            var live = try self.adapter(entry, state, &gh_env, &reviewer_env);
            const payload = (try core.run(self.a, &live, entry.repo, &job, .{ .preview = initial })).?;
            try io.out("{s}\n", .{try io.json(self.a, .{ .repo = entry.repo.name, .pr = job.number, .review = payload })});
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
        if (state.entries.len == 0 and !json_output) try io.out("No repositories registered\n", .{});
        if (json_output) try io.out("[", .{});
        var first = true;
        for (state.entries) |entry| {
            if (repo != null and !std.ascii.eqlIgnoreCase(repo.?, entry.repo.name)) continue;
            const paused = try self.db.paused(entry.repo.name);
            const measurement = self.objectCache(entry.repo).measure();
            const retained: ?u64 = if (measurement) |bytes| bytes else |_| null;
            const cache_error: ?[]const u8 = if (measurement) |_| null else |err| @errorName(err);
            if (json_output) {
                try io.out("{s}{s}", .{ if (first) "" else ",", try io.json(self.a, .{ .paused = paused, .state = entry, .cache_bytes = retained, .cache_error = cache_error }) });
                first = false;
                continue;
            }
            try io.out("{s}  {s}  {s}  interval {d}s  comments {s}  approvals {s}\n", .{
                entry.repo.name,     if (paused) "paused" else "active",       @tagName(entry.repo.engine),
                entry.repo.interval, if (entry.repo.comments) "on" else "off", if (entry.repo.approvals) "on" else "off",
            });
            try io.out("  Last successful scan {s}  |  Next scan {s}  |  Ready PRs {d}\n", .{
                try formatTime(self.a, entry.last_scan), try formatTime(self.a, entry.next_scan), entry.seen.len,
            });
            if (retained) |bytes| {
                try io.out("  Git cache {d} bytes / {d} MiB  |  Idle expiry {d}d\n", .{ bytes, entry.repo.cache_mib, entry.repo.cache_idle_days });
            } else {
                try io.out("  Git cache unavailable ({s})\n", .{cache_error.?});
            }
            var queued: usize = 0;
            for (entry.jobs) |job| {
                if (job.phase == .complete) continue;
                queued += 1;
                try io.out("  #{d} {s} {s}, attempts {d}, next {s}\n", .{
                    job.number,                       job.head[0..@min(job.head.len, 10)], @tagName(job.phase), job.attempts,
                    try formatTime(self.a, job.next),
                });
            }
            if (queued == 0) try io.out("  Queue empty\n", .{});
            for (entry.errors) |issue| {
                try io.out("  {s}  {s}", .{ try formatTime(self.a, issue.at), issue.detail });
                if (issue.number) |number| try io.out("  PR #{d}", .{number});
                try io.out("\n", .{});
            }
        }
        if (json_output) try io.out("]\n", .{});
    }

    fn dispatch(self: Main, args: []const []const u8) !void {
        const cmd = args[0];
        const params = args[1..];
        if (eq(u8, cmd, "status")) {
            var state = try self.db.load();
            return self.status(&state, params);
        }
        if (eq(u8, cmd, "pause") or eq(u8, cmd, "resume")) {
            if (params.len != 1) return error.Usage;
            var state = try self.db.load();
            const entry = state.find(params[0]) orelse return error.UnknownRepository;
            const pause = eq(u8, cmd, "pause");
            try self.db.setPaused(entry.repo.name, pause);
            return io.out("{s} {s}\n", .{ if (pause) "Paused" else "Resumed", entry.repo.name });
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
        var state = try self.db.load();
        if (eq(u8, cmd, "add")) return self.add(&state, params);
        if (eq(u8, cmd, "tick") and params.len == 0) return self.tick(&state);
        if (eq(u8, cmd, "run-once")) return self.dry(&state, params);
        if (eq(u8, cmd, "queue") and params.len == 2) {
            const entry = state.find(params[0]) orelse return error.UnknownRepository;
            const pull = try self.choose(entry, try prNumber(params[1]));
            try entry.queue(self.a, pull, true);
            try self.db.save(&state);
            return io.out("Selected {s} #{d} at {s}\n", .{ entry.repo.name, pull.number, pull.headRefOid });
        }
        return error.Usage;
    }
};

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
    if (timestamp <= 0) return "—";
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
    _ = c.umask(0o077);
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
        std.log.err("{s}", .{@errorName(err)});
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
    _ = @import("tests.zig");
}
