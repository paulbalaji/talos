const std = @import("std");
const io = @import("io.zig");

pub const max_reads = 6;
pub const registry_repo = "hyperlane-xyz/hyperlane-registry";
const rpc_budget_seconds = 30;

pub const Operation = enum {
    owner,
    safe_owners,
    safe_threshold,
    paused,
    has_code,
    max_capacity,
    warp_rate_limit,

    fn selector(self: Operation) []const u8 {
        return switch (self) {
            .owner => "0x8da5cb5b",
            .safe_owners => "0xa0e67e2b",
            .safe_threshold => "0xe75235b8",
            .paused => "0x5c975abb",
            .max_capacity => "0x59b6a0c9",
            .has_code, .warp_rate_limit => unreachable,
        };
    }
};

pub const Request = struct {
    chain: []const u8,
    address: []const u8,
    operation: Operation,
    expected_value: ?[]const u8 = null,

    pub fn valid(self: Request) bool {
        if (self.chain.len == 0 or self.chain.len > 48) return false;
        for (self.chain) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch)) return false;
        return self.address.len == 42 and hex(self.address) != null;
    }
};

pub const Observation = struct {
    request: Request,
    block: ?u64 = null,
    value: ?[]const u8 = null,
    resolved_address: ?[]const u8 = null,
};

const Reading = struct { value: []const u8, resolved_address: ?[]const u8 = null };

const Metadata = struct {
    chain_id: u64,
    urls: [4]?[]const u8,
};

fn parseMetadata(text: []const u8) ?Metadata {
    var chain_id: ?u64 = null;
    var evm = false;
    var urls: [4]?[]const u8 = @splat(null);
    var url_count: usize = 0;
    var in_rpc_urls = false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != ' ') {
            in_rpc_urls = io.eq(u8, line, "rpcUrls:");
            if (std.mem.startsWith(u8, line, "chainId: ")) chain_id = std.fmt.parseInt(u64, line["chainId: ".len..], 10) catch return null;
            evm = evm or io.eq(u8, line, "protocol: ethereum");
            continue;
        }
        const prefix = "  - http: ";
        if (!in_rpc_urls or !std.mem.startsWith(u8, line, prefix) or url_count == urls.len) continue;
        const url = std.mem.trim(u8, line[prefix.len..], "\"'");
        const uri = std.Uri.parse(url) catch continue;
        if (!io.eq(u8, uri.scheme, "https") or uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) continue;
        urls[url_count] = url;
        url_count += 1;
    }
    if (!evm or url_count == 0) return null;
    return .{ .chain_id = chain_id orelse return null, .urls = urls };
}

pub const Pin = struct { metadata: Metadata, url: []const u8, block: []const u8, height: u64 };

pub const Client = struct {
    cmd: io.Command,
    curl: []const u8,
    timer: *std.time.Timer,

    fn rpc(self: Client, url: []const u8, method: []const u8, params: anytype) ![]const u8 {
        const remaining = rpc_budget_seconds * std.time.ns_per_s -| self.timer.read();
        const seconds = @min(5, remaining / std.time.ns_per_s);
        if (seconds == 0) return error.OnchainBudgetExhausted;
        var timeout_buffer: [1]u8 = undefined;
        const timeout = try std.fmt.bufPrint(&timeout_buffer, "{d}", .{seconds});
        const request = try io.json(self.cmd.a, .{ .jsonrpc = "2.0", .id = @as(u32, 1), .method = method, .params = params });
        const output = try self.cmd.run(&.{ self.curl, "--disable", "--silent", "--fail", "--globoff", "--proto", "=https", "--connect-timeout", "3", "--max-time", timeout, "--max-filesize", "65536", "--header", "Content-Type: application/json", "--data-binary", "@-", "--url", url }, request, @intCast(seconds + 1));
        const response = try io.parse(self.cmd.a, struct {
            id: u32,
            result: ?[]const u8 = null,
            @"error": ?struct { code: i32, message: []const u8 } = null,
        }, output);
        if (response.id != 1) return error.InvalidRpcReply;
        if (response.@"error") |failure| {
            if (failure.code == 3 or std.ascii.indexOfIgnoreCase(failure.message, "execution reverted") != null) return error.RpcCallReverted;
            return error.InvalidRpcReply;
        }
        return response.result orelse error.InvalidRpcReply;
    }

    pub fn pin(self: Client, text: []const u8) !Pin {
        const metadata = parseMetadata(text) orelse return error.UnsupportedChainMetadata;
        for (metadata.urls) |candidate| {
            const url = candidate orelse continue;
            const raw_chain = self.rpc(url, "eth_chainId", [0]u32{}) catch continue;
            if (quantity(raw_chain) != metadata.chain_id) continue;
            const block = self.rpc(url, "eth_blockNumber", [0]u32{}) catch continue;
            const height = quantity(block) orelse continue;
            return .{ .metadata = metadata, .url = url, .block = block, .height = height };
        }
        return error.RpcUnavailable;
    }

    pub fn read(self: Client, request: Request, pinned: Pin) !Reading {
        if (!request.valid()) return error.InvalidOnchainRequest;
        if (self.readAt(request, pinned.url, pinned.block)) |value| return value else |_| {}
        for (pinned.metadata.urls) |candidate| {
            const url = candidate orelse continue;
            if (io.eq(u8, url, pinned.url)) continue;
            const raw_chain = self.rpc(url, "eth_chainId", [0]u32{}) catch continue;
            if (quantity(raw_chain) != pinned.metadata.chain_id) continue;
            return self.readAt(request, url, pinned.block) catch continue;
        }
        return error.RpcUnavailable;
    }

    fn call(self: Client, url: []const u8, block: []const u8, address: []const u8, data: []const u8) ![]const u8 {
        return self.rpc(url, "eth_call", .{ .{ .to = address, .data = data }, block });
    }

    fn readAt(self: Client, request: Request, url: []const u8, block: []const u8) !Reading {
        if (request.operation == .warp_rate_limit) return self.warpRateLimit(request.address, url, block);
        const result = if (request.operation == .has_code)
            try self.rpc(url, "eth_getCode", .{ request.address, block })
        else
            try self.call(url, block, request.address, request.operation.selector());
        return .{ .value = try decode(self.cmd.a, request.operation, result) };
    }

    fn warpRateLimit(self: Client, router: []const u8, url: []const u8, block: []const u8) !Reading {
        const a = self.cmd.a;
        // Resolve the router's configured ISM and the static aggregation members
        // at the same block. A RateLimitedIsm is bound to this recipient.
        const ism = try decode(a, .owner, try self.call(url, block, router, "0xde523cf3"));
        const members = try aggregationMembers(try self.call(url, block, ism, "0x6f72df75" ++ "0" ** 62 ++ "20" ++ "0" ** 64));
        var match: ?Reading = null;
        for (0..members.len / 64) |index| {
            const module = try addressWord(a, members[index * 64 ..][0..64]);
            const raw_recipient = self.call(url, block, module, "0x66d003ac") catch |err| switch (err) {
                error.RpcCallReverted => continue,
                else => return err,
            };
            if (io.eq(u8, raw_recipient, "0x")) continue;
            const recipient = try decode(a, .owner, raw_recipient);
            if (!std.ascii.eqlIgnoreCase(recipient, router)) continue;
            if (match != null) return error.AmbiguousRateLimit;
            const capacity = try self.call(url, block, module, Operation.max_capacity.selector());
            match = .{ .value = try decode(a, .max_capacity, capacity), .resolved_address = module };
        }
        return match orelse error.MissingRateLimit;
    }
};

fn hex(raw: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, raw, "0x")) return null;
    for (raw[2..]) |ch| if (!std.ascii.isHex(ch)) return null;
    return raw[2..];
}

fn quantity(raw: []const u8) ?u64 {
    const digits = hex(raw) orelse return null;
    if (digits.len == 0 or digits.len > 16 or (digits.len > 1 and digits[0] == '0')) return null;
    return std.fmt.parseInt(u64, digits, 16) catch null;
}

fn addressWord(a: io.A, word: []const u8) ![]const u8 {
    if (word.len != 64 or !io.eq(u8, word[0..24], "0" ** 24)) return error.InvalidRpcReply;
    return io.fmt(a, "0x{s}", .{word[24..]});
}

fn aggregationMembers(raw: []const u8) ![]const u8 {
    const data = hex(raw) orelse return error.InvalidRpcReply;
    if (data.len < 192) return error.InvalidRpcReply;
    const offset = std.fmt.parseInt(u8, data[0..64], 16) catch return error.InvalidRpcReply;
    const threshold = std.fmt.parseInt(u8, data[64..128], 16) catch return error.InvalidRpcReply;
    const count = std.fmt.parseInt(usize, data[128..192], 16) catch return error.InvalidRpcReply;
    if (offset != 64 or count > 8 or threshold == 0 or threshold > count or data.len != 192 + 64 * count) return error.InvalidRpcReply;
    return data[192..];
}

fn decode(a: io.A, operation: Operation, raw: []const u8) ![]const u8 {
    const data = hex(raw) orelse return error.InvalidRpcReply;
    switch (operation) {
        .owner => return addressWord(a, data),
        .max_capacity => {
            if (data.len != 64) return error.InvalidRpcReply;
            const number = std.fmt.parseInt(u256, data, 16) catch return error.InvalidRpcReply;
            return io.fmt(a, "{d}", .{number});
        },
        .safe_threshold, .paused => {
            if (data.len != 64) return error.InvalidRpcReply;
            const number = std.fmt.parseInt(u64, data, 16) catch return error.InvalidRpcReply;
            if (operation == .paused) return switch (number) {
                0 => "false",
                1 => "true",
                else => error.InvalidRpcReply,
            };
            return io.fmt(a, "{d}", .{number});
        },
        .has_code => {
            if (data.len % 2 != 0) return error.InvalidRpcReply;
            return if (data.len == 0) "false" else "true";
        },
        .safe_owners => {
            if (data.len < 128) return error.InvalidRpcReply;
            const offset = std.fmt.parseInt(u32, data[0..64], 16) catch return error.InvalidRpcReply;
            const count = std.fmt.parseInt(u32, data[64..128], 16) catch return error.InvalidRpcReply;
            if (offset != 32 or count > 16 or data.len != 128 + 64 * count) return error.InvalidRpcReply;
            var owners: [16][]const u8 = undefined;
            for (owners[0..count], 0..) |*owner, i| owner.* = try addressWord(a, data[128 + 64 * i ..][0..64]);
            return std.mem.join(a, ", ", owners[0..count]);
        },
        .warp_rate_limit => unreachable,
    }
}

test "on-chain reads validate requests and decode standard ABI return values" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const address = "1234567890abcdef1234567890abcdef12345678";
    const request: Request = .{ .chain = "bsc", .address = "0x" ++ address, .operation = .owner };
    try t.expect(request.valid());
    try t.expect(!(Request{ .chain = "../bsc", .address = request.address, .operation = .owner }).valid());
    try t.expectEqualStrings(request.address, try decode(arena.allocator(), .owner, "0x" ++ "0" ** 24 ++ address));
    try t.expectEqualStrings("3", try decode(arena.allocator(), .safe_threshold, "0x" ++ "0" ** 63 ++ "3"));
    try t.expectEqualStrings("18446744073709551616", try decode(arena.allocator(), .max_capacity, "0x" ++ "0" ** 47 ++ "10000000000000000"));
    try t.expectEqualStrings(request.address, try decode(arena.allocator(), .safe_owners, "0x" ++ "0" ** 62 ++ "20" ++ "0" ** 63 ++ "1" ++ "0" ** 24 ++ address));
    try t.expectError(error.InvalidRpcReply, decode(arena.allocator(), .paused, "0x" ++ "0" ** 63 ++ "2"));
    const metadata = parseMetadata("chainId: 56\nprotocol: ethereum\nrpcUrls:\n  - http: http://example.com\n  - http: https://example.com\n").?;
    try t.expectEqual(@as(u64, 56), metadata.chain_id);
    try t.expectEqualStrings("https://example.com", metadata.urls[0].?);
}
