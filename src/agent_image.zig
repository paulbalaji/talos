const std = @import("std");
const io = @import("io.zig");
const eq = io.eq;

pub const pin_path = "typescript/infra/config/docker.ts";
pub const registry_image = "hyperlane-xyz/hyperlane-agent";
const registry = "https://ghcr.io";
pub const max_tags = 6;
pub const environments = [_][]const u8{ "mainnet3", "testnet4" };
pub const exports = [_][]const u8{ "mainnetDockerTags", "testnetDockerTags" };
pub const roles = [_][]const u8{ "relayer", "relayerRC", "relayerFastPath" };
pub const Pins = [environments.len * roles.len][]const u8;

pub fn pins(blob: []const u8) ?Pins {
    var result: Pins = @splat("");
    var active: ?usize = null;
    var lines = std.mem.tokenizeScalar(u8, blob, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "export const ")) {
            active = null;
            for (exports, 0..) |name, i| {
                if (std.mem.startsWith(u8, line["export const ".len..], name) and
                    std.mem.startsWith(u8, line["export const ".len + name.len ..], ":")) active = i;
            }
            continue;
        }
        if (eq(u8, line, "};")) active = null;
        const base = (active orelse continue) * roles.len;
        const field = std.mem.trim(u8, line, " \t\r");
        const end = std.mem.indexOfScalar(u8, field, ':') orelse continue;
        for (roles, 0..) |role, i| {
            if (!eq(u8, field[0..end], role)) continue;
            const value = std.mem.trim(u8, field[end + 1 ..], " \t");
            if (result[base + i].len != 0 or value.len < 4 or value[0] != '\'' or !std.mem.endsWith(u8, value, "',")) return null;
            result[base + i] = value[1 .. value.len - 2];
        }
    }
    for (result) |tag| if (tag.len == 0) return null;
    return result;
}

pub fn validTag(tag: []const u8) bool {
    if (tag.len != 23 or tag[7] != '-' or tag[16] != '-') return false;
    for (tag[0..7]) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    for (tag[8..16]) |c| if (!std.ascii.isDigit(c)) return false;
    for (tag[17..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

pub fn onlyPinFile(raw: []const u8) bool {
    if (!std.mem.endsWith(u8, raw, "\x00")) return false;
    var fields = std.mem.splitScalar(u8, raw, 0);
    const header = fields.next() orelse return false;
    return std.mem.startsWith(u8, header, ":100644 100644 ") and std.mem.endsWith(u8, header, " M") and
        eq(u8, fields.next() orelse return false, pin_path) and eq(u8, fields.rest(), "");
}

pub fn promotionTag(before: []const u8, after: []const u8, old_pins: Pins, new_pins: Pins) ?[]const u8 {
    var old_end: usize = 0;
    var new_end: usize = 0;
    var target: ?[]const u8 = null;
    for (old_pins, new_pins) |old, new| {
        // The parsed tags are slices into the original files. All intervening
        // bytes must match, including comments, selectors, and other roles.
        const old_start = @intFromPtr(old.ptr) - @intFromPtr(before.ptr);
        const new_start = @intFromPtr(new.ptr) - @intFromPtr(after.ptr);
        if (old_start < old_end or new_start < new_end or !eq(u8, before[old_end..old_start], after[new_end..new_start])) return null;
        old_end = old_start + old.len;
        new_end = new_start + new.len;
        if (eq(u8, old, new)) continue;
        if (!validTag(old) or !validTag(new)) return null;
        if (std.mem.order(u8, new[8..], old[8..]) != .gt) return null;
        if (target) |tag| {
            if (!eq(u8, tag, new)) return null;
        } else target = new;
    }
    return if (eq(u8, before[old_end..], after[new_end..])) target else null;
}

pub fn remainingSeconds(timer: *std.time.Timer, limit: u32) !u32 {
    const elapsed = timer.read() / std.time.ns_per_s;
    if (elapsed >= limit) return error.ImageEvidenceTimeout;
    return @intCast(limit - elapsed);
}

pub const Client = struct {
    cmd: io.Command,
    curl: []const u8,
    timer: *std.time.Timer,
    limit: u32,

    fn get(self: Client, url: []const u8, headers: []const u8) ![]const u8 {
        const seconds = @min(5, try remainingSeconds(self.timer, self.limit));
        const timeout = try io.fmt(self.cmd.a, "{d}", .{seconds});
        return self.cmd.run(&.{
            self.curl,           "--disable", "--silent",   "--fail", "--globoff",      "--proto", "=https",
            "--connect-timeout", "3",         "--max-time", timeout,  "--max-filesize", "131072",  "--header",
            "@-",                "--url",     url,
        }, headers, seconds + 1);
    }

    pub fn token(self: Client) ![]const u8 {
        const raw = try self.get(registry ++ "/token?scope=repository:" ++ registry_image ++ ":pull", "");
        const response = try io.parse(self.cmd.a, struct { token: []const u8 }, raw);
        if (response.token.len == 0 or response.token.len > 4096 or std.mem.indexOfAny(u8, response.token, " \t\r\n\x00") != null)
            return error.InvalidImageToken;
        return response.token;
    }

    pub fn digest(self: Client, bearer: []const u8, tag: []const u8) ![]const u8 {
        if (!validTag(tag)) return error.InvalidImageTag;
        const a = self.cmd.a;
        const url = try io.fmt(a, registry ++ "/v2/" ++ registry_image ++ "/manifests/{s}", .{tag});
        const headers = try io.fmt(a, "Authorization: Bearer {s}\n" ++
            "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json\n", .{bearer});
        const raw = try self.get(url, headers);
        return manifestDigest(a, raw);
    }
};

fn manifestDigest(a: io.A, raw: []const u8) ![]const u8 {
    const manifest = try io.parse(a, struct { schemaVersion: u32, mediaType: []const u8 }, raw);
    if (manifest.schemaVersion != 2) return error.InvalidImageManifest;
    for ([_][]const u8{
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    }) |media| {
        if (!eq(u8, manifest.mediaType, media)) continue;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        return io.fmt(a, "sha256:{x}", .{&hash});
    }
    return error.InvalidImageManifest;
}

/// Only trust the BuildKit push record for the exact tag and manifest bytes.
pub fn logMatches(log: []const u8, tag_digest: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        var columns = std.mem.splitScalar(u8, line, '\t');
        if (!eq(u8, columns.next() orelse continue, "build-and-push")) continue;
        const step = columns.next() orelse continue;
        if (!eq(u8, step, "Build and push") and !eq(u8, step, "UNKNOWN STEP")) continue;
        const message = columns.rest();
        const time = std.mem.indexOfScalar(u8, message, ' ') orelse continue;
        var parts = std.mem.tokenizeScalar(u8, message[time + 1 ..], ' ');
        const label = parts.next() orelse continue;
        if (label.len < 2 or label[0] != '#') continue;
        for (label[1..]) |c| {
            if (!std.ascii.isDigit(c)) break;
        } else {
            if (!eq(u8, parts.next() orelse continue, "pushing") or
                !eq(u8, parts.next() orelse continue, "manifest") or
                !eq(u8, parts.next() orelse continue, "for")) continue;
            if (eq(u8, parts.next() orelse continue, tag_digest) and parts.next() == null) return true;
        }
    }
    return false;
}

test "relayer pins read only the recognized environment exports" {
    const blob =
        \\interface AgentDockerTags { relayer: string }
        \\export const mainnetDockerTags: MainnetDockerTags = {
        \\  relayer: 'cdeacee-20261120-123426',
        \\  relayerRC: 'cdeacee-20261120-123426',
        \\  relayerFastPath: 'cdeacee-20261120-123426',
        \\};
        \\export const testnetDockerTags: BaseDockerTags = {
        \\  validator: 'e492f45-20261110-131529',
        \\  relayer: '30b039c-20261124-095058',
        \\  relayerRC: 'e492f45-20261110-131529',
        \\  relayerFastPath: '30b039c-20261124-095058',
        \\};
    ;
    const found = pins(blob).?;
    try std.testing.expectEqualStrings("cdeacee-20261120-123426", found[0]);
    try std.testing.expectEqualStrings("e492f45-20261110-131529", found[4]);
    for (found) |tag| try std.testing.expect(validTag(tag));
    try std.testing.expect(!validTag("30b039z-20261124-095058"));
    try std.testing.expect(!validTag("30b039c-20261124&095058"));
    try std.testing.expect(pins(blob[0 .. blob.len - 50]) == null);
}

test "only pure forward relayer pins to a single build qualify" {
    const t = std.testing;
    const before =
        \\export const mainnetDockerTags: MainnetDockerTags = {
        \\  relayer: 'abcdef0-20261124-100000',
        \\  relayerRC: 'abcdef0-20261124-100000',
        \\  relayerFastPath: 'abcdef0-20261124-100000',
        \\  validator: 'abcdef0-20261124-100000',
        \\};
        \\export const testnetDockerTags: BaseDockerTags = {
        \\  relayer: 'abcdef0-20261124-100000',
        \\  relayerRC: 'abcdef0-20261124-100000',
        \\  relayerFastPath: 'abcdef0-20261124-100000',
        \\};
    ;
    const after = try std.mem.replaceOwned(u8, t.allocator, before, "relayer: 'abcdef0-20261124-100000'", "relayer: '1234567-20261124-110000'");
    defer t.allocator.free(after);
    try t.expectEqualStrings("1234567-20261124-110000", promotionTag(before, after, pins(before).?, pins(after).?).?);
    try t.expect(promotionTag(after, before, pins(after).?, pins(before).?) == null);
    const mixed = try std.mem.replaceOwned(u8, t.allocator, after, "relayerRC: 'abcdef0-20261124-100000'", "relayerRC: '1234567-20261124-120000'");
    defer t.allocator.free(mixed);
    try t.expect(promotionTag(before, mixed, pins(before).?, pins(mixed).?) == null);
    const other_role = try std.mem.replaceOwned(u8, t.allocator, after, "validator: 'abcdef0-20261124-100000'", "validator: '1234567-20261124-110000'");
    defer t.allocator.free(other_role);
    try t.expect(promotionTag(before, other_role, pins(before).?, pins(other_role).?) == null);
    const raw = ":100644 100644 1234abcd abcd1234 M\x00" ++ pin_path ++ "\x00";
    try t.expect(onlyPinFile(raw));
    try t.expect(!onlyPinFile(raw ++ ":100644 100644 1234abcd abcd1234 M\x00.gitignore\x00"));
    try t.expect(!onlyPinFile(":100644 100755 1234abcd abcd1234 M\x00" ++ pin_path ++ "\x00"));
}

test "verified build evidence requires the exact tagged digest in the build step" {
    const t = std.testing;
    const exact = "ghcr.io/hyperlane-xyz/hyperlane-agent:35afedd-20261124-185322@sha256:04ed5b285c9113541b98f0e2f1cfda23103e9afa9938748e33714b941fd4fe11";
    const message = "2026-11-24T18:56:59.8991597Z #35 pushing manifest for " ++ exact;
    try t.expect(logMatches("build-and-push\tUNKNOWN STEP\t" ++ message ++ "\n", exact));
    try t.expect(logMatches("build-and-push\tBuild and push\t" ++ message ++ "\n", exact));
    try t.expect(!logMatches("build-and-push\tGenerate image tags output\t" ++ message ++ "\n", exact));
    try t.expect(!logMatches("build-and-push\tBuild and push\t" ++ message ++ "malicious\n", exact));
    try t.expect(!logMatches("test\tUNKNOWN STEP\t" ++ message ++ "\n", exact));
}

test "manifest evidence hashes the registry bytes rather than trusting a tag or header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\"}";
    const first = try manifestDigest(arena.allocator(), body);
    const changed = try manifestDigest(arena.allocator(), body ++ "\n");
    try std.testing.expectEqual(@as(usize, 71), first.len);
    try std.testing.expect(!eq(u8, first, changed));
    try std.testing.expectError(error.InvalidImageManifest, manifestDigest(arena.allocator(), "{\"schemaVersion\":1,\"mediaType\":\"text/html\"}"));
}
