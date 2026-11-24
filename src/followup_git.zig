const std = @import("std");
const core = @import("core.zig");
const followup = @import("followup.zig");
const source = @import("source.zig");
const io = @import("io.zig");
const A = io.A;
const eq = io.eq;

pub fn allowed(path: []const u8) bool {
    if (!core.validPath(path) or source.sensitive(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part[0] == '.') return false;
    for ([_][]const u8{ ".zig", ".rs", ".ts", ".tsx", ".js", ".jsx", ".py", ".go", ".sol", ".md" }) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) return true;
    }
    return false;
}

pub const Blob = struct { mode: []const u8, text: []const u8 };

pub const Work = struct {
    git: source.Git,
    dir: []const u8,
    repo: []const u8,
    initialized: bool = false,

    pub fn make(git: source.Git, scratch: []const u8, repo: []const u8) !Work {
        return .{ .git = git, .dir = try std.fs.path.join(git.cmd.a, &.{ scratch, "followup.git" }), .repo = repo };
    }

    fn call(self: *Work, args: []const []const u8, input: []const u8) ![]const u8 {
        if (!self.initialized) {
            _ = try self.git.cmd.run(&.{ self.git.bin, "init", "--bare", "--template=", self.dir }, "", 20);
            _ = try self.git.git(self.dir, &.{ "config", "--local", "remote.origin.url", try self.url() }, "");
            _ = try self.git.git(self.dir, &.{ "config", "--local", "remote.origin.promisor", "true" }, "");
            _ = try self.git.git(self.dir, &.{ "config", "--local", "remote.origin.partialclonefilter", "blob:none" }, "");
            self.initialized = true;
        }
        return self.git.git(self.dir, args, input);
    }

    fn url(self: Work) ![]const u8 {
        return io.fmt(self.git.cmd.a, "https://github.com/{s}.git", .{self.repo});
    }

    fn ref(self: *Work, branch: []const u8) ![]const u8 {
        const full = try io.fmt(self.git.cmd.a, "refs/heads/{s}", .{branch});
        _ = self.call(&.{ "check-ref-format", full }, "") catch return error.InvalidFollowupBranch;
        return full;
    }

    pub fn remote(self: *Work, branch: []const u8) !?[]const u8 {
        const target = try self.ref(branch);
        const result = try self.call(&.{ "ls-remote", "--refs", "origin", target }, "");
        const line = io.trim(u8, result, "\r\n");
        if (line.len == 0) return null;
        var columns = std.mem.splitScalar(u8, line, '\t');
        const oid = columns.next().?;
        if (!core.validOid(oid) or !eq(u8, columns.next() orelse "", target) or columns.next() != null)
            return error.InvalidFollowupRef;
        return oid;
    }

    pub fn fetch(self: *Work, branch: []const u8, head: []const u8) !void {
        if (!core.validOid(head)) return error.InvalidFollowupRef;
        const target = try io.fmt(self.git.cmd.a, "+{s}:refs/talos/followup-input", .{try self.ref(branch)});
        _ = try self.call(&.{ "fetch", "--no-tags", "--no-write-fetch-head", "--no-auto-maintenance", "--no-recurse-submodules", "--depth=1", "--filter=blob:none", "origin", target }, "");
        const oid = try self.call(&.{ "rev-parse", "refs/talos/followup-input" }, "");
        if (!eq(u8, io.trim(u8, oid, "\r\n"), head)) return error.FollowupTargetChanged;
    }

    pub fn read(self: *Work, head: []const u8, path: []const u8) !Blob {
        if (!core.validOid(head) or !allowed(path)) return error.FollowupPathDisallowed;
        const pathspec = try io.fmt(self.git.cmd.a, ":(literal){s}", .{path});
        const line = try self.call(&.{ "ls-tree", "-z", "--full-tree", head, "--", pathspec }, "");
        var records = std.mem.splitScalar(u8, line, 0);
        const record = records.next().?;
        if (!eq(u8, records.next() orelse "?", "") or records.next() != null) return error.FollowupPathDisallowed;
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.FollowupPathDisallowed;
        if (!eq(u8, record[tab + 1 ..], path)) return error.FollowupPathDisallowed;
        var meta = std.mem.splitScalar(u8, record[0..tab], ' ');
        const mode = meta.next().?;
        if (!eq(u8, mode, "100644") or !eq(u8, meta.next() orelse "", "blob")) return error.FollowupPathDisallowed;
        const oid = meta.next() orelse return error.FollowupPathDisallowed;
        if (!core.validOid(oid) or meta.next() != null) return error.FollowupPathDisallowed;
        const size_text = try self.call(&.{ "cat-file", "-s", oid }, "");
        const size = try std.fmt.parseUnsigned(usize, io.trim(u8, size_text, "\r\n"), 10);
        if (size > 48 * 1024) return error.FollowupContextLimit;
        const text = try self.call(&.{ "cat-file", "blob", oid }, "");
        if (text.len != size or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null)
            return error.FollowupPathDisallowed;
        return .{ .mode = mode, .text = text };
    }

    pub fn commit(self: *Work, job: followup.Job, parent: []const u8, mode: []const u8, new_content: []const u8, title: []const u8) ![]const u8 {
        const a = self.git.cmd.a;
        _ = try self.call(&.{ "read-tree", parent }, "");
        const blob_text = try self.call(&.{ "hash-object", "-w", "--stdin" }, new_content);
        const blob = io.trim(u8, blob_text, "\r\n");
        if (!core.validOid(blob)) return error.InvalidFollowupCommit;
        const cacheinfo = try io.fmt(a, "{s},{s},{s}", .{ mode, blob, job.path });
        _ = try self.call(&.{ "update-index", "--cacheinfo", cacheinfo }, "");
        _ = try self.call(&.{ "diff", "--cached", "--check", "--no-ext-diff", "--no-textconv", parent, "--" }, "");
        const paths = try self.call(&.{ "diff", "--cached", "--name-status", "--no-renames", "--no-ext-diff", "--no-textconv", "-z", parent, "--" }, "");
        if (!eq(u8, paths, try io.fmt(a, "M\x00{s}\x00", .{job.path}))) return error.InvalidFollowupCommit;
        const tree_text = try self.call(&.{"write-tree"}, "");
        const tree = io.trim(u8, tree_text, "\r\n");
        if (!core.validOid(tree)) return error.InvalidFollowupCommit;
        const message = try io.fmt(a, "{s}\n\n{s}\n", .{ title, try job.source.url(a) });
        const email = try io.fmt(a, "user.email={s}@users.noreply.github.com", .{job.login});
        const oid_text = try self.call(&.{ "-c", "user.name=Talos", "-c", email, "commit-tree", tree, "-p", parent, "-F", "-" }, message);
        const oid = io.trim(u8, oid_text, "\r\n");
        if (!core.validOid(oid)) return error.InvalidFollowupCommit;
        return oid;
    }

    pub fn push(self: *Work, branch: []const u8, expected: ?[]const u8, head: []const u8) !void {
        if (!core.validOid(head) or (expected != null and !core.validOid(expected.?))) return error.InvalidFollowupRef;
        const target = try self.ref(branch);
        const a = self.git.cmd.a;
        const lease = try io.fmt(a, "--force-with-lease={s}:{s}", .{ target, expected orelse "" });
        const refspec = try io.fmt(a, "{s}:{s}", .{ head, target });
        _ = try self.call(&.{ "push", "--no-verify", lease, "origin", refspec }, "");
    }
};

test "authoring an exact replacement changes one file in a bare Git tree" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sandbox = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(sandbox) catch {};
    var directory = try std.fs.openDirAbsolute(sandbox, .{});
    defer directory.close();
    var env = std.process.EnvMap.init(a);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_CONFIG_SYSTEM", "/dev/null");
    const git_bin = io.executable(a, "/usr/bin:/bin", "git") catch return error.SkipZigTest;
    const git: source.Git = .{
        .cmd = .{ .a = a, .env = &env, .cwd = sandbox, .dir = directory },
        .bin = git_bin,
        .gh = "/bin/false",
        .object_cache = .{ .a = a, .root = directory, .repo = .{ .name = "example/repo", .login = "author" } },
    };
    var work = try Work.make(git, sandbox, "example/repo");
    const blob_text = try work.call(&.{ "hash-object", "-w", "--stdin" }, "var retries = 0;\n");
    const oid = io.trim(u8, blob_text, "\r\n");
    _ = try work.call(&.{ "update-index", "--add", "--cacheinfo", try io.fmt(a, "100644,{s},src/retry.zig", .{oid}) }, "");
    _ = try work.call(&.{ "update-index", "--add", "--cacheinfo", try io.fmt(a, "120000,{s},src/link.zig", .{oid}) }, "");
    const tree_text = try work.call(&.{"write-tree"}, "");
    const tree = io.trim(u8, tree_text, "\r\n");
    const commit_text = try work.call(&.{ "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit-tree", tree, "-m", "Fixture" }, "");
    const parent = io.trim(u8, commit_text, "\r\n");
    const job: followup.Job = .{
        .source = .{ .repo = "example/repo", .pr = 1, .comment = 7 },
        .thread = "abc",
        .path = "src/retry.zig",
        .login = "author",
        .base = "main",
    };
    const file = try work.read(parent, job.path);
    try t.expectEqualStrings("var retries = 0;\n", file.text);
    try t.expectError(error.FollowupPathDisallowed, work.read(parent, "src/link.zig"));
    try t.expectError(error.FollowupPathDisallowed, work.read(parent, ".github/workflows/retry.js"));
    const head = try work.commit(job, parent, file.mode, "var retries = 1;\n", "fix: keep one retry");
    try t.expectEqualStrings("var retries = 1;\n", (try work.read(head, job.path)).text);
    const actual_parent = try work.call(&.{ "rev-parse", try io.fmt(a, "{s}^", .{head}) }, "");
    try t.expectEqualStrings(parent, io.trim(u8, actual_parent, "\r\n"));
}
