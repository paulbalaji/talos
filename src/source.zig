const std = @import("std");
const core = @import("core.zig");
const github = @import("github.zig");
const io = @import("io.zig");
const cache = @import("cache.zig");
const onchain = @import("onchain.zig");
const routing = @import("routing.zig");
const registry_logo = @import("registry_logo.zig");
const agent_image = @import("agent_image.zig");
const warp_capacity = @import("warp_capacity.zig");
const A = io.A;
const eq = io.eq;

const diff_limit = 48 * 1024;
const context_limit = 24 * 1024;
const max_blob_size = 16 * 1024;
const batch_size = 32;
const thread_context_limit = 12 * 1024;
const thread_excerpt_limit = 2 * 1024;
const max_thread_excerpts = 12;
pub const max_requests = core.max_evidence_requests;
const supplement_limit = 16 * 1024;
const delta_limit = 12 * 1024;
const excerpt_blob_limit = 128 * 1024;
const excerpt_line_limit = 120;
const registry_diff_limit = 16 * 1024;
const registry_pin_path = ".registryrc";
const agent_image_diff_limit = 16 * 1024;
const agent_image_inventory_limit = 24 * 1024;
const AgentEvidence = struct { promotion: bool = false, optional_start: ?usize = null };
const AgentPromotion = struct { tag: []const u8, commit: []const u8, previous: []const u8 };
const agent_image_diff_paths = [_][]const u8{ ".dockerignore", ".github/workflows/rust-docker.yml", "rust/Dockerfile", "rust/main", "rust/sealevel" };
const agent_image_diff_order =
    \\.github/workflows/rust-docker.yml
    \\.dockerignore
    \\rust/Dockerfile
    \\rust/main/config
    \\rust/main/app-contexts
    \\rust/main/agents/relayer
    \\rust/main/hyperlane-base
    \\rust/main/hyperlane-core
;

pub const Supplement = struct {
    evidence: []const u8 = "",
    limited: bool = false,
    coverage_reasons: []const []const u8 = &.{},
    excerpts: []const struct { request: core.EvidenceRequest, end_offset: usize } = &.{},
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

const DiffPriority = enum { thread, risk, source, supporting };
const PrioritizedFile = struct { file: github.File, priority: DiffPriority };

fn prioritizeFiles(a: A, files: []const github.File, threads: []const core.Thread) ![]const PrioritizedFile {
    var open_paths: std.StringHashMapUnmanaged(void) = .empty;
    defer open_paths.deinit(a);
    for (threads) |thread| {
        if (!thread.isResolved and !thread.isOutdated) try open_paths.put(a, thread.path, {});
    }
    var ordered: std.ArrayList(PrioritizedFile) = .empty;
    for (files) |file| {
        if (!core.validPath(file.filename) or sensitive(file.filename)) continue;
        const priority: DiffPriority = if (open_paths.contains(file.filename))
            .thread
        else if (supportingFile(file.filename))
            .supporting
        else switch (routing.inspect(&[_]github.File{file}, false).floor.depth) {
            .multi, .focused => .risk,
            .regular, .light => .source,
        };
        try ordered.append(a, .{ .file = file, .priority = priority });
    }
    std.mem.sort(PrioritizedFile, ordered.items, {}, struct {
        fn lessThan(_: void, left: PrioritizedFile, right: PrioritizedFile) bool {
            if (left.priority != right.priority) return @intFromEnum(left.priority) < @intFromEnum(right.priority);
            return std.mem.lessThan(u8, left.file.filename, right.file.filename);
        }
    }.lessThan);
    return ordered.toOwnedSlice(a);
}

fn supportingFile(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    return std.ascii.endsWithIgnoreCase(name, ".md") or std.ascii.endsWithIgnoreCase(name, ".lock") or
        eq(u8, name, "pnpm-lock.yaml") or eq(u8, name, "package-lock.json");
}

pub const Git = struct {
    cmd: io.Command,
    bin: []const u8,
    gh: []const u8,
    object_cache: cache.Cache,
    github_calls: ?*u32 = null,

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

    pub fn snapshot(self: Git, pr: core.Pull, files: []const github.File, threads: []const core.Thread) !core.Snapshot {
        var repo_dir = (try self.object_cache.repoDir(true)) orelse return error.GitCacheInitFailed;
        defer repo_dir.close();
        const parent = try repo_dir.realpathAlloc(self.cmd.a, ".");
        const path = try std.fs.path.join(self.cmd.a, &.{ parent, cache.directory });
        try self.object_cache.evict(repo_dir, std.time.timestamp());
        const result = self.readSnapshot(repo_dir, path, pr, files, threads) catch |err| {
            self.object_cache.evict(repo_dir, std.time.timestamp()) catch |cache_err|
                std.log.warn("Git cache eviction failed for {s} ({s})", .{ self.object_cache.repo.name, @errorName(cache_err) });
            return err;
        };
        try self.object_cache.evict(repo_dir, std.time.timestamp());
        return result;
    }

    fn readSnapshot(self: Git, repo_dir: std.fs.Dir, path: []const u8, pr: core.Pull, files: []const github.File, threads: []const core.Thread) !core.Snapshot {
        const a = self.cmd.a;
        try self.pin(repo_dir, path, pr);
        const merge_base = io.trim(u8, try self.git(path, &.{ "merge-base", pr.baseRefOid, pr.headRefOid }, ""), "\r\n");
        if (!core.validOid(merge_base)) return error.InvalidMergeBase;

        const ordered = try prioritizeFiles(a, files, threads);
        const patch = try self.orderedDiff(path, merge_base, pr.headRefOid, ordered);
        const prefix = patch[0..core.safePrefix(patch, diff_limit)];
        if (!std.unicode.utf8ValidateSlice(prefix)) return error.NonUtf8Diff;
        var evidence: std.ArrayList(u8) = .empty;
        var remaining: usize = context_limit;
        const missing_threads = try self.appendThreadExcerpts(path, pr.headRefOid, files, threads, prefix.len == patch.len, &evidence, &remaining);
        const writer = evidence.writer(a);
        if (evidence.items.len != 0) try writer.writeAll("\n\n");
        try writer.print("Merge-base diff:\n{s}", .{prefix});
        var coverage: std.ArrayList([]const u8) = .empty;
        if (prefix.len != patch.len) try coverage.append(a, "The merge base diff exceeded the byte limit.");
        if (missing_threads != 0) try coverage.append(a, try io.fmt(a, "Current source excerpts were unavailable for {d} active review thread anchors.", .{missing_threads}));
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
            } else if (!core.validPath(file.filename)) {
                invalid_path_count += 1;
            }
        }
        for (ordered) |item| {
            if (item.file.patch != null) try candidates.append(a, item.file.filename);
        }
        if (sensitive_count != 0) try coverage.append(a, try io.fmt(a, "Sensitive changed paths omitted: {d}.", .{sensitive_count}));
        if (patch_count != 0) try coverage.append(a, try io.fmt(a, "Files without a GitHub patch: {d}.", .{patch_count}));
        if (invalid_path_count != 0) try coverage.append(a, try io.fmt(a, "Unsupported changed paths omitted: {d}.", .{invalid_path_count}));
        const logo_only = core.registryMain(self.object_cache.repo, pr) and coverage.items.len == 0 and
            registry_logo.candidate(files, patch) and try self.appendStaticRegistryLogos(path, merge_base, pr.headRefOid, files, &evidence, remaining);
        var offset: usize = 0;
        while (!logo_only and offset < candidates.items.len and remaining >= 1024) : (offset += batch_size) {
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
        var onchain_reads: []const onchain.Request = &.{};
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
            onchain_reads = try self.warpCapacityRequests(path, pr, merge_base, files);
        }
        var image: AgentEvidence = .{};
        if (std.ascii.eqlIgnoreCase(self.object_cache.repo.name, github.registry_pin_source)) {
            try self.appendRegistryComparison(path, merge_base, pr.headRefOid, &evidence, &coverage);
            if (eq(u8, pr.baseRefName, "main")) {
                for (files) |file| {
                    if (!eq(u8, file.filename, agent_image.pin_path) or !eq(u8, file.status, "modified")) continue;
                    image = try self.appendAgentImages(path, pr, merge_base, files.len == 1, &evidence, &coverage);
                    break;
                }
            }
        }
        return .{ .merge_base = merge_base, .evidence = evidence.items, .limited = coverage.items.len != 0, .coverage_reasons = coverage.items, .registry_logo_only = logo_only, .relayer_promotion = image.promotion, .optional_evidence_start = image.optional_start, .onchain_reads = onchain_reads };
    }

    fn warpCapacityRequests(self: Git, path: []const u8, pr: core.Pull, merge_base: []const u8, files: []const github.File) ![]const onchain.Request {
        if (files.len == 0 or files.len > 2) return &.{};
        const suffix = "-deploy.yaml";
        var deployment: ?[]const u8 = null;
        for (files) |file| {
            if (file.previous_filename != null or !core.validPath(file.filename) or sensitive(file.filename)) return &.{};
            if (std.mem.startsWith(u8, file.filename, "deployments/warp_routes/") and std.mem.endsWith(u8, file.filename, suffix) and eq(u8, file.status, "modified")) {
                if (deployment != null) return &.{};
                deployment = file.filename;
            } else if (!(std.mem.startsWith(u8, file.filename, ".changeset/") and std.mem.endsWith(u8, file.filename, ".md") and eq(u8, file.status, "added"))) return &.{};
        }
        const name = deployment orelse return &.{};
        const raw = self.gitWithin(path, &.{ "diff", "--name-status", "--no-renames", "-z", merge_base, pr.headRefOid, "--" }, "", 5) catch return &.{};
        var entries = std.mem.tokenizeScalar(u8, raw, 0);
        var count: usize = 0;
        while (entries.next()) |status| {
            const changed = entries.next() orelse return &.{};
            for (files) |file| {
                const expected_status = if (eq(u8, file.status, "modified")) "M" else "A";
                if (eq(u8, file.filename, changed) and eq(u8, status, expected_status)) break;
            } else return &.{};
            count += 1;
        }
        if (count != files.len) return &.{};
        const config = try io.fmt(self.cmd.a, "{s}-config.yaml", .{name[0 .. name.len - suffix.len]});
        const route = self.pinnedOid(path, pr.baseRefOid, config) catch return &.{};
        if (!eq(u8, route, self.pinnedOid(path, pr.headRefOid, config) catch return &.{})) return &.{};
        const before = self.pinnedBlob(path, self.pinnedOid(path, merge_base, name) catch return &.{}) catch return &.{};
        const after = self.pinnedBlob(path, self.pinnedOid(path, pr.headRefOid, name) catch return &.{}) catch return &.{};
        return warp_capacity.requests(self.cmd.a, before, after, self.pinnedBlob(path, route) catch return &.{});
    }

    fn appendStaticRegistryLogos(self: Git, path: []const u8, base: []const u8, head: []const u8, files: []const github.File, evidence: *std.ArrayList(u8), remaining: usize) !bool {
        const a = self.cmd.a;
        var logos: std.ArrayList(u8) = .empty;
        defer logos.deinit(a);
        const writer = logos.writer(a);
        for (files) |file| {
            const new = try self.logoBlob(path, head, file.filename) orelse return false;
            if (registry_logo.isLogo(file.filename)) {
                const old = try self.logoBlob(path, base, file.filename) orelse return false;
                if (!registry_logo.staticSvg(old) or !registry_logo.staticSvg(new)) return false;
                try writer.print("\n\nMerge-base file {s}:\n{s}", .{ file.filename, old });
            } else if (!registry_logo.patchChangeset(new)) return false;
            try writer.print("\n\nHead file {s}:\n{s}", .{ file.filename, new });
            if (logos.items.len > remaining) return false;
        }
        try evidence.appendSlice(a, logos.items);
        return true;
    }

    fn logoBlob(self: Git, path: []const u8, commit: []const u8, name: []const u8) !?[]const u8 {
        const oid = self.pinnedOid(path, commit, name) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        const blob = self.pinnedBlob(path, oid) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        return if (blob.len <= 8 * 1024) blob else null;
    }

    fn registryPinBlob(self: Git, path: []const u8, commit: []const u8) !?[]const u8 {
        return self.pinnedOid(path, commit, registry_pin_path) catch |err| switch (err) {
            error.ExcerptMissing => null,
            else => return err,
        };
    }

    fn registryPins(self: Git, path: []const u8, merge_base: []const u8, head: []const u8) !?struct { before: []const u8, after: []const u8 } {
        const old_blob = try self.registryPinBlob(path, merge_base);
        const new_blob = try self.registryPinBlob(path, head);
        if (old_blob == null and new_blob == null) return null;
        const before_blob = old_blob orelse return error.RegistryPinMissing;
        const after_blob = new_blob orelse return error.RegistryPinMissing;
        if (eq(u8, before_blob, after_blob)) return null;
        const before = io.trim(u8, try self.pinnedBlob(path, before_blob), " \t\r\n");
        const after = io.trim(u8, try self.pinnedBlob(path, after_blob), " \t\r\n");
        if (!core.validOid(before) or !core.validOid(after)) return error.InvalidRegistryPins;
        return if (eq(u8, before, after)) null else .{ .before = before, .after = after };
    }

    fn appendRegistryComparison(self: Git, path: []const u8, merge_base: []const u8, head: []const u8, evidence: *std.ArrayList(u8), coverage: *std.ArrayList([]const u8)) !void {
        const a = self.cmd.a;
        const pins = (self.registryPins(path, merge_base, head) catch |err| {
            const reason = switch (err) {
                error.OutOfMemory => return err,
                error.RegistryPinMissing => ".registryrc is missing on one side of the pin change.",
                error.InvalidRegistryPins => "Registry pin comparison requires one full commit SHA in .registryrc on both sides of the change.",
                error.DisallowedTreeEntry => ".registryrc must be a regular tracked file.",
                else => "Could not read .registryrc at the pinned pull request commits.",
            };
            try coverage.append(a, reason);
            return;
        }) orelse return;
        const client: github.Client = .{ .cmd = self.cmd, .gh = self.gh, .repo = self.object_cache.repo.name, .calls = self.github_calls };
        const files = client.registryFiles(pins.before, pins.after) catch |err| {
            const reason = switch (err) {
                error.OutOfMemory, error.GitHubRateLimited => return err,
                error.RegistryPinNotFastForward => "The new registry revision does not descend from the previous pin.",
                error.RegistryCompareIncomplete => "GitHub omitted commits from the registry pin comparison.",
                error.RegistryCompareMismatch => "GitHub did not confirm the exact registry pins.",
                else => "The exact registry pin comparison was unavailable.",
            };
            try coverage.append(a, reason);
            return;
        };
        try evidence.writer(a).print("\n\nPinned {s} dependency diff, {s} to {s} ({d} paths returned):\n", .{ onchain.registry_repo, pins.before, pins.after, files.len });
        try appendRegistryFiles(a, evidence, coverage, files);
    }

    fn readAgentPinFile(self: Git, path: []const u8, commit: []const u8) ![]const u8 {
        return self.pinnedBlob(path, try self.pinnedOid(path, commit, agent_image.pin_path));
    }

    fn appendAgentImages(self: Git, path: []const u8, pr: core.Pull, base: []const u8, single_file: bool, evidence: *std.ArrayList(u8), coverage: *std.ArrayList([]const u8)) !AgentEvidence {
        const a = self.cmd.a;
        const before_file = self.readAgentPinFile(path, base) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{},
        };
        const after_file = self.readAgentPinFile(path, pr.headRefOid) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{},
        };
        const before = agent_image.pins(before_file) orelse return .{};
        const after = agent_image.pins(after_file) orelse return .{};
        const target = if (single_file) agent_image.promotionTag(before_file, after_file, before, after) else null;
        const promotion = if (target) |tag| try self.agentPromotion(path, pr, base, before, after, tag) else null;
        var tags: std.ArrayList([]const u8) = .empty;
        if (promotion) |rollout| {
            try tags.append(a, rollout.tag);
        } else for (before, after) |old, new| {
            if (eq(u8, old, new)) continue;
            for ([_][]const u8{ old, new }) |tag| {
                if (!agent_image.validTag(tag)) continue;
                for (tags.items) |prior| {
                    if (eq(u8, prior, tag)) break;
                } else try tags.append(a, tag);
            }
        }
        if (tags.items.len == 0) return .{};
        const writer = evidence.writer(a);
        try writer.writeAll("\n\nHyperlane Rust agent image evidence. GHCR observations describe the tags at review time. Successful main workflow logs corroborate the published manifest digests. Image layers were not opened.\n");
        try self.appendAgentSelectors(path, pr.headRefOid, before, after, evidence, coverage);
        if (tags.items.len > agent_image.max_tags) {
            try coverage.append(a, "Relayer image tags exceeded the verification budget.");
            return .{};
        }
        var timer = try std.time.Timer.start();
        const client: github.Client = .{ .cmd = self.cmd, .gh = self.gh, .repo = self.object_cache.repo.name, .calls = self.github_calls };
        var network_env = std.process.EnvMap.init(a);
        defer network_env.deinit();
        var command = self.cmd;
        command.env = &network_env;
        const curl = io.executable(a, self.cmd.env.get("PATH") orelse "/usr/bin:/bin", "curl") catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => "",
        };
        const registry: agent_image.Client = .{ .cmd = command, .curl = curl, .timer = &timer, .limit = 30 };
        const bearer: ?[]const u8 = if (curl.len == 0) null else registry.token() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        var commits: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer commits.deinit(a);
        for (tags.items) |tag| {
            const commit = if (promotion) |rollout| rollout.commit else self.resolveAgentCommit(path, tag) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try coverage.append(a, try io.fmt(a, "Could not resolve an exact source commit for agent image {s}.", .{tag}));
                    continue;
                },
            };
            try commits.put(a, tag, commit);
            const verified = if (bearer) |token| check: {
                const digest = registry.digest(token, tag) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => break :check false,
                };
                const run = client.agentImageBuild(commit, tag, digest, &timer, registry.limit) catch |err| switch (err) {
                    error.OutOfMemory, error.GitHubRateLimited => return err,
                    else => break :check false,
                };
                try writer.print("ghcr.io/" ++ agent_image.registry_image ++ ":{s}@{s} was pushed by main workflow run {d} at source {s}.\n", .{ tag, digest, run, commit });
                break :check true;
            } else false;
            if (!verified) try coverage.append(a, try io.fmt(a, "Could not verify the published digest against a main build log for agent image {s}.", .{tag}));
        }
        if (promotion) |rollout| {
            if (coverage.items.len != 0) return .{};
            try writer.print("The PR merge base {s} already includes the promoted image source {s}. The changed slots previously used ancestor builds.\n", .{ base, rollout.commit });
            return .{ .promotion = true, .optional_start = try self.appendPromotionConfig(path, rollout.previous, rollout.commit, evidence) };
        }
        return .{ .optional_start = try self.appendAgentDiff(path, before, after, commits, evidence, coverage) };
    }

    fn agentPromotion(self: Git, path: []const u8, pr: core.Pull, base: []const u8, before: agent_image.Pins, after: agent_image.Pins, tag: []const u8) !?AgentPromotion {
        const change = self.gitWithin(path, &.{ "diff", "--raw", "--no-renames", "-z", base, pr.headRefOid, "--" }, "", 5) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        if (!agent_image.onlyPinFile(change)) return null;
        const promoted = self.resolveAgentCommit(path, tag) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        if (!try self.imageAncestor(path, promoted, base)) return null;
        if (!eq(u8, base, pr.baseRefOid)) {
            _ = self.gitWithin(path, &.{
                "diff",                                                   "--quiet",                                                base, pr.baseRefOid, "--", agent_image.pin_path,
                "typescript/infra/config/environments/mainnet3/agent.ts", "typescript/infra/config/environments/testnet4/agent.ts",
            }, "", 5) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return null,
            };
        }
        var previous: ?[]const u8 = null;
        for (before, after, 0..) |old, new, i| {
            if (eq(u8, old, new)) continue;
            for (before[0..i], after[0..i]) |earlier_old, earlier_new| {
                if (!eq(u8, earlier_old, earlier_new) and eq(u8, earlier_old, old)) break;
            } else {
                const commit = self.resolveAgentCommit(path, old) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return null,
                };
                if (!try self.imageAncestor(path, commit, promoted)) return null;
                if (previous == null) previous = commit;
            }
        }
        return .{ .tag = tag, .commit = promoted, .previous = previous orelse return null };
    }

    fn imageAncestor(self: Git, path: []const u8, before: []const u8, after: []const u8) !bool {
        _ = self.gitWithin(path, &.{ "merge-base", "--is-ancestor", before, after }, "", 5) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        return true;
    }

    fn appendPromotionConfig(self: Git, path: []const u8, before: []const u8, after: []const u8, evidence: *std.ArrayList(u8)) !?usize {
        const args = diff_flags ++ [_][]const u8{ before, after, "--", "rust/main/config" } ++ excluded_paths;
        const patch = self.gitWithin(path, &args, "", 5) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        if (patch.len == 0) return null;
        const prefix = patch[0..core.safePrefix(patch, 8 * 1024)];
        if (!std.unicode.utf8ValidateSlice(prefix)) return null;
        const start = evidence.items.len;
        try evidence.writer(self.cmd.a).print("\nBundled chain configuration diff from the first changed slot's previous image source{s}:\n{s}\n", .{
            if (prefix.len < patch.len) " (excerpt)" else "", prefix,
        });
        return start;
    }

    fn resolveAgentCommit(self: Git, path: []const u8, tag: []const u8) ![]const u8 {
        const rev = try io.fmt(self.cmd.a, "{s}^{{commit}}", .{tag[0..7]});
        const result = io.trim(u8, try self.gitWithin(path, &.{ "rev-parse", "--verify", "--end-of-options", rev }, "", 5), "\r\n");
        if (!core.validOid(result) or !std.mem.startsWith(u8, result, tag[0..7])) return error.InvalidAgentImageCommit;
        return result;
    }

    fn appendAgentSelectors(self: Git, path: []const u8, head: []const u8, before: agent_image.Pins, after: agent_image.Pins, evidence: *std.ArrayList(u8), coverage: *std.ArrayList([]const u8)) !void {
        const a = self.cmd.a;
        for (agent_image.environments, agent_image.exports, 0..) |environment, export_name, i| {
            const offset = i * agent_image.roles.len;
            const changed = for (before[offset..][0..agent_image.roles.len], after[offset..][0..agent_image.roles.len]) |old, new| {
                if (!eq(u8, old, new)) break true;
            } else false;
            if (!changed) continue;
            const filename = try io.fmt(a, "typescript/infra/config/environments/{s}/agent.ts", .{environment});
            var seen: [agent_image.roles.len]bool = @splat(false);
            const blob = selection: {
                const oid = self.pinnedOid(path, head, filename) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => break :selection "",
                };
                break :selection self.pinnedBlob(path, oid) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => "",
                };
            };
            var lines = std.mem.splitScalar(u8, blob, '\n');
            var preceding: []const u8 = "";
            var number: usize = 0;
            var fields: [agent_image.roles.len][]const u8 = undefined;
            for (agent_image.roles, &fields) |role, *field| field.* = try io.fmt(a, "tag: {s}.{s},", .{ export_name, role });
            while (lines.next()) |line| {
                number += 1;
                defer preceding = line;
                if (!eq(u8, io.trim(u8, preceding, " \t\r"), "repo: DockerImageRepos.AGENT,")) continue;
                for (fields, 0..) |field, j| {
                    if (seen[j] or eq(u8, before[offset + j], after[offset + j]) or !eq(u8, io.trim(u8, line, " \t\r"), field)) continue;
                    seen[j] = true;
                    try evidence.writer(a).print("Pinned deployment selector {s}:{d}-{d}:\n{s}\n{s}\n", .{ filename, number - 1, number, preceding, line });
                }
            }
            for (agent_image.roles, 0..) |role, j| {
                if (!seen[j] and !eq(u8, before[offset + j], after[offset + j]))
                    try coverage.append(a, try io.fmt(a, "The {s} deployment selector for {s} was unavailable.", .{ environment, role }));
            }
        }
    }

    fn appendAgentDiff(self: Git, path: []const u8, before: agent_image.Pins, after: agent_image.Pins, commits: std.StringHashMapUnmanaged([]const u8), evidence: *std.ArrayList(u8), coverage: *std.ArrayList([]const u8)) !?usize {
        const a = self.cmd.a;
        const Pair = struct { old: []const u8, new: []const u8, base: []const u8, head: []const u8 };
        var pairs: std.ArrayList(Pair) = .empty;
        var missing_pair = false;
        for (before, after) |old, new| {
            if (eq(u8, old, new)) continue;
            const base = commits.get(old);
            const head = commits.get(new);
            if (base == null or head == null) {
                missing_pair = true;
                continue;
            }
            for (pairs.items) |pair| {
                if (eq(u8, old, pair.old) and eq(u8, new, pair.new)) break;
            } else try pairs.append(a, .{ .old = old, .new = new, .base = base.?, .head = head.? });
        }
        if (missing_pair) try coverage.append(a, "Some relayer image changes lacked comparable pinned build source.");
        if (pairs.items.len == 0) return null;

        var timer = try std.time.Timer.start();
        const writer = evidence.writer(a);
        var inventory_left: usize = agent_image_inventory_limit;
        for (pairs.items) |pair| {
            const seconds = agent_image.remainingSeconds(&timer, 20) catch {
                try coverage.append(a, "Could not enumerate changed relayer build inputs within the time limit.");
                return null;
            };
            const args = [_][]const u8{ "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=none", "--numstat", "-z", pair.base, pair.head, "--" } ++ agent_image_diff_paths;
            const inventory = self.gitWithin(path, &args, "", seconds) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try coverage.append(a, try io.fmt(a, "Could not enumerate changed build inputs from {s} to {s}.", .{ pair.old, pair.new }));
                    continue;
                },
            };
            try writer.print("\nChanged agent build inputs {s} to {s} ({s} to {s}), in additions/deletions/path format:\n", .{ pair.old, pair.new, pair.base, pair.head });
            if (!try appendAgentInventory(a, evidence, inventory, &inventory_left))
                try coverage.append(a, try io.fmt(a, "The changed build input inventory from {s} to {s} could not include every path.", .{ pair.old, pair.new }));
        }

        const excerpt_start = evidence.items.len;
        const order_file = "agent-build-order";
        try io.write(self.cmd.dir, order_file, agent_image_diff_order);
        defer self.cmd.dir.deleteFile(order_file) catch {};
        const order = try io.fmt(a, "-O{s}/{s}", .{ self.cmd.cwd, order_file });
        const patch_limit = agent_image_diff_limit / pairs.items.len;
        for (pairs.items) |pair| {
            const args = diff_flags ++ [_][]const u8{ order, pair.base, pair.head, "--" } ++ agent_image_diff_paths ++ excluded_paths;
            const seconds = agent_image.remainingSeconds(&timer, 20) catch break;
            const patch = self.gitWithin(path, &args, "", seconds) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            const prefix = patch[0..core.safePrefix(patch, patch_limit)];
            if (!std.unicode.utf8ValidateSlice(prefix)) continue;
            const clipped = prefix.len != patch.len;
            const excerpt = if (clipped) prefix[0..(std.mem.lastIndexOfScalar(u8, prefix, '\n') orelse 0)] else prefix;
            try writer.print("\nPinned agent build-source diff {s} to {s}{s}:\n{s}\n", .{
                pair.old, pair.new, if (clipped) " (excerpt)" else "", excerpt,
            });
        }
        return if (excerpt_start < evidence.items.len) excerpt_start else null;
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

    fn orderedDiff(self: Git, cache_path: []const u8, base: []const u8, head: []const u8, files: []const PrioritizedFile) ![]const u8 {
        if (files.len == 0) return self.diff(cache_path, base, head);
        const a = self.cmd.a;
        const order_file = "diff-order";
        var patterns: std.ArrayList(u8) = .empty;
        for (files) |item| {
            for (item.file.filename, 0..) |byte, i| {
                // Git treats order-file lines as glob patterns and leading # as a comment.
                if (byte == '*' or byte == '?' or byte == '[' or (byte == '#' and i == 0)) try patterns.append(a, '\\');
                try patterns.append(a, byte);
            }
            try patterns.append(a, '\n');
        }
        try io.write(self.cmd.dir, order_file, patterns.items);
        defer self.cmd.dir.deleteFile(order_file) catch {};
        const option = try io.fmt(a, "-O{s}/{s}", .{ self.cmd.cwd, order_file });
        const args = diff_flags ++ [_][]const u8{ option, base, head, "--" } ++ excluded_paths;
        return self.git(cache_path, &args, "") catch return error.GitDiffFailed;
    }

    fn appendThreadExcerpts(self: Git, cache_path: []const u8, head: []const u8, files: []const github.File, threads: []const core.Thread, diff_complete: bool, evidence: *std.ArrayList(u8), remaining: *usize) !usize {
        var seen: [max_thread_excerpts]struct { path: []const u8, line: u32 } = undefined;
        var attempted: usize = 0;
        var missing: usize = 0;
        var thread_remaining: usize = @min(thread_context_limit, remaining.*);
        for (threads) |thread| {
            if (thread.isResolved or thread.isOutdated or thread.diffSide != .RIGHT) continue;
            const line = thread.line orelse continue;
            const duplicate = for (seen[0..attempted]) |target| {
                if (target.line == line and eq(u8, target.path, thread.path)) break true;
            } else false;
            if (duplicate) continue;
            if (line != 0 and attempted < seen.len and thread_remaining > thread.path.len + 160 and
                core.validPath(thread.path) and !sensitive(thread.path))
            {
                seen[attempted] = .{ .path = thread.path, .line = line };
                attempted += 1;
                const budget: usize = @min(thread_remaining, thread_excerpt_limit);
                var left = budget;
                const request: core.EvidenceRequest = .{ .path = thread.path, .start_line = @max(1, line -| 8), .end_line = line +| 8 };
                const complete = self.appendExcerpt(cache_path, head, request, line, evidence, &left) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => false,
                };
                thread_remaining -= budget - left;
                remaining.* -= budget - left;
                if (complete) continue;
            }
            if (!diff_complete or !anchor(files, thread.path, line)) missing += 1;
        }
        return missing;
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
        var timer = try std.time.Timer.start();
        const client: onchain.Client = .{ .cmd = command, .curl = curl, .timer = &timer };
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
            const reading = client.read(result.request, read_pin) catch continue;
            result.value = reading.value;
            result.resolved_address = reading.resolved_address;
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
        var excerpts: std.ArrayList(std.meta.Child(@FieldType(Supplement, "excerpts"))) = .empty;
        for (requests[0..@min(requests.len, max_requests)], 1..) |request, index| {
            if (self.appendExcerpt(cache_path, head, request, null, &evidence, &remaining)) |complete| {
                requests_incomplete = requests_incomplete or !complete;
                try excerpts.append(a, .{ .request = request, .end_offset = evidence.items.len });
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
        return .{ .evidence = evidence.items, .limited = coverage.items.len != 0, .coverage_reasons = coverage.items, .excerpts = excerpts.items };
    }

    fn appendExcerpt(self: Git, cache_path: []const u8, head: []const u8, request: core.EvidenceRequest, anchor_line: ?u32, evidence: *std.ArrayList(u8), remaining: *usize) !bool {
        const a = self.cmd.a;
        if (!core.validPath(request.path) or sensitive(request.path)) return error.DisallowedExcerptPath;
        if (remaining.* <= request.path.len + 160) return error.ExcerptBudget;
        const blob = try self.pinnedBlob(cache_path, try self.pinnedOid(cache_path, head, request.path));
        const lines = if (request.line_contains) |needle| try anchoredRange(blob, needle) else try excerptRange(request.start_line, request.end_line);
        const excerpt = try excerptLines(blob, lines);
        if (anchor_line) |line| {
            if (excerpt.end < line) return error.ExcerptPastEnd;
        }
        const prefix = excerpt.text[0..core.safePrefix(excerpt.text, remaining.* - request.path.len - 160)];
        const complete = !(excerpt.more and (lines.clipped or (request.end_line == null and request.line_contains == null))) and prefix.len == excerpt.text.len;
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

fn registryPatchComplete(file: github.File) bool {
    const additions = file.additions orelse return false;
    const deletions = file.deletions orelse return false;
    const patch = file.patch orelse return false;
    if (!std.mem.startsWith(u8, patch, "@@ -") or !std.unicode.utf8ValidateSlice(patch) or std.mem.indexOfScalar(u8, patch, 0) != null)
        return false;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    var added: u32 = 0;
    var deleted: u32 = 0;
    var left: u32 = 0;
    var right: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        switch (line[0]) {
            '@' => {
                if (left != 0 or right != 0) return false;
                const hunk = hunkRanges(line) orelse return false;
                left = hunk.left.count;
                right = hunk.right.count;
            },
            '+' => {
                if (right == 0) return false;
                right -= 1;
                added +|= 1;
            },
            '-' => {
                if (left == 0) return false;
                left -= 1;
                deleted +|= 1;
            },
            ' ' => {
                if (left == 0 or right == 0) return false;
                left -= 1;
                right -= 1;
            },
            '\\' => if (!eq(u8, line, "\\ No newline at end of file")) return false,
            else => return false,
        }
    }
    return left == 0 and right == 0 and added == additions and deleted == deletions;
}

fn appendAgentInventory(a: A, evidence: *std.ArrayList(u8), inventory: []const u8, remaining: *usize) !bool {
    if (inventory.len == 0) {
        try evidence.appendSlice(a, "No build inputs changed.\n");
        return true;
    }
    var complete = inventory[inventory.len - 1] == 0;
    var records = std.mem.tokenizeScalar(u8, inventory, 0);
    while (records.next()) |record| {
        var fields = std.mem.splitScalar(u8, record, '\t');
        const added = fields.next() orelse unreachable;
        const deleted = fields.next() orelse "";
        const path = fields.rest();
        const binary = eq(u8, added, "-") and eq(u8, deleted, "-");
        if ((!binary and (!gitLineCount(added) or !gitLineCount(deleted))) or !core.validPath(path) or sensitive(path)) {
            complete = false;
            continue;
        }
        if (record.len + 1 > remaining.*) return false;
        try evidence.writer(a).print("{s}\n", .{record});
        remaining.* -= record.len + 1;
    }
    return complete;
}

fn gitLineCount(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn appendRegistryFiles(a: A, evidence: *std.ArrayList(u8), coverage: *std.ArrayList([]const u8), files: []const github.File) !void {
    if (files.len >= github.registry_compare_file_limit) try coverage.append(a, "The registry pin comparison reached GitHub's changed file limit.");
    const start = evidence.items.len;
    var unavailable: usize = 0;
    var omitted: usize = 0;
    for (files) |file| {
        const original = file.previous_filename orelse file.filename;
        if (!core.validPath(file.filename) or !core.validPath(original) or sensitive(file.filename) or sensitive(original)) {
            unavailable += 1;
            continue;
        }
        const heading = "diff --git a/{s} b/{s}\n";
        if (evidence.items.len - start + file.filename.len + original.len + heading.len - 6 > registry_diff_limit) {
            omitted += 1;
            continue;
        }
        const writer = evidence.writer(a);
        try writer.print(heading, .{ original, file.filename });
        if (!registryPatchComplete(file)) {
            unavailable += 1;
            continue;
        }
        if (file.patch) |patch| {
            if (evidence.items.len - start + patch.len + 1 > registry_diff_limit) {
                omitted += 1;
                continue;
            }
            try writer.print("{s}\n", .{patch});
        }
    }
    if (unavailable != 0) try coverage.append(a, try io.fmt(a, "Registry changes unavailable, partial, or excluded for {d} path{s}.", .{ unavailable, if (unavailable == 1) "" else "s" }));
    if (omitted != 0) try coverage.append(a, try io.fmt(a, "Registry changes exceeded the review byte limit for {d} path{s}.", .{ omitted, if (omitted == 1) "" else "s" }));
}

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

fn anchoredRange(blob: []const u8, needle: []const u8) !ExcerptRange {
    var lines = std.mem.splitScalar(u8, blob, '\n');
    var line: u32 = 1;
    var anchor_index: ?u32 = null;
    while (lines.next()) |text| : (line += 1) {
        if (std.mem.indexOf(u8, text, needle) == null) continue;
        if (anchor_index != null) return error.ExcerptAnchorAmbiguous;
        anchor_index = line;
    }
    const match = anchor_index orelse return error.ExcerptAnchorMissing;
    return excerptRange(@max(1, match -| 6), match +| 80);
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
        error.ExcerptAnchorMissing => "anchor missing at the pinned head",
        error.ExcerptAnchorAmbiguous => "anchor matches multiple lines",
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
    const overhead = name.len + 40;
    if (blob.len > max_blob_size or blob.len + overhead > remaining.* or !std.unicode.utf8ValidateSlice(blob) or
        std.mem.indexOfScalar(u8, blob, 0) != null) return;
    try evidence.writer(a).print("\n\nHead file {s}:\n{s}", .{ name, blob });
    remaining.* -= blob.len + overhead;
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
            const hunk = hunkRanges(text) orelse return false;
            left_remaining = hunk.left.count;
            right = hunk.right.start;
            right_end = std.math.add(u32, right, hunk.right.count) catch return false;
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

const LineRange = struct { start: u32, count: u32 };

fn hunkRanges(text: []const u8) ?struct { left: LineRange, right: LineRange } {
    if (!std.mem.startsWith(u8, text, "@@ -")) return null;
    const plus = std.mem.indexOf(u8, text[4..], " +") orelse return null;
    const right = text[4 + plus + 2 ..];
    const suffix = std.mem.indexOf(u8, right, " @@") orelse return null;
    return .{ .left = range(text[4..][0..plus]) orelse return null, .right = range(right[0..suffix]) orelse return null };
}

fn range(text: []const u8) ?LineRange {
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

test "registry evidence retains exact text patches and withholds approval on omitted content" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const example = "@@ -1 +1 @@\n-old\n+new";
    const input = [_]github.File{
        .{ .filename = "chains/apechain/metadata.yaml", .patch = example, .additions = 1, .deletions = 1 },
        .{ .filename = "chains/renamed.yaml", .status = "renamed", .previous_filename = "chains/old.yaml", .additions = 0, .deletions = 0 },
        .{ .filename = "chains/partial.yaml", .patch = "@@ -1,3 +1,3 @@\n-old\n+new\n context", .additions = 1, .deletions = 1 },
        .{ .filename = "chains/credentials.yaml", .status = "renamed", .previous_filename = ".env.local", .patch = "hidden" },
        .{ .filename = "chains/missing.yaml", .additions = 1, .deletions = 1 },
    };
    var evidence: std.ArrayList(u8) = .empty;
    var coverage: std.ArrayList([]const u8) = .empty;
    try appendRegistryFiles(a, &evidence, &coverage, input[0..1]);
    try t.expectEqualStrings("diff --git a/chains/apechain/metadata.yaml b/chains/apechain/metadata.yaml\n" ++ example ++ "\n", evidence.items);
    try t.expectEqual(@as(usize, 0), coverage.items.len);
    evidence.clearRetainingCapacity();
    try appendRegistryFiles(a, &evidence, &coverage, input[1..]);
    try t.expectEqualStrings("diff --git a/chains/old.yaml b/chains/renamed.yaml\n" ++
        "diff --git a/chains/partial.yaml b/chains/partial.yaml\n" ++
        "diff --git a/chains/missing.yaml b/chains/missing.yaml\n", evidence.items);
    try t.expectEqualStrings("Registry changes unavailable, partial, or excluded for 4 paths.", coverage.items[0]);
    const oversized = [_]github.File{.{
        .filename = "big.yaml",
        .patch = "@@ -0,0 +1 @@\n+" ++ "x" ** registry_diff_limit,
        .additions = 1,
        .deletions = 0,
    }};
    try appendRegistryFiles(a, &evidence, &coverage, &oversized);
    try t.expect(evidence.items.len < registry_diff_limit);
    try t.expectEqualStrings("Registry changes exceeded the review byte limit for 1 path.", coverage.items[1]);
}

test "agent build inventory retains every available path and detects gaps" {
    const t = std.testing;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(t.allocator);
    var remaining: usize = 1024;
    const records = "2\t4\trust/main/config/mainnet.json\x00-\t-\trust/main/fixture.bin\x00";
    try t.expect(try appendAgentInventory(t.allocator, &output, records, &remaining));
    try t.expectEqualStrings("2\t4\trust/main/config/mainnet.json\n-\t-\trust/main/fixture.bin\n", output.items);
    try t.expect(!try appendAgentInventory(t.allocator, &output, "1\t2\trust/main/.env.secret\x00", &remaining));
    try t.expect(std.mem.indexOf(u8, output.items, ".env.secret") == null);
    remaining = 1;
    try t.expect(!try appendAgentInventory(t.allocator, &output, records, &remaining));
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

test "pinned source reads exact trees and prioritizes active review anchors in a large diff" {
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
    const old_pin = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const new_pin = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var commits: [2][]const u8 = undefined;
    for (&commits, [_][]const u8{ "old behavior\n", "new behavior\n" }, [_][]const u8{ old_pin ++ "\n", new_pin ++ "\n" }) |*commit, content, pin| {
        const blob = io.trim(u8, try git.git(path, &.{ "hash-object", "-w", "--stdin" }, content), "\n");
        const pin_blob = io.trim(u8, try git.git(path, &.{ "hash-object", "-w", "--stdin" }, pin), "\n");
        const input = try io.fmt(a, "100644 blob {s}\tcaller.zig\n100644 blob {s}\tchange.zig\n100644 blob {s}\t.env.local\n120000 blob {s}\tlinked.zig\n100644 blob {s}\t.registryrc\n", .{ unchanged, blob, secret, secret, pin_blob });
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
    const pins = (try git.registryPins(path, commits[0], commits[1])).?;
    try t.expectEqualStrings(old_pin, pins.before);
    try t.expectEqualStrings(new_pin, pins.after);
    try t.expect((try git.registryPins(path, commits[1], commits[1])) == null);

    const active_path = "z-active[?]*.zig";
    const risky_path = "zz-owner.yaml";
    const docs = "#doc.md";
    const files = [_]github.File{
        .{ .filename = docs },
        .{ .filename = risky_path, .patch = "@@ -0,0 +1 @@\n+owner: new\n" },
        .{ .filename = active_path, .patch = "@@ -0,0 +1,3 @@\n+start\n+active anchor\n+end\n" },
    };
    const current = core.Thread{ .id = "current", .isResolved = false, .isOutdated = false, .path = active_path, .line = 2, .diffSide = .RIGHT, .replies = &.{} };
    var duplicate = current;
    duplicate.id = "duplicate";
    var stale = current;
    stale.isOutdated = true;
    stale.path = ".env.local";
    var left = current;
    left.path = "linked.zig";
    left.diffSide = .LEFT;
    var missing = current;
    missing.line = 9;
    const threads: []const core.Thread = &.{ current, duplicate, stale, left, missing };

    const docs_blob = io.trim(u8, try git.git(path, &.{ "hash-object", "-w", "--stdin" }, "large docs\n" ** 5000), "\n");
    const risk_blob = io.trim(u8, try git.git(path, &.{ "hash-object", "-w", "--stdin" }, "owner: new\n"), "\n");
    const active_blob = io.trim(u8, try git.git(path, &.{ "hash-object", "-w", "--stdin" }, "start\nactive anchor\nend\n"), "\n");
    const new_tree = try io.fmt(a, "100644 blob {s}\t{s}\n100644 blob {s}\t{s}\n100644 blob {s}\t{s}\n", .{
        docs_blob, docs, risk_blob, risky_path, active_blob, active_path,
    });
    const tree_oid = io.trim(u8, try git.git(path, &.{"mktree"}, new_tree), "\n");
    const new_head = io.trim(u8, try git.git(path, &.{ "commit-tree", tree_oid, "-p", commits[0], "-m", "review" }, ""), "\n");
    const full = try git.diff(path, commits[0], new_head);
    try t.expect(std.mem.indexOf(u8, full[0..diff_limit], "+active anchor") == null);
    const ordered = try prioritizeFiles(a, &files, threads);
    try t.expectEqualStrings(active_path, ordered[0].file.filename);
    try t.expectEqualStrings(risky_path, ordered[1].file.filename);
    try t.expectEqualStrings(docs, ordered[2].file.filename);
    const diff = try git.orderedDiff(path, commits[0], new_head, ordered);
    const active_offset = std.mem.indexOf(u8, diff[0..diff_limit], "+active anchor") orelse return error.TestExpectedEqual;
    const risk_offset = std.mem.indexOf(u8, diff[0..diff_limit], "+owner: new") orelse return error.TestExpectedEqual;
    const docs_offset = std.mem.indexOf(u8, diff[0..diff_limit], "+large docs") orelse return error.TestExpectedEqual;
    try t.expect(active_offset < risk_offset and risk_offset < docs_offset);
    var evidence: std.ArrayList(u8) = .empty;
    var remaining: usize = context_limit;
    try t.expectEqual(@as(usize, 1), try git.appendThreadExcerpts(path, new_head, &files, threads, false, &evidence, &remaining));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, evidence.items, "active anchor"));
    try t.expect(std.mem.indexOf(u8, evidence.items, "DO NOT PRESENT") == null);
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

test "an exact source anchor fetches a declaration beyond the first excerpt" {
    const t = std.testing;
    const source = "// prefix\n" ** 180 ++ "function parseId(value: unknown) {\n  return value;\n}\n" ++ "// suffix\n" ** 100;
    const span = try anchoredRange(source, "function parseId(");
    try t.expectEqual(@as(u32, 175), span.start);
    const excerpt = try excerptLines(source, span);
    try t.expect(std.mem.indexOf(u8, excerpt.text, "return value;") != null);
    try t.expectError(error.ExcerptAnchorAmbiguous, anchoredRange(source, "// prefix"));
    try t.expectError(error.ExcerptAnchorMissing, anchoredRange(source, "function absent("));
}
