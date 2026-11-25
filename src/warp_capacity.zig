const std = @import("std");
const onchain = @import("onchain.zig");
const eql = std.mem.eql;

const Change = struct { chain: []const u8, capacity: []const u8 };
const capacity_prefix = "      - maxCapacity: ";

pub fn requests(a: std.mem.Allocator, before: []const u8, after: []const u8, route: []const u8) ![]const onchain.Request {
    var left = std.mem.splitScalar(u8, before, '\n');
    var right = std.mem.splitScalar(u8, after, '\n');
    var chain: []const u8 = "";
    var in_ism = false;
    var in_modules = false;
    var aggregate = false;
    var changed_chain = false;
    var pending: ?Change = null;
    var result: std.ArrayList(onchain.Request) = .empty;
    while (right.next()) |line| {
        const old = left.next() orelse return &.{};
        if (!eql(u8, old, line)) {
            if (!in_modules or changed_chain or chain.len == 0 or !std.mem.startsWith(u8, old, capacity_prefix) or
                !std.mem.startsWith(u8, line, capacity_prefix) or result.items.len == onchain.max_reads) return &.{};
            const capacity = decimal(line[capacity_prefix.len..]) orelse return &.{};
            _ = decimal(old[capacity_prefix.len..]) orelse return &.{};
            pending = .{ .chain = chain, .capacity = capacity };
            changed_chain = true;
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != ' ') {
            if (pending != null or (changed_chain and !aggregate) or !std.mem.endsWith(u8, line, ":")) return &.{};
            chain = line[0 .. line.len - 1];
            in_ism = false;
            in_modules = false;
            changed_chain = false;
            aggregate = false;
        } else if (std.mem.startsWith(u8, line, "  ") and !std.mem.startsWith(u8, line, "   ")) {
            if (pending != null) return &.{};
            in_ism = eql(u8, line, "  interchainSecurityModule:");
            in_modules = false;
        } else if (in_ism and std.mem.startsWith(u8, line, "    ") and !std.mem.startsWith(u8, line, "     ")) {
            if (pending != null) return &.{};
            in_modules = eql(u8, line, "    modules:");
            aggregate = aggregate or eql(u8, line, "    type: staticAggregationIsm");
        } else if (pending) |item| {
            if (!std.mem.startsWith(u8, line, "        ")) return &.{};
            if (!std.mem.startsWith(u8, line, "        type: ")) continue;
            if (!eql(u8, line, "        type: rateLimitedIsm")) return &.{};
            const request: onchain.Request = .{
                .chain = item.chain,
                .address = router(route, item.chain) orelse return &.{},
                .operation = .warp_rate_limit,
                .expected_value = item.capacity,
            };
            if (!request.valid()) return &.{};
            for (result.items) |previous| if (eql(u8, previous.chain, request.chain)) return &.{};
            try result.append(a, request);
            pending = null;
        }
    }
    if (left.next() != null or pending != null or (changed_chain and !aggregate)) return &.{};
    return result.items;
}

fn decimal(raw: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, raw, " \r\t");
    const digits = if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') text[1 .. text.len - 1] else text;
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return null;
    for (digits) |digit| if (!std.ascii.isDigit(digit)) return null;
    _ = std.fmt.parseInt(u256, digits, 10) catch return null;
    return digits;
}

fn router(route: []const u8, chain: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, route, '\n');
    var active = false;
    var address: ?[]const u8 = null;
    var found: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != ' ') {
            active = eql(u8, line, "tokens:");
            address = null;
        }
        if (!active) continue;
        const address_prefix = "  - addressOrDenom: ";
        const chain_prefix = "    chainName: ";
        if (std.mem.startsWith(u8, line, "  - ")) address = null;
        if (std.mem.startsWith(u8, line, address_prefix)) address = std.mem.trim(u8, line[address_prefix.len..], " \"'\r");
        if (std.mem.startsWith(u8, line, chain_prefix) and eql(u8, std.mem.trim(u8, line[chain_prefix.len..], " \"'\r"), chain)) {
            if (found != null) return null;
            found = address orelse return null;
        }
    }
    return found;
}

test "capacity sync finds the router in the pinned route and refuses changes outside the limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    const address = "0x1234567890abcdef1234567890abcdef12345678";
    const token_config = "tokens:\n  - addressOrDenom: \"" ++ address ++ "\"\n    chainName: base\n";
    const header = "base:\n  interchainSecurityModule:\n    modules:\n      - maxCapacity: ";
    const tail = "\n        type: rateLimitedIsm\n    threshold: 1\n    type: staticAggregationIsm\n";
    const old = header ++ "\"1700\"" ++ tail;
    const new = header ++ "\"1500\"" ++ tail;
    const observed = try requests(a, old, new, token_config);
    try t.expectEqual(@as(usize, 1), observed.len);
    try t.expectEqualStrings(address, observed[0].address);
    try t.expectEqualStrings("1500", observed[0].expected_value.?);
    try t.expectEqual(@as(usize, 0), (try requests(a, old, new ++ "  owner: other\n", token_config)).len);
    try t.expectEqual(@as(usize, 0), (try requests(a, old, new, "tokens:\n")).len);
    try t.expectEqual(@as(usize, 0), (try requests(a, "base:\n  tokenFee:\n    modules:\n      - maxCapacity: 1700\n" ++ tail, "base:\n  tokenFee:\n    modules:\n      - maxCapacity: 1500\n" ++ tail, token_config)).len);
}
