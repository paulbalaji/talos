const std = @import("std");

pub const Mode = enum { fixed, shadow, adaptive };
pub const Depth = enum { light, regular, focused, multi };
pub const Lens = enum { performance, reliability, security };

pub const Decision = struct {
    depth: Depth = .regular,
    performance: bool = false,
    reliability: bool = false,
    security: bool = false,

    pub fn has(self: Decision, lens: Lens) bool {
        return switch (lens) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    pub fn merge(self: Decision, other: Decision) Decision {
        return .{
            .depth = @enumFromInt(@max(@intFromEnum(self.depth), @intFromEnum(other.depth))),
            .performance = self.performance or other.performance,
            .reliability = self.reliability or other.reliability,
            .security = self.security or other.security,
        };
    }

    pub fn valid(self: Decision) bool {
        const has_lens = self.performance or self.reliability or self.security;
        return switch (self.depth) {
            .light, .regular => !has_lens,
            .focused, .multi => has_lens,
        };
    }
};

pub const Screen = struct {
    floor: Decision,
    ask_model: bool,
};

pub const all_lenses: Decision = .{ .depth = .multi, .security = true, .reliability = true, .performance = true };

fn hyperlaneMessageVerification(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "rust/main/agents/relayer/src/msg/metadata/ccip_read/") or
        std.mem.eql(u8, path, "rust/main/hyperlane-core/src/offchain_lookup.rs") or
        std.mem.eql(u8, path, "typescript/ccip-server/src/utils/ccsAuth.ts") or
        std.mem.eql(u8, path, "typescript/ccip-server/src/services/CallCommitmentsService.ts") or
        std.mem.eql(u8, path, "typescript/relayer/src/metadata/ccipread.ts");
}

pub fn messageVerificationChanged(repo: []const u8, files: anytype) bool {
    if (!std.ascii.eqlIgnoreCase(repo, "hyperlane-xyz/hyperlane-monorepo")) return false;
    for (files) |file| {
        if (hyperlaneMessageVerification(file.filename)) return true;
        if (file.previous_filename) |old| if (hyperlaneMessageVerification(old)) return true;
    }
    return false;
}

test "production message verification changes escalate but docs and tests do not" {
    const File = struct { filename: []const u8, previous_filename: ?[]const u8 = null };
    const repo = "hyperlane-xyz/hyperlane-monorepo";
    const root = "rust/main/agents/relayer/src/msg/metadata/ccip_read/mod.rs";
    try std.testing.expect(messageVerificationChanged(repo, &[_]File{.{ .filename = root }}));
    try std.testing.expect(messageVerificationChanged(repo, &[_]File{.{ .filename = "new.ts", .previous_filename = "typescript/ccip-server/src/utils/ccsAuth.ts" }}));
    try std.testing.expect(!messageVerificationChanged("example/repo", &[_]File{.{ .filename = root }}));
    try std.testing.expect(!messageVerificationChanged(repo, &[_]File{
        .{ .filename = "typescript/ccip-server/CCS_AUTH.md" },
        .{ .filename = "typescript/ccip-server/tests/services/CcsAuth.test.ts" },
        .{ .filename = "typescript/relayer/src/metadata/ccipread.test.ts" },
    }));
}

const authority_risk: Decision = .{ .depth = .multi, .security = true, .reliability = true };

fn contains(path: []const u8, part: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(path, part) != null;
}

fn pathRisk(path: []const u8) Decision {
    if (std.ascii.endsWithIgnoreCase(path, ".sol") or contains(path, "/contracts/") or std.mem.startsWith(u8, path, "contracts/") or
        contains(path, "auth") or contains(path, "permission") or contains(path, "iam.") or
        contains(path, "access-control") or contains(path, "security") or contains(path, "signing") or contains(path, "signer") or
        contains(path, "blocklist") or contains(path, "denylist") or contains(path, "sanction") or
        std.ascii.startsWithIgnoreCase(path, ".github/workflows/"))
        return authority_risk;
    if (contains(path, "migrat") or contains(path, "schema") or contains(path, "deploy"))
        return .{ .depth = .multi, .reliability = true };
    if (contains(path, "benchmark") or contains(path, "perf") or contains(path, "cache"))
        return .{ .depth = .focused, .performance = true };
    if (contains(path, "queue") or contains(path, "retry") or contains(path, "scheduler"))
        return .{ .depth = .focused, .reliability = true };
    return .{};
}

fn configFile(path: []const u8) bool {
    for ([_][]const u8{ ".yaml", ".yml", ".json", ".toml" }) |extension| {
        if (std.ascii.endsWithIgnoreCase(path, extension)) return true;
    }
    return false;
}

fn authorityKey(line: []const u8) bool {
    const end = std.mem.indexOfAny(u8, line, ":=") orelse return false;
    const raw = std.mem.trim(u8, line[0..end], " \t\r\"'{}[-");
    if (raw.len == 0 or raw.len > 48) return false;
    var key: [48]u8 = undefined;
    var len: usize = 0;
    for (raw) |byte| {
        if (byte == '-' or byte == '_') continue;
        if (!std.ascii.isAlphanumeric(byte)) return false;
        key[len] = std.ascii.toLower(byte);
        len += 1;
    }
    for ([_][]const u8{
        "owner",            "owners",   "owneroverride", "proxyadmin",  "proxyadminowner", "admin",                    "admins",
        "upgradeauthority", "governor", "governance",    "signer",      "signers",         "signeraddress",            "signingkey",
        "signingthreshold", "multisig", "roles",         "permissions", "accesscontrol",   "interchainsecuritymodule", "ism",
        "validators",
    }) |sensitive| {
        if (std.mem.eql(u8, key[0..len], sensitive)) return true;
    }
    return false;
}

fn opensAuthorityBlock(line: []const u8) bool {
    if (!authorityKey(line)) return false;
    const separator = std.mem.indexOfAny(u8, line, ":=").?;
    const value = std.mem.trim(u8, line[separator + 1 ..], " \t\r");
    return value.len == 0 or value[0] == '#' or std.mem.eql(u8, value, "{") or std.mem.eql(u8, value, "[");
}

fn policySymbol(line: []const u8) bool {
    for ([_][]const u8{
        "blocked_countries",   "blocked_regions",      "allowed_countries", "allowed_regions",
        "blockedCountries",    "blockedRegions",       "allowedCountries",  "allowedRegions",
        "sanctionedCountries", "sanctioned_countries",
    }) |symbol| {
        if (contains(line, symbol)) return true;
    }
    return false;
}

const Image = struct { prefix: []const u8, suffix: []const u8, patch: u32 };

fn image(line: []const u8) ?Image {
    const text = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, text, "image:")) return null;
    var value = std.mem.trim(u8, text["image:".len..], " \t");
    if (value.len < 2) return null;
    if ((value[0] == '"' or value[0] == '\'') and value[0] == value[value.len - 1]) value = value[1 .. value.len - 1];
    if (std.mem.indexOfAny(u8, value, " \t@#\x00") != null) return null;
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return null;
    if (colon == 0) return null;
    const name = value[0..colon];
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '_' or c == '-' or c == '.' or c == ':')) return null;
    const tag = value[colon + 1 ..];
    var parts = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag, '.');
    var version: [3]u32 = undefined;
    for (&version) |*part| {
        const digits = parts.next() orelse return null;
        if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return null;
        for (digits) |c| if (!std.ascii.isDigit(c)) return null;
        part.* = std.fmt.parseUnsigned(u32, digits, 10) catch return null;
    }
    if (parts.next() != null) return null;
    const patch_start = std.mem.lastIndexOfScalar(u8, tag, '.').? + 1;
    const offset = @intFromPtr(tag.ptr) - @intFromPtr(line.ptr);
    return .{ .prefix = line[0 .. offset + patch_start], .suffix = line[offset + tag.len ..], .patch = version[2] };
}

fn patchBump(patch: []const u8, additions: ?u32, deletions: ?u32) bool {
    var lines = std.mem.splitScalar(u8, patch, '\n');
    var old: ?Image = null;
    var pairs: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        switch (line[0]) {
            '-' => {
                if (old != null) return false;
                old = image(line[1..]) orelse return false;
            },
            '+' => {
                const before = old orelse return false;
                const after = image(line[1..]) orelse return false;
                if (!std.mem.eql(u8, before.prefix, after.prefix) or !std.mem.eql(u8, before.suffix, after.suffix) or
                    after.patch <= before.patch) return false;
                old = null;
                pairs += 1;
            },
            else => if (old != null) return false,
        }
    }
    return pairs != 0 and old == null and pairs == (additions orelse 0) and pairs == (deletions orelse 0);
}

pub fn inspect(files: anytype, limited: bool) Screen {
    var floor: Decision = .{};
    var mechanical = !limited and files.len > 0 and files.len <= 4;
    var edits: usize = 0;
    for (files) |file| {
        const path = file.filename;
        floor = floor.merge(pathRisk(path));
        if (file.previous_filename) |old| floor = floor.merge(pathRisk(old));
        const patch = file.patch orelse {
            mechanical = false;
            continue;
        };
        const config = configFile(path);
        var lines = std.mem.splitScalar(u8, patch, '\n');
        var policy_hunk = false;
        var authority_indent: ?usize = null;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "@@")) {
                policy_hunk = policySymbol(line);
                authority_indent = null;
                continue;
            }
            const changed = line[0] == '+' or line[0] == '-';
            if (!changed and line[0] != ' ') continue;
            const text = std.mem.trimStart(u8, line[1..], " \t");
            const indent = line.len - 1 - text.len;
            if (config and text.len > 0 and text[0] != '#') {
                if (authority_indent) |parent| {
                    // YAML allows list items at their parent's indentation.
                    if (indent < parent or (indent == parent and !std.mem.startsWith(u8, text, "- ")))
                        authority_indent = null;
                }
                if (opensAuthorityBlock(text)) authority_indent = indent;
            }
            if (policySymbol(text)) policy_hunk = true;
            if (changed) {
                edits += 1;
                if (policy_hunk or authority_indent != null or (config and authorityKey(text)))
                    floor = floor.merge(authority_risk);
            }
        }
        if (!std.mem.eql(u8, file.status, "modified") or file.previous_filename != null or
            !(std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) or
            !patchBump(patch, file.additions, file.deletions)) mechanical = false;
    }
    if (files.len >= 12 or edits >= 400) floor = floor.merge(.{ .depth = .focused, .reliability = true });
    if (floor.depth == .regular and mechanical and edits <= 8) {
        floor.depth = .light;
        return .{ .floor = floor, .ask_model = true };
    }
    return .{ .floor = floor, .ask_model = !limited and floor.depth == .regular };
}

test "the light floor only covers same-image semver patch bumps in complete modified YAML" {
    const File = struct {
        filename: []const u8 = "config/images.yaml",
        status: []const u8 = "modified",
        previous_filename: ?[]const u8 = null,
        additions: ?u32 = 1,
        deletions: ?u32 = 1,
        patch: ?[]const u8,
    };
    const cases = [_]struct { file: File, expected: Depth }{
        .{ .file = .{ .patch = "@@ -1 +1 @@\n-  image: image/path:1.2.3\n+  image: image/path:1.2.4" }, .expected = .light },
        .{ .file = .{ .patch = "-image: image/path:1.2.3\n+image: another/path:1.2.4" }, .expected = .regular },
        .{ .file = .{ .patch = "-image: image/path:1.2.3\n+image: image/path:2.0.0" }, .expected = .regular },
        .{ .file = .{ .patch = "-image: image/path:1.2.3\n+image: image/path:1.2.4\n+privileged: true" }, .expected = .regular },
        .{ .file = .{ .patch = "-  image: image/path:1.2.3\n+ image: image/path:1.2.4" }, .expected = .regular },
        .{ .file = .{ .patch = "-image: image/path:1.2.3\n+image: image/path:1.2.4", .additions = 2 }, .expected = .regular },
        .{ .file = .{ .filename = ".github/workflows/deploy.yaml", .patch = null }, .expected = .multi },
        .{ .file = .{ .filename = "src/cache.zig", .patch = null }, .expected = .focused },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, inspect(&[_]File{case.file}, false).floor.depth);
    try std.testing.expectEqual(Depth.regular, inspect(&[_]File{cases[0].file}, true).floor.depth);
}

test "small ownership, signing, permission and policy edits get two reviewers" {
    const File = @import("github.zig").File;
    const cases = [_]File{
        .{ .filename = "config/route.yaml", .patch = "@@ -1 +1 @@\n-  owner: old\n+  owner: new" },
        .{ .filename = "config/route.json", .patch = "@@ -1 +1 @@\n-  \"proxy_admin_owner\": \"old\"\n+  \"proxy_admin_owner\": \"new\"" },
        .{ .filename = "config/agent.toml", .patch = "@@ -1 +1 @@\n-signing-key = \"old\"\n+signing-key = \"new\"" },
        .{ .filename = "config/service.yaml", .patch = "@@ -1 +1 @@\n-permissions: read\n+permissions: write" },
        .{ .filename = "src/proxy.ts", .patch = "@@ -30,2 +30,1 @@ const BLOCKED_COUNTRIES = [\n-  'SY',\n ];" },
        .{ .filename = "src/proxy.ts", .patch = "@@ -1,2 +1,3 @@\n const blockedRegions = [\n+  'test',\n ];" },
        .{ .filename = "config/route.yaml", .patch = "@@ -1,2 +1,2 @@\n owners:\n-  - old\n+  - new" },
        .{ .filename = "config/route.yaml", .patch = "@@ -1,2 +1,2 @@\n owners:\n-- old\n+- new" },
        .{ .filename = "src/signing/client.rs", .patch = null },
    };
    for (cases) |file| {
        const result = inspect(&[_]File{file}, false);
        try std.testing.expectEqualDeep(authority_risk, result.floor);
        try std.testing.expect(!result.ask_model);
    }
    const image_only = inspect(&[_]File{.{
        .filename = "config/agent.yaml",
        .status = "modified",
        .additions = 1,
        .deletions = 1,
        .patch = "@@ -1,2 +1,2 @@\n owner: unchanged\n-image: example/agent:1.2.3\n+image: example/agent:1.2.4",
    }}, false);
    try std.testing.expectEqual(Depth.light, image_only.floor.depth);
}
