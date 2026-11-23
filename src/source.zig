const std = @import("std");
const core = @import("core.zig");
const github = @import("github.zig");
const io = @import("io.zig");
const cache = @import("cache.zig");
const A = io.A;
const eq = io.eq;

const diff_limit = 48 * 1024;
const context_limit = 24 * 1024;
const max_blob_size = 16 * 1024;
const batch_size = 32;
const excluded_paths = [_][]const u8{
    ":(exclude,glob)**/.env*",
    ":(exclude,glob)**/*.pem",
    ":(exclude,glob)**/*.key",
    ":(exclude,glob)**/*.p12",
    ":(exclude,glob)**/*.pfx",
    ":(exclude,glob)**/.npmrc",
    ":(exclude,glob)**/.netrc",
    ":(exclude,glob)**/id_rsa",
    ":(exclude,glob)**/id_ed25519",
};

fn sensitive(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, name, ".env")) return true;
    for (excluded_paths[1..5]) |pattern| {
        if (std.mem.endsWith(u8, name, pattern[pattern.len - 4 ..])) return true;
    }
    for (excluded_paths[5..]) |pattern| {
        if (eq(u8, name, std.fs.path.basename(pattern))) return true;
    }
    return false;
}

fn shellQuote(a: A, value: []const u8) ![]const u8 {
    const escaped = try std.mem.replaceOwned(u8, a, value, "'", "'\"'\"'");
    return io.fmt(a, "'{s}'", .{escaped});
}

pub const Git = struct {
    cmd: io.Command,
    bin: []const u8,
    gh: []const u8,
    object_cache: cache.Cache,

    fn git(self: Git, path: []const u8, args: []const []const u8, input: []const u8) ![]const u8 {
        const a = self.cmd.a;
        var argv: std.ArrayList([]const u8) = .empty;
        const helper = try io.fmt(a, "credential.helper=!{s} auth git-credential", .{try shellQuote(a, self.gh)});
        try argv.appendSlice(a, &.{
            self.bin,
            "--no-replace-objects",
            try io.fmt(a, "--git-dir={s}", .{path}),
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "credential.helper=",
            "-c",
            helper,
            "-c",
            "protocol.allow=never",
            "-c",
            "protocol.https.allow=always",
            "-c",
            "gc.auto=0",
            "-c",
            "maintenance.auto=false",
        });
        try argv.appendSlice(a, args);
        return self.cmd.run(argv.items, input, 180);
    }

    fn prepare(self: Git, repo_dir: std.fs.Dir, path: []const u8) !void {
        if (try cache.openCache(repo_dir)) |existing| {
            var dir = existing;
            defer dir.close();
            try cache.touch(self.cmd.a, dir, std.time.timestamp());
            return;
        }
        _ = self.cmd.run(&.{ self.bin, "init", "--bare", "--template=", path }, "", 20) catch
            return error.GitCacheInitFailed;
        const remote = try io.fmt(self.cmd.a, "https://github.com/{s}.git", .{self.object_cache.repo.name});
        _ = try self.git(path, &.{ "config", "--local", "remote.origin.url", remote }, "");
        _ = try self.git(path, &.{ "config", "--local", "remote.origin.promisor", "true" }, "");
        _ = try self.git(path, &.{ "config", "--local", "remote.origin.partialclonefilter", "blob:none" }, "");
        var dir = (try cache.openCache(repo_dir)) orelse return error.GitCacheInitFailed;
        defer dir.close();
        try cache.touch(self.cmd.a, dir, std.time.timestamp());
    }

    pub fn snapshot(self: Git, pr: core.Pull, files: []const github.File) !core.Snapshot {
        var repo_dir = (try self.object_cache.repoDir(true)) orelse return error.GitCacheInitFailed;
        defer repo_dir.close();
        const parent = try repo_dir.realpathAlloc(self.cmd.a, ".");
        const path = try std.fs.path.join(self.cmd.a, &.{ parent, cache.directory });
        try self.object_cache.evict(repo_dir, std.time.timestamp());
        const result = self.readSnapshot(repo_dir, path, pr, files) catch |err| {
            self.object_cache.evict(repo_dir, std.time.timestamp()) catch |cache_err|
                std.log.warn("Git cache eviction failed for {s} ({s})", .{ self.object_cache.repo.name, @errorName(cache_err) });
            return err;
        };
        try self.object_cache.evict(repo_dir, std.time.timestamp());
        return result;
    }

    fn readSnapshot(self: Git, repo_dir: std.fs.Dir, path: []const u8, pr: core.Pull, files: []const github.File) !core.Snapshot {
        const a = self.cmd.a;
        try self.prepare(repo_dir, path);
        const head_ref = "refs/talos/head";
        const base_ref = "refs/talos/base";
        _ = self.git(path, &.{
            "fetch",  "--atomic",                                                         "--filter=blob:none",                                    "--no-tags", "--no-write-fetch-head", "--no-auto-maintenance", "--no-recurse-submodules",
            "origin", try io.fmt(a, "+refs/pull/{d}/head:{s}", .{ pr.number, head_ref }), try io.fmt(a, "+{s}:{s}", .{ pr.baseRefOid, base_ref }),
        }, "") catch return error.GitFetchFailed;
        const pins = io.trim(u8, try self.git(path, &.{ "rev-parse", head_ref, base_ref }, ""), "\r\n");
        const expected = try io.fmt(a, "{s}\n{s}", .{ pr.headRefOid, pr.baseRefOid });
        if (!eq(u8, pins, expected)) return error.TargetChanged;
        const merge_base = io.trim(u8, try self.git(path, &.{ "merge-base", pr.baseRefOid, pr.headRefOid }, ""), "\r\n");
        if (!core.validOid(merge_base)) return error.InvalidMergeBase;

        const diff_args = [_][]const u8{
            "diff",     "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--unified=4",
            merge_base, pr.headRefOid,   "--",
        } ++ excluded_paths;
        const diff = self.git(path, &diff_args, "") catch return error.GitDiffFailed;
        const prefix = diff[0..core.safePrefix(diff, diff_limit)];
        if (!std.unicode.utf8ValidateSlice(prefix)) return error.NonUtf8Diff;
        var evidence: std.ArrayList(u8) = .empty;
        const writer = evidence.writer(a);
        try writer.print("Merge-base diff:\n{s}", .{prefix});
        var limited = prefix.len != diff.len or files.len >= 3000;
        var candidates: std.ArrayList([]const u8) = .empty;
        for (files) |file| {
            if (sensitive(file.filename) or file.patch == null) {
                limited = true;
            } else if (core.validPath(file.filename)) {
                try candidates.append(a, file.filename);
            }
        }
        var remaining: usize = context_limit;
        var offset: usize = 0;
        while (offset < candidates.items.len and remaining >= 1024) : (offset += batch_size) {
            const group = candidates.items[offset..@min(offset + batch_size, candidates.items.len)];
            const blobs = self.readBlobs(path, pr.headRefOid, group, remaining) catch {
                // A lazy fetch can fail for one object. Keep available context
                // from other objects in that batch as in the individual path.
                for (group) |name| {
                    if (remaining < 1024) break;
                    const blob = self.readBlob(path, pr.headRefOid, name, remaining) catch continue;
                    try appendBlob(&evidence, a, name, blob, &remaining);
                }
                continue;
            };
            for (group, blobs[0..group.len]) |name, content| {
                if (remaining < 1024) break;
                if (content) |blob| try appendBlob(&evidence, a, name, blob, &remaining);
            }
        }
        return .{ .merge_base = merge_base, .evidence = evidence.items, .limited = limited };
    }

    fn readBlob(self: Git, path: []const u8, head: []const u8, name: []const u8, remaining: usize) ![]const u8 {
        const object = try io.fmt(self.cmd.a, "{s}:{s}", .{ head, name });
        const text = try self.git(path, &.{ "cat-file", "-s", object }, "");
        const size = try std.fmt.parseInt(usize, io.trim(u8, text, "\r\n"), 10);
        if (size > @min(remaining, max_blob_size)) return error.GitBlobTooLarge;
        return self.git(path, &.{ "cat-file", "blob", object }, "");
    }

    fn readBlobs(self: Git, path: []const u8, head: []const u8, names: []const []const u8, remaining: usize) ![batch_size]?[]const u8 {
        const a = self.cmd.a;
        var input: std.ArrayList(u8) = .empty;
        for (names) |name| try input.writer(a).print("{s}:{s}\n", .{ head, name });
        var info = try self.git(path, &.{ "cat-file", "--batch-check", "--buffer" }, input.items);
        input.clearRetainingCapacity();
        var requests: [batch_size]?BlobHeader = @splat(null);
        for (requests[0..names.len]) |*request| {
            const line = try takeLine(&info);
            if (std.mem.endsWith(u8, line, " missing")) continue;
            const header = try blobHeader(line);
            if (!header.is_blob or header.size > @min(remaining, max_blob_size)) continue;
            request.* = header;
            try input.writer(a).print("{s}\n", .{header.oid});
        }
        if (info.len != 0) return error.InvalidGitBatch;
        var blobs: [batch_size]?[]const u8 = @splat(null);
        if (input.items.len == 0) return blobs;
        var output = try self.git(path, &.{ "cat-file", "--batch", "--buffer" }, input.items);
        for (requests[0..names.len], blobs[0..names.len]) |request, *blob| {
            if (request) |expected| blob.* = try takeBlob(&output, expected);
        }
        if (output.len != 0) return error.InvalidGitBatch;
        return blobs;
    }
};

const BlobHeader = struct { oid: []const u8, size: usize, is_blob: bool };

fn takeLine(input: *[]const u8) ![]const u8 {
    const end = std.mem.indexOfScalar(u8, input.*, '\n') orelse return error.InvalidGitBatch;
    const line = input.*[0..end];
    input.* = input.*[end + 1 ..];
    return line;
}

fn blobHeader(line: []const u8) !BlobHeader {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const oid = fields.next() orelse return error.InvalidGitBatch;
    const kind = fields.next() orelse return error.InvalidGitBatch;
    const text = fields.next() orelse return error.InvalidGitBatch;
    if (fields.next() != null or !core.validOid(oid)) return error.InvalidGitBatch;
    const size = std.fmt.parseUnsigned(usize, text, 10) catch return error.InvalidGitBatch;
    return .{ .oid = oid, .size = size, .is_blob = eq(u8, kind, "blob") };
}

fn takeBlob(input: *[]const u8, expected: BlobHeader) ![]const u8 {
    const header = try blobHeader(try takeLine(input));
    if (!header.is_blob or !eq(u8, header.oid, expected.oid) or header.size != expected.size)
        return error.InvalidGitBatch;
    if (input.len <= header.size or input.*[header.size] != '\n') return error.InvalidGitBatch;
    const blob = input.*[0..header.size];
    input.* = input.*[header.size + 1 ..];
    return blob;
}

fn appendBlob(evidence: *std.ArrayList(u8), a: A, name: []const u8, blob: []const u8, remaining: *usize) !void {
    if (blob.len > @min(remaining.*, max_blob_size) or !std.unicode.utf8ValidateSlice(blob) or
        std.mem.indexOfScalar(u8, blob, 0) != null) return;
    try evidence.writer(a).print("\n\nHead file {s}:\n{s}", .{ name, blob });
    remaining.* -|= blob.len + name.len + 40;
}

// GitHub's files API provides the hunks GitHub can attach to. Count right-side
// lines only, and reject malformed or truncated hunks.
pub fn anchor(files: []const github.File, path: []const u8, line: u32) bool {
    if (sensitive(path)) return false;
    for (files) |file| {
        if (eq(u8, path, file.filename)) return patchHasLine(file.patch orelse return false, line);
    }
    return false;
}

fn patchHasLine(patch: []const u8, line: u32) bool {
    var lines = std.mem.splitScalar(u8, patch, '\n');
    var right: u32 = 0;
    var right_end: u32 = 0;
    var left_remaining: u32 = 0;
    var matched = false;
    while (lines.next()) |text| {
        if (std.mem.startsWith(u8, text, "@@ -")) {
            if (right != right_end or left_remaining != 0) return false;
            if (matched) return true;
            const plus = std.mem.indexOf(u8, text, " +") orelse return false;
            const suffix = std.mem.indexOf(u8, text[plus + 2 ..], " @@") orelse return false;
            const left = range(text[4..plus]) orelse return false;
            const target = range(text[plus + 2 ..][0..suffix]) orelse return false;
            left_remaining = left.count;
            right = target.start;
            right_end = std.math.add(u32, right, target.count) catch return false;
        } else if (text.len > 0) switch (text[0]) {
            ' ', '+' => {
                if (right >= right_end) return false;
                if (text[0] == ' ') {
                    if (left_remaining == 0) return false;
                    left_remaining -= 1;
                }
                matched = matched or right == line;
                right += 1;
            },
            '-' => {
                if (left_remaining == 0) return false;
                left_remaining -= 1;
            },
            '\\' => {},
            else => return false,
        };
    }
    return matched and right == right_end and left_remaining == 0;
}

fn range(text: []const u8) ?struct { start: u32, count: u32 } {
    var parts = std.mem.splitScalar(u8, text, ',');
    const start = std.fmt.parseUnsigned(u32, parts.next() orelse return null, 10) catch return null;
    const count = if (parts.next()) |value| std.fmt.parseUnsigned(u32, value, 10) catch return null else 1;
    if (parts.next() != null) return null;
    return .{ .start = start, .count = count };
}

test "right-side anchors honor deletions, context, and truncated hunks" {
    const testing = std.testing;
    const patch = "@@ -8,3 +8,3 @@\n context\n-old\n+new\n end\n@@ -70 +70,0 @@\n-deleted";
    try testing.expect(patchHasLine(patch, 9));
    try testing.expect(patchHasLine(patch, 10));
    try testing.expect(!patchHasLine(patch, 70));
    try testing.expect(!patchHasLine("@@ -8,3 +8,3 @@\n context\n-old\n+new", 9));
    try testing.expect(!anchor(&.{.{ .filename = ".env.local", .patch = "@@ -0,0 +1 @@\n+secret" }}, ".env.local", 1));
}

test "batch blobs use size framing and reject mismatched responses" {
    const testing = std.testing;
    const oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const first = try blobHeader(oid ++ " blob 5");
    const empty = try blobHeader(oid ++ " blob 0");
    var input: []const u8 = oid ++ " blob 5\na\x00\nbc\n" ++ oid ++ " blob 0\n\n";

    try testing.expectEqualSlices(u8, "a\x00\nbc", try takeBlob(&input, first));
    try testing.expectEqualStrings("", try takeBlob(&input, empty));
    try testing.expectEqualStrings("", input);

    input = oid ++ " blob 5\nshort";
    try testing.expectError(error.InvalidGitBatch, takeBlob(&input, first));
    input = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb blob 5\nshort\n";
    try testing.expectError(error.InvalidGitBatch, takeBlob(&input, first));
    try testing.expectError(error.InvalidGitBatch, blobHeader(oid ++ " blob 1 extra"));
}
