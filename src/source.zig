const std = @import("std");
const core = @import("core.zig");
const github = @import("github.zig");
const io = @import("io.zig");
const cache = @import("cache.zig");
const onchain = @import("onchain.zig");
const A = io.A;
const eq = io.eq;

const diff_limit = 48 * 1024;
const context_limit = 24 * 1024;
const max_blob_size = 16 * 1024;
const batch_size = 32;
pub const max_requests = core.max_evidence_requests;
const supplement_limit = 16 * 1024;
const delta_limit = 12 * 1024;
const excerpt_blob_limit = 128 * 1024;
const excerpt_line_limit = 120;

pub const Supplement = struct {
    evidence: []const u8 = "",
    limited: bool = false,
    coverage_reasons: []const []const u8 = &.{},
};

const diff_flags = [_][]const u8{
    "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--unified=4",
};
const fetch_flags = [_][]const u8{
    "fetch", "--atomic", "--filter=blob:none", "--no-tags", "--no-write-fetch-head", "--no-auto-maintenance", "--no-recurse-submodules",
};

const SensitiveName = union(enum) {
    exact: []const u8,
    prefix: []const u8,
    suffix: []const u8,

    fn gitPathspec(comptime self: SensitiveName) []const u8 {
        const glob = switch (self) {
            .exact => |name| name,
            .prefix => |prefix| prefix ++ "*",
            .suffix => |suffix| "*" ++ suffix,
        };
        return ":(exclude,glob)**/" ++ glob;
    }

    fn matches(self: SensitiveName, name: []const u8) bool {
        return switch (self) {
            .exact => |exact| eq(u8, name, exact),
            .prefix => |prefix| std.mem.startsWith(u8, name, prefix),
            .suffix => |suffix| std.mem.endsWith(u8, name, suffix),
        };
    }
};

const sensitive_names = [_]SensitiveName{
    .{ .prefix = ".env" },
    .{ .suffix = ".pem" },
    .{ .suffix = ".key" },
    .{ .suffix = ".p12" },
    .{ .suffix = ".pfx" },
    .{ .exact = ".npmrc" },
    .{ .exact = ".netrc" },
    .{ .exact = "id_rsa" },
    .{ .exact = "id_ed25519" },
};
const excluded_paths = specs: {
    var result: [sensitive_names.len][]const u8 = undefined;
    for (sensitive_names, &result) |rule, *pathspec| pathspec.* = rule.gitPathspec();
    break :specs result;
};

pub fn sensitive(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    for (sensitive_names) |rule| if (rule.matches(name)) return true;
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

    pub fn git(self: Git, path: []const u8, args: []const []const u8, input: []const u8) ![]const u8 {
        return self.gitWithin(path, args, input, 180);
    }

    fn gitWithin(self: Git, path: []const u8, args: []const []const u8, input: []const u8, seconds: u32) ![]const u8 {
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
        return self.cmd.run(argv.items, input, seconds);
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
        try self.pin(repo_dir, path, pr);
        const merge_base = io.trim(u8, try self.git(path, &.{ "merge-base", pr.baseRefOid, pr.headRefOid }, ""), "\r\n");
        if (!core.validOid(merge_base)) return error.InvalidMergeBase;

        const patch = try self.diff(path, merge_base, pr.headRefOid);
        const prefix = patch[0..core.safePrefix(patch, diff_limit)];
        if (!std.unicode.utf8ValidateSlice(prefix)) return error.NonUtf8Diff;
        var evidence: std.ArrayList(u8) = .empty;
        const writer = evidence.writer(a);
        try writer.print("Merge-base diff:\n{s}", .{prefix});
        var coverage: std.ArrayList([]const u8) = .empty;
        if (prefix.len != patch.len) try coverage.append(a, "The merge base diff exceeded the byte limit.");
        if (files.len >= 3000) try coverage.append(a, "GitHub reached its changed file limit.");
        var sensitive_count: usize = 0;
        var patch_count: usize = 0;
        var invalid_path_count: usize = 0;
        var candidates: std.ArrayList([]const u8) = .empty;
        for (files) |file| {
            if (sensitive(file.filename)) {
                sensitive_count += 1;
            } else if (file.patch == null) {
                patch_count += 1;
            } else if (core.validPath(file.filename)) {
                try candidates.append(a, file.filename);
            } else {
                invalid_path_count += 1;
            }
        }
        if (sensitive_count != 0) try coverage.append(a, try io.fmt(a, "Sensitive changed paths omitted: {d}.", .{sensitive_count}));
        if (patch_count != 0) try coverage.append(a, try io.fmt(a, "Files without a GitHub patch: {d}.", .{patch_count}));
        if (invalid_path_count != 0) try coverage.append(a, try io.fmt(a, "Unsupported changed paths omitted: {d}.", .{invalid_path_count}));
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
        if (core.registryMain(self.object_cache.repo, pr)) {
            var route_bytes: usize = 6 * 1024;
            var route_files: usize = 0;
            for (candidates.items) |name| {
                const suffix = "-deploy.yaml";
                if (!std.mem.startsWith(u8, name, "deployments/warp_routes/") or !std.mem.endsWith(u8, name, suffix)) continue;
                if (route_files == 4 or route_bytes < 1024) break;
                route_files += 1;
                const config = try io.fmt(a, "{s}-config.yaml", .{name[0 .. name.len - suffix.len]});
                const oid = self.pinnedOid(path, pr.baseRefOid, config) catch continue;
                const blob = self.pinnedBlob(path, oid) catch continue;
                const excerpt = blob[0..core.safePrefix(blob, @min(blob.len, route_bytes -| (config.len + 64)))];
                if (excerpt.len == 0) continue;
                try writer.print("\nPinned base Warp route config {s}{s}:\n{s}\n", .{ config, if (excerpt.len == blob.len) "" else " (excerpt)", excerpt });
                route_bytes -= config.len + excerpt.len + 64;
            }
        }
        return .{ .merge_base = merge_base, .evidence = evidence.items, .limited = coverage.items.len != 0, .coverage_reasons = coverage.items };
    }

    fn pin(self: Git, repo_dir: std.fs.Dir, path: []const u8, pr: core.Pull) !void {
        const a = self.cmd.a;
        if (!core.validOid(pr.headRefOid) or !core.validOid(pr.baseRefOid)) return error.InvalidCommit;
        try self.prepare(repo_dir, path);
        const head_ref = "refs/talos/head";
        const base_ref = "refs/talos/base";
        const args = fetch_flags ++ [_][]const u8{
            "origin", try io.fmt(a, "+refs/pull/{d}/head:{s}", .{ pr.number, head_ref }), try io.fmt(a, "+{s}:{s}", .{ pr.baseRefOid, base_ref }),
        };
        _ = self.git(path, &args, "") catch return error.GitFetchFailed;
        if (!try self.cachedPinsMatch(path, pr)) return error.TargetChanged;
    }

    fn cachedPinsMatch(self: Git, path: []const u8, pr: core.Pull) !bool {
        const raw = self.git(path, &.{ "rev-parse", "refs/talos/head", "refs/talos/base" }, "") catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        const pins = io.trim(u8, raw, "\r\n");
        const a = self.cmd.a;
        const expected = try io.fmt(a, "{s}\n{s}", .{ pr.headRefOid, pr.baseRefOid });
        return eq(u8, pins, expected);
    }

    fn diff(self: Git, cache_path: []const u8, base: []const u8, head: []const u8) ![]const u8 {
        const args = diff_flags ++ [_][]const u8{ base, head, "--" } ++ excluded_paths;
        return self.git(cache_path, &args, "") catch return error.GitDiffFailed;
    }

    pub fn supplement(self: Git, pr: core.Pull, previous_head: ?[]const u8, requests: []const core.EvidenceRequest) !Supplement {
        const a = self.cmd.a;
        const previous = if (previous_head) |oid| if (eq(u8, oid, pr.headRefOid)) null else oid else null;
        if (previous == null and requests.len == 0) return .{};
        if (!core.validOid(pr.headRefOid) or !core.validOid(pr.baseRefOid)) return error.InvalidCommit;
        var repo_dir = (try self.object_cache.repoDir(true)) orelse return error.GitCacheInitFailed;
        defer repo_dir.close();
        const parent = try repo_dir.realpathAlloc(a, ".");
        const cache_path = try std.fs.path.join(a, &.{ parent, cache.directory });
        try self.object_cache.evict(repo_dir, std.time.timestamp());
        errdefer self.object_cache.evict(repo_dir, std.time.timestamp()) catch |err|
            std.log.warn("Git cache eviction failed for {s} ({s})", .{ self.object_cache.repo.name, @errorName(err) });
        if (!try self.cachedPinsMatch(cache_path, pr)) try self.pin(repo_dir, cache_path, pr);
        const result = try self.readSupplement(cache_path, pr.headRefOid, previous, requests);
        try self.object_cache.evict(repo_dir, std.time.timestamp());
        return result;
    }

    pub fn onchainReads(self: Git, pr: core.Pull, requests: []const onchain.Request, search_path: []const u8) ![]const onchain.Observation {
        if (!std.ascii.eqlIgnoreCase(self.object_cache.repo.name, onchain.registry_repo) or !eq(u8, pr.baseRefName, "main") or
            requests.len > onchain.max_reads) return error.InvalidOnchainRequest;
        const a = self.cmd.a;
        const results = try a.alloc(onchain.Observation, requests.len);
        for (results, requests) |*result, request| {
            if (!request.valid()) return error.InvalidOnchainRequest;
            result.* = .{ .request = request };
        }
        const curl = io.executable(a, search_path, "curl") catch return results;
        var repo_dir = (try self.object_cache.repoDir(true)) orelse return error.GitCacheInitFailed;
        defer repo_dir.close();
        const cache_path = try std.fs.path.join(a, &.{ try repo_dir.realpathAlloc(a, "."), cache.directory });
        defer self.object_cache.evict(repo_dir, std.time.timestamp()) catch |err|
            std.log.warn("Git cache eviction failed for {s} ({s})", .{ self.object_cache.repo.name, @errorName(err) });
        if (!try self.cachedPinsMatch(cache_path, pr)) try self.pin(repo_dir, cache_path, pr);

        var env = std.process.EnvMap.init(a);
        defer env.deinit();
        var command = self.cmd;
        command.env = &env;
        const client: onchain.Client = .{ .cmd = command, .curl = curl };
        var pins = std.StringHashMap(?onchain.Pin).init(a);
        defer pins.deinit();
        for (results) |*result| {
            const chain = result.request.chain;
            const entry = try pins.getOrPut(chain);
            if (!entry.found_existing) entry.value_ptr.* = pinned: {
                const file = try io.fmt(a, "chains/{s}/metadata.yaml", .{chain});
                const oid = self.pinnedOid(cache_path, pr.baseRefOid, file) catch break :pinned null;
                const metadata = self.pinnedBlob(cache_path, oid) catch break :pinned null;
                break :pinned client.pin(metadata) catch null;
            };
            const read_pin = entry.value_ptr.* orelse continue;
            result.block = read_pin.height;
            result.value = client.read(result.request, read_pin) catch null;
        }
        return results;
    }

    fn previousDiff(self: Git, cache_path: []const u8, previous: []const u8, head: []const u8) ![]const u8 {
        if (!core.validOid(previous)) return error.InvalidCommit;
        const commit = try io.fmt(self.cmd.a, "{s}^{{commit}}", .{previous});
        _ = self.git(cache_path, &.{ "cat-file", "-e", commit }, "") catch blk: {
            const target = try io.fmt(self.cmd.a, "+{s}:refs/talos/previous", .{previous});
            const args = fetch_flags ++ [_][]const u8{ "origin", target };
            break :blk try self.git(cache_path, &args, "");
        };
        return self.diff(cache_path, previous, head);
    }

    fn readSupplement(self: Git, cache_path: []const u8, head: []const u8, previous: ?[]const u8, requests: []const core.EvidenceRequest) !Supplement {
        const a = self.cmd.a;
        var evidence: std.ArrayList(u8) = .empty;
        const writer = evidence.writer(a);
        var coverage: std.ArrayList([]const u8) = .empty;
        if (previous) |oid| {
            const delta = self.previousDiff(cache_path, oid, head) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            if (delta) |raw| {
                const prefix = raw[0..core.safePrefix(raw, delta_limit)];
                if (std.unicode.utf8ValidateSlice(prefix)) {
                    try writer.print("Previous reviewed head {s} to current head {s}:\n{s}\n", .{ oid, head, prefix });
                    if (prefix.len != raw.len) {
                        try writer.writeAll("Previous-head diff was truncated.\n");
                        try coverage.append(a, "The previous diff exceeded the byte limit.");
                    }
                } else {
                    try writer.writeAll("The previous diff could not be read as UTF-8.\n");
                    try coverage.append(a, "The previous diff could not be read as UTF-8.");
                }
            } else {
                try writer.writeAll("The previous diff was unavailable.\n");
                try coverage.append(a, "The previous diff was unavailable.");
            }
        }
        var remaining: usize = supplement_limit;
        var requests_incomplete = requests.len > max_requests;
        for (requests[0..@min(requests.len, max_requests)], 1..) |request, index| {
            if (self.appendExcerpt(cache_path, head, request, &evidence, &remaining)) |complete| {
                requests_incomplete = requests_incomplete or !complete;
            } else |err| {
                if (err == error.OutOfMemory) return err;
                try writer.print("Evidence request {d} omitted ({s}).\n", .{ index, excerptOmission(err) });
                requests_incomplete = true;
            }
        }
        if (requests.len > max_requests) {
            try writer.writeAll("Remaining evidence requests omitted (request budget).\n");
        }
        if (requests_incomplete) try coverage.append(a, "Some requested pinned source excerpts were omitted or clipped.");
        return .{ .evidence = evidence.items, .limited = coverage.items.len != 0, .coverage_reasons = coverage.items };
    }

    fn appendExcerpt(self: Git, cache_path: []const u8, head: []const u8, request: core.EvidenceRequest, evidence: *std.ArrayList(u8), remaining: *usize) !bool {
        const a = self.cmd.a;
        if (!core.validPath(request.path) or sensitive(request.path)) return error.DisallowedExcerptPath;
        const lines = try excerptRange(request.start_line, request.end_line);
        if (remaining.* <= request.path.len + 160) return error.ExcerptBudget;
        const blob = try self.pinnedBlob(cache_path, try self.pinnedOid(cache_path, head, request.path));
        const excerpt = try excerptLines(blob, lines);
        const prefix = excerpt.text[0..core.safePrefix(excerpt.text, remaining.* - request.path.len - 160)];
        const complete = !(excerpt.more and (lines.clipped or request.end_line == null)) and prefix.len == excerpt.text.len;
        const start = evidence.items.len;
        try evidence.writer(a).print("\nPinned head file {s}, lines {d}-{d}{s}:\n{s}\n", .{
            request.path, lines.start, excerpt.end, if (complete) "" else " (excerpt clipped by budget)", prefix,
        });
        remaining.* -= evidence.items.len - start;
        return complete;
    }

    fn pinnedOid(self: Git, cache_path: []const u8, head: []const u8, file: []const u8) ![]const u8 {
        const pathspec = try io.fmt(self.cmd.a, ":(literal){s}", .{file});
        const entry = try self.gitWithin(cache_path, &.{ "ls-tree", "-z", "--full-tree", head, "--", pathspec }, "", 20);
        return excerptOid(entry, file);
    }

    fn pinnedBlob(self: Git, cache_path: []const u8, oid: []const u8) ![]const u8 {
        const text = io.trim(u8, try self.gitWithin(cache_path, &.{ "cat-file", "-s", oid }, "", 30), "\r\n");
        const size = try std.fmt.parseUnsigned(usize, text, 10);
        if (size > excerpt_blob_limit) return error.ExcerptTooLarge;
        const blob = try self.gitWithin(cache_path, &.{ "cat-file", "blob", oid }, "", 20);
        if (blob.len != size or !std.unicode.utf8ValidateSlice(blob) or std.mem.indexOfScalar(u8, blob, 0) != null)
            return error.ExcerptNotText;
        return blob;
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

fn excerptOid(entry: []const u8, path: []const u8) ![]const u8 {
    if (entry.len == 0) return error.ExcerptMissing;
    const separator = std.mem.indexOfScalar(u8, entry, '\t') orelse return error.InvalidTreeEntry;
    const header = entry[0..separator];
    const filename = entry[separator + 1 ..];
    if (filename.len != path.len + 1 or filename[path.len] != 0 or !eq(u8, filename[0..path.len], path))
        return error.InvalidTreeEntry;
    const prefix = "100644 blob ";
    if (!std.mem.startsWith(u8, header, prefix) and !std.mem.startsWith(u8, header, "100755 blob "))
        return error.DisallowedTreeEntry;
    const oid = header[prefix.len..];
    if (!core.validOid(oid)) return error.InvalidTreeEntry;
    return oid;
}

const ExcerptRange = struct { start: u32, end: u32, clipped: bool };

fn excerptRange(start: ?u32, end: ?u32) !ExcerptRange {
    const first = start orelse 1;
    const limit = first +| (excerpt_line_limit - 1);
    const last = end orelse limit;
    if (first == 0 or last < first) return error.InvalidExcerptRange;
    return .{ .start = first, .end = @min(last, limit), .clipped = last > limit };
}

fn excerptLines(blob: []const u8, request: ExcerptRange) !struct { text: []const u8, end: u32, more: bool } {
    var remaining = blob;
    var line: u32 = 1;
    while (line < request.start) : (line += 1) {
        const next = std.mem.indexOfScalar(u8, remaining, '\n') orelse return error.ExcerptPastEnd;
        remaining = remaining[next + 1 ..];
    }
    if (remaining.len == 0) return error.ExcerptPastEnd;
    var length: usize = 0;
    while (true) {
        const next = std.mem.indexOfScalar(u8, remaining[length..], '\n') orelse {
            length = remaining.len;
            break;
        };
        length += next + 1;
        if (line == request.end or length == remaining.len) break;
        line += 1;
    }
    return .{ .text = remaining[0..length], .end = line, .more = length < remaining.len };
}

fn excerptOmission(err: anyerror) []const u8 {
    return switch (err) {
        error.DisallowedExcerptPath => "invalid or sensitive path",
        error.InvalidExcerptRange => "invalid line range",
        error.ExcerptBudget => "byte budget",
        error.ExcerptMissing => "path absent at the pinned head",
        error.DisallowedTreeEntry => "path is not a regular tracked file",
        error.ExcerptTooLarge => "file exceeds the size limit",
        error.ExcerptNotText => "file is not UTF-8 text",
        error.ExcerptPastEnd => "range starts after the end of the file",
        else => "source could not be read",
    };
}

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

test "sensitive names keep existing Git exclusions and match root and nested basenames" {
    const t = std.testing;
    const previous = [_][]const u8{
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
    for (previous, excluded_paths) |expected, pathspec| try t.expectEqualStrings(expected, pathspec);
    inline for (.{ ".env", ".envrc", ".env.production", ".pem", "ca.pem", "server.key", "client.p12", "client.pfx", ".npmrc", ".netrc", "id_rsa", "id_ed25519" }) |name| {
        try t.expect(sensitive(name));
        try t.expect(sensitive("nested/dir/" ++ name));
    }
    inline for (.{ ".ENV.local", "env.local", "ca.PEM", "client.p12.txt", "server.key.example", ".npmrc.example", ".netrc.bak", "id_rsa.pub", "id_ed25519.pub" }) |name| {
        try t.expect(!sensitive(name));
        try t.expect(!sensitive("nested/dir/" ++ name));
    }
    try t.expect(!sensitive(".env/README.md"));
    try t.expect(!sensitive("nested/id_rsa/README.md"));
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

test "supplement reads a pinned caller and a previous-head delta and rejects invalid requests" {
    const t = std.testing;
    const bin = "/usr/bin/git";
    std.fs.accessAbsolute(bin, .{}) catch return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try io.temp(a);
    defer std.fs.deleteTreeAbsolute(path) catch {};
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    var env = std.process.EnvMap.init(a);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_AUTHOR_NAME", "Talos fixture");
    try env.put("GIT_AUTHOR_EMAIL", "talos@example.invalid");
    try env.put("GIT_COMMITTER_NAME", "Talos fixture");
    try env.put("GIT_COMMITTER_EMAIL", "talos@example.invalid");
    const git: Git = .{
        .cmd = .{ .a = a, .env = &env, .cwd = path, .dir = dir },
        .bin = bin,
        .gh = "/bin/false",
        .object_cache = .{ .a = a, .root = dir, .repo = .{ .name = "example/repo", .login = "reviewer" } },
    };
    _ = try git.cmd.run(&.{ bin, "init", "--bare", "--template=", path }, "", 10);
    const unchanged = io.trim(u8, try git.git(path, &.{ "hash-object", "-w", "--stdin" }, "skip\ncaller evidence\nskip too\n"), "\n");
    const secret = io.trim(u8, try git.git(path, &.{ "hash-object", "-w", "--stdin" }, "DO NOT PRESENT THIS VALUE"), "\n");
    var commits: [2][]const u8 = undefined;
    for (&commits, [_][]const u8{ "old behavior\n", "new behavior\n" }) |*commit, content| {
        const blob = io.trim(u8, try git.git(path, &.{ "hash-object", "-w", "--stdin" }, content), "\n");
        const input = try io.fmt(a, "100644 blob {s}\tcaller.zig\n100644 blob {s}\tchange.zig\n100644 blob {s}\t.env.local\n120000 blob {s}\tlinked.zig\n", .{ unchanged, blob, secret, secret });
        const tree = io.trim(u8, try git.git(path, &.{"mktree"}, input), "\n");
        commit.* = io.trim(u8, try git.git(path, &.{ "commit-tree", tree, "-m", "fixture" }, ""), "\n");
    }
    const result = try git.readSupplement(path, commits[1], commits[0], &.{
        .{ .path = "caller.zig", .start_line = 2, .end_line = 2 },
        .{ .path = ".env.local", .start_line = null, .end_line = null },
        .{ .path = "linked.zig", .start_line = null, .end_line = null },
        .{ .path = "../caller.zig", .start_line = null, .end_line = null },
        .{ .path = "untracked.zig", .start_line = 1, .end_line = null },
        .{ .path = "caller.zig", .start_line = 20, .end_line = null },
        .{ .path = "over-budget.zig", .start_line = 1, .end_line = null },
    });
    try t.expect(result.limited);
    for ([_][]const u8{ "\n-old behavior\n+new behavior", "caller.zig, lines 2-2:\ncaller evidence", "invalid or sensitive path", "not a regular tracked file", "path absent at the pinned head", "range starts after the end", "request budget" }) |part| {
        try t.expect(std.mem.indexOf(u8, result.evidence, part) != null);
    }
    for ([_][]const u8{ "skip too", "DO NOT PRESENT", "over-budget.zig" }) |part| {
        try t.expect(std.mem.indexOf(u8, result.evidence, part) == null);
    }
}

test "source excerpts cap requested lines and preserve the last line without a newline" {
    const t = std.testing;
    try t.expectError(error.InvalidExcerptRange, excerptRange(5, 2));
    const bounded = try excerptRange(20, 200);
    try t.expectEqual(@as(u32, 139), bounded.end);
    try t.expect(bounded.clipped);
    const excerpt = try excerptLines("one\ntwo\nthree", try excerptRange(2, 4));
    try t.expectEqualStrings("two\nthree", excerpt.text);
    try t.expectEqual(@as(u32, 3), excerpt.end);
    try t.expect(!excerpt.more);
    try t.expect((try excerptLines("one\ntwo\nthree", try excerptRange(2, 2))).more);
    try t.expectError(error.ExcerptPastEnd, excerptLines("one\n", try excerptRange(2, null)));
}
