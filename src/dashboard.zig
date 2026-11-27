const std = @import("std");
const io = @import("io.zig");
const http = std.http;
const posix = std.posix;
const eq = std.ascii.eqlIgnoreCase;

pub const default_port: u16 = 8749;

pub const Request = struct {
    route: enum { state, metrics, review, queue, queue_target },
    query: []const u8,
    body: []const u8,
};

pub const Response = struct {
    status: http.Status = .ok,
    body: []const u8,
};

const max_head = 8 * 1024;
const max_target = 2 * 1024;
const max_body = 4 * 1024;
const max_response = 8 * 1024 * 1024;
const socket_deadline = 3 * std.time.ns_per_s;
const workers = 4;
const max_stack_lookups = 2;
const LookupCount = std.atomic.Value(usize);

const Hosts = struct {
    ip: []const u8,
    localhost: []const u8,

    fn init(port: u16, ip_buffer: []u8, localhost_buffer: []u8) !Hosts {
        if (port == 80) return .{ .ip = "127.0.0.1", .localhost = "localhost" };
        return .{
            .ip = try std.fmt.bufPrint(ip_buffer, "127.0.0.1:{d}", .{port}),
            .localhost = try std.fmt.bufPrint(localhost_buffer, "localhost:{d}", .{port}),
        };
    }
};

fn listen(port: u16) !std.net.Server {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer posix.close(fd);
    // Permit restart with sockets in TIME_WAIT without allowing a second listener.
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    var address_len = address.getOsSockLen();
    try posix.bind(fd, &address.any, address_len);
    try posix.listen(fd, 16);
    var bound: std.net.Address = undefined;
    try posix.getsockname(fd, &bound.any, &address_len);
    return .{ .listen_address = bound, .stream = .{ .handle = fd } };
}

/// `context.api` receives a request allocator and may run on any worker.
/// Keep the shared context immutable and store request-owned data in the arena.
pub fn serve(port: u16, context: anytype) !void {
    var listener = try listen(port);
    defer listener.deinit();
    var ip_buffer: [32]u8 = undefined;
    var localhost_buffer: [32]u8 = undefined;
    const hosts = try Hosts.init(listener.listen_address.getPort(), &ip_buffer, &localhost_buffer);
    try io.out("Talos dashboard at http://{s}\n", .{hosts.ip});
    var stack_lookups: LookupCount = .init(0);
    for (1..workers) |_| {
        const thread = std.Thread.spawn(.{}, acceptLoop, .{ &listener, hosts, &stack_lookups, context }) catch break;
        thread.detach();
    }
    acceptLoop(&listener, hosts, &stack_lookups, context);
}

fn acceptLoop(listener: *std.net.Server, hosts: Hosts, stack_lookups: *LookupCount, context: anytype) noreturn {
    while (true) {
        const conn = listener.accept() catch {
            std.Thread.sleep(250 * std.time.ns_per_ms);
            continue;
        };
        defer conn.stream.close();
        handle(conn.stream.handle, hosts, stack_lookups, context) catch {};
    }
}

const Destination = union(enum) {
    index,
    stylesheet,
    script,
    providers,
    favicon,
    api: @FieldType(Request, "route"),
};

const destinations = std.StaticStringMap(Destination).initComptime(.{
    .{ "/", .index },
    .{ "/app.css", .stylesheet },
    .{ "/app.js", .script },
    .{ "/providers.svg", .providers },
    .{ "/favicon.svg", .favicon },
    .{ "/api/state", Destination{ .api = .state } },
    .{ "/api/metrics", Destination{ .api = .metrics } },
    .{ "/api/review", Destination{ .api = .review } },
    .{ "/api/queue", Destination{ .api = .queue } },
    .{ "/api/queue-target", Destination{ .api = .queue_target } },
});

const Parsed = struct {
    destination: Destination,
    method: http.Method,
    query: []const u8,
    body_len: usize,
};

const HeadError = error{ InvalidRequest, InvalidHost, ForeignOrigin, NotFound, MethodNotAllowed, BodyTooLarge, TargetTooLong, UnsupportedMediaType };

fn parseHead(raw: []const u8, hosts: Hosts) HeadError!Parsed {
    const head = http.Server.Request.Head.parse(raw) catch return error.InvalidRequest;
    if (head.target.len > max_target) return error.TargetTooLong;
    if (head.target.len == 0 or head.target[0] != '/') return error.InvalidRequest;
    for (head.target) |byte| if (byte < 0x21 or byte > 0x7e or byte == '#') return error.InvalidRequest;

    var host: ?[]const u8 = null;
    var origin: ?[]const u8 = null;
    var marker: ?[]const u8 = null;
    var fetch_site: ?[]const u8 = null;
    var content_type: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidRequest;
        const name = line[0..colon];
        for (name) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
                return error.InvalidRequest;
        }
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.InvalidRequest;
        if (eq(name, "transfer-encoding") or eq(name, "content-encoding") or eq(name, "expect")) return error.InvalidRequest;
        if (eq(name, "content-length")) {
            for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidRequest;
        }
        const selected = if (eq(name, "host"))
            &host
        else if (eq(name, "origin"))
            &origin
        else if (eq(name, "x-talos-request"))
            &marker
        else if (eq(name, "sec-fetch-site"))
            &fetch_site
        else if (eq(name, "content-type"))
            &content_type
        else
            continue;
        if (selected.* != null) return error.InvalidRequest;
        selected.* = value;
    }

    const authority = host orelse return error.InvalidHost;
    if (!eq(authority, hosts.ip) and !eq(authority, hosts.localhost)) return error.InvalidHost;
    if (origin) |value| {
        const prefix = "http://";
        if (!std.mem.startsWith(u8, value, prefix) or !eq(value[prefix.len..], authority)) return error.ForeignOrigin;
    }

    const separator = std.mem.indexOfScalar(u8, head.target, '?') orelse head.target.len;
    const path = head.target[0..separator];
    const query = if (separator < head.target.len) head.target[separator + 1 ..] else "";
    const destination = destinations.get(path) orelse return error.NotFound;

    const length = head.content_length orelse 0;
    if (destination == .api) {
        if (fetch_site) |site| if (!eq(site, "same-origin") and !eq(site, "none")) return error.ForeignOrigin;
        if (destination.api == .queue) {
            if (head.method != .POST) return error.MethodNotAllowed;
            if (origin == null or !eq(marker orelse "", "1")) return error.ForeignOrigin;
            if (query.len != 0 or length == 0) return error.InvalidRequest;
            if (length > max_body) return error.BodyTooLarge;
            const media_type = content_type orelse return error.UnsupportedMediaType;
            if (!eq(media_type, "application/json") and !eq(media_type, json_type)) return error.UnsupportedMediaType;
            return .{ .destination = destination, .method = .POST, .query = "", .body_len = @intCast(length) };
        }
        if (destination.api == .queue_target) {
            if (head.method != .GET) return error.MethodNotAllowed;
            // A same-origin GET may omit Origin. The custom header keeps
            // passive browser requests from spending a GitHub call.
            if (!eq(marker orelse "", "1")) return error.ForeignOrigin;
        }
    }
    if (head.method != .GET and head.method != .HEAD) return error.MethodNotAllowed;
    if (length != 0) return error.InvalidRequest;
    return .{ .destination = destination, .method = head.method, .query = query, .body_len = 0 };
}

fn ready(fd: posix.socket_t, events: i16, timer: *std.time.Timer) !void {
    const remaining = socket_deadline -| timer.read();
    if (remaining == 0) return error.SocketTimeout;
    const ms = (remaining + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    var poll_fds = [_]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    if (try posix.poll(&poll_fds, @intCast(ms)) == 0) return error.SocketTimeout;
    if (poll_fds[0].revents & events == 0) return error.EndOfStream;
}

fn receive(fd: posix.socket_t, output: []u8, timer: *std.time.Timer) !usize {
    while (true) {
        try ready(fd, posix.POLL.IN, timer);
        const n = posix.recv(fd, output, posix.MSG.DONTWAIT) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        return n;
    }
}

fn sendAll(fd: posix.socket_t, bytes: []const u8, timer: *std.time.Timer) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        try ready(fd, posix.POLL.OUT, timer);
        const n = posix.send(fd, bytes[sent..], posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        sent += n;
    }
}

const json_type = "application/json; charset=utf-8";
const security_headers =
    "Cache-Control: no-store\r\n" ++
    "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'\r\n" ++
    "Cross-Origin-Opener-Policy: same-origin\r\n" ++
    "Cross-Origin-Resource-Policy: same-origin\r\n" ++
    "Referrer-Policy: no-referrer\r\n" ++
    "X-Content-Type-Options: nosniff\r\n" ++
    "X-Frame-Options: DENY\r\n";

fn respond(fd: posix.socket_t, status: http.Status, content_type: []const u8, body: []const u8, head_only: bool) !void {
    var buffer: [1024]u8 = undefined;
    const response_head = try std.fmt.bufPrint(
        &buffer,
        "HTTP/1.1 {d} {s}\r\nConnection: close\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}\r\n",
        .{ @intFromEnum(status), status.phrase() orelse "Unknown", content_type, body.len, security_headers },
    );
    var timer = try std.time.Timer.start();
    try sendAll(fd, response_head, &timer);
    if (!head_only) try sendAll(fd, body, &timer);
}

fn reject(fd: posix.socket_t, status: http.Status, comptime message: []const u8, head_only: bool) !void {
    return respond(fd, status, json_type, "{\"error\":\"" ++ message ++ "\"}", head_only);
}

fn handle(fd: posix.socket_t, hosts: Hosts, stack_lookups: *LookupCount, context: anytype) !void {
    var timer = try std.time.Timer.start();
    var header_buffer: [max_head]u8 = undefined;
    var used: usize = 0;
    var header_end: usize = 0;
    while (used < header_buffer.len) {
        const offset = used -| 3;
        used += try receive(fd, header_buffer[used..], &timer);
        if (std.mem.indexOfPos(u8, header_buffer[0..used], offset, "\r\n\r\n")) |end| {
            header_end = end + 4;
            break;
        }
    }
    const head_only = std.mem.startsWith(u8, header_buffer[0..used], "HEAD ");
    if (header_end == 0) return reject(fd, .request_header_fields_too_large, "Request headers are too large.", head_only);
    const request = parseHead(header_buffer[0..header_end], hosts) catch |err| return switch (err) {
        error.InvalidRequest => reject(fd, .bad_request, "Invalid request.", head_only),
        error.InvalidHost => reject(fd, .forbidden, "Use the dashboard's local address.", head_only),
        error.ForeignOrigin => reject(fd, .forbidden, "This request must come from the dashboard.", head_only),
        error.NotFound => reject(fd, .not_found, "Route not found.", head_only),
        error.MethodNotAllowed => reject(fd, .method_not_allowed, "Method not allowed.", head_only),
        error.BodyTooLarge => reject(fd, .payload_too_large, "Request body is too large.", head_only),
        error.TargetTooLong => reject(fd, .uri_too_long, "Request URL is too long.", head_only),
        error.UnsupportedMediaType => reject(fd, .unsupported_media_type, "Expected a JSON request.", head_only),
    };
    const received = header_buffer[header_end..used];
    if (received.len > request.body_len) return reject(fd, .bad_request, "Unexpected request body.", head_only);
    switch (request.destination) {
        .index => return respond(fd, .ok, "text/html; charset=utf-8", @embedFile("dashboard_web/index.html"), head_only),
        .stylesheet => return respond(fd, .ok, "text/css; charset=utf-8", @embedFile("dashboard_web/app.css"), head_only),
        .script => return respond(fd, .ok, "text/javascript; charset=utf-8", @embedFile("dashboard_web/app.js"), head_only),
        .providers => return respond(fd, .ok, "image/svg+xml", @embedFile("dashboard_web/providers.svg"), head_only),
        .favicon => return respond(fd, .ok, "image/svg+xml", @embedFile("dashboard_web/favicon.svg"), head_only),
        .api => |route| {
            var body: [max_body]u8 = undefined;
            @memcpy(body[0..received.len], received);
            var read: usize = received.len;
            while (read < request.body_len) read += try receive(fd, body[read..request.body_len], &timer);
            const lookup = route == .queue_target;
            if (lookup and stack_lookups.fetchAdd(1, .monotonic) >= max_stack_lookups) {
                _ = stack_lookups.fetchSub(1, .monotonic);
                return reject(fd, .too_many_requests, "Stack lookups are busy. Try again in a moment.", head_only);
            }
            defer if (lookup) {
                _ = stack_lookups.fetchSub(1, .monotonic);
            };
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const response = context.api(arena.allocator(), .{ .route = route, .query = request.query, .body = body[0..read] }) catch |err| {
                std.log.warn("dashboard API {s} failed ({s})", .{ @tagName(route), @errorName(err) });
                return reject(fd, .internal_server_error, "Talos could not complete the request.", head_only);
            };
            if (response.body.len > max_response) return reject(fd, .internal_server_error, "Dashboard response is too large.", head_only);
            return respond(fd, response.status, json_type, response.body, head_only);
        },
    }
}

const test_hosts: Hosts = .{ .ip = "127.0.0.1:8749", .localhost = "localhost:8749" };
const headers = "Host: 127.0.0.1:8749\r\n";
const queue_headers = headers ++ "Origin: http://127.0.0.1:8749\r\nX-Talos-Request: 1\r\nContent-Type: application/json\r\n";

test "dashboard routes same-origin reads and queue requests" {
    const t = std.testing;
    const request = try parseHead("GET /api/review?repo=owner%2Frepo&number=4 HTTP/1.1\r\n" ++ headers ++ "\r\n", test_hosts);
    try t.expectEqual(.review, request.destination.api);
    try t.expectEqualStrings("repo=owner%2Frepo&number=4", request.query);
    const queue = try parseHead("POST /api/queue HTTP/1.1\r\n" ++ queue_headers ++ "Content-Length: 15\r\n\r\n", test_hosts);
    try t.expectEqual(.queue, queue.destination.api);
    try t.expectEqual(@as(usize, 15), queue.body_len);
    try t.expectEqual(.index, (try parseHead("GET / HTTP/1.1\r\nHost: localhost:8749\r\nSec-Fetch-Site: cross-site\r\n\r\n", test_hosts)).destination);
}

test "dashboard rejects external hosts and cross-origin queue writes" {
    const t = std.testing;
    try t.expectError(error.InvalidHost, parseHead("GET /api/state HTTP/1.1\r\nHost: outside.test:8749\r\n\r\n", test_hosts));
    try t.expectError(error.InvalidRequest, parseHead("GET /api/state HTTP/1.1\r\n" ++ headers ++ "Host: localhost:8749\r\n\r\n", test_hosts));
    try t.expectError(error.ForeignOrigin, parseHead("POST /api/queue HTTP/1.1\r\n" ++ headers ++ "Origin: http://localhost:8749\r\nX-Talos-Request: 1\r\n\r\n", test_hosts));
    try t.expectError(error.ForeignOrigin, parseHead("POST /api/queue HTTP/1.1\r\n" ++ headers ++ "Origin: http://127.0.0.1:8749\r\nContent-Length: 2\r\n\r\n", test_hosts));
    try t.expectError(error.ForeignOrigin, parseHead("GET /api/state HTTP/1.1\r\n" ++ headers ++ "Sec-Fetch-Site: cross-site\r\n\r\n", test_hosts));
    try t.expectError(error.MethodNotAllowed, parseHead("GET /api/queue HTTP/1.1\r\n" ++ headers ++ "\r\n", test_hosts));
}

test "smart queue lookup needs an active same-origin GET" {
    const t = std.testing;
    const request = "GET /api/queue-target?repo=owner%2Frepo&number=4 HTTP/1.1\r\n";
    const marker = "X-Talos-Request: 1\r\n";
    try t.expectEqual(.queue_target, (try parseHead(request ++ headers ++ marker ++ "\r\n", test_hosts)).destination.api);
    try t.expectError(error.ForeignOrigin, parseHead(request ++ headers ++ "\r\n", test_hosts));
    try t.expectError(error.ForeignOrigin, parseHead(request ++ headers ++ marker ++ "Origin: http://localhost:8749\r\n\r\n", test_hosts));
    try t.expectError(error.ForeignOrigin, parseHead(request ++ headers ++ marker ++ "Sec-Fetch-Site: cross-site\r\n\r\n", test_hosts));
    try t.expectError(error.MethodNotAllowed, parseHead("HEAD /api/queue-target HTTP/1.1\r\n" ++ headers ++ marker ++ "\r\n", test_hosts));
}

test "dashboard accepts only bounded unencoded request bodies" {
    const t = std.testing;
    try t.expectError(error.BodyTooLarge, parseHead("POST /api/queue HTTP/1.1\r\n" ++ queue_headers ++ "Content-Length: 4097\r\n\r\n", test_hosts));
    try t.expectError(error.InvalidRequest, parseHead("POST /api/queue HTTP/1.1\r\n" ++ queue_headers ++ "Transfer-Encoding: chunked\r\n\r\n", test_hosts));
    try t.expectError(error.InvalidRequest, parseHead("POST /api/queue HTTP/1.1\r\n" ++ queue_headers ++ "Content-Length: 2\r\nContent-Length: 1\r\n\r\n", test_hosts));
    try t.expectError(error.InvalidRequest, parseHead("POST /api/queue HTTP/1.1\r\n" ++ queue_headers ++ "Content-Length: +2\r\n\r\n", test_hosts));
    try t.expectError(error.InvalidRequest, parseHead("GET /api/state HTTP/1.1\r\n" ++ headers ++ "Content-Length: 2\r\n\r\n", test_hosts));
    try t.expectError(error.UnsupportedMediaType, parseHead("POST /api/queue HTTP/1.1\r\n" ++ headers ++ "Origin: http://127.0.0.1:8749\r\nX-Talos-Request: 1\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n", test_hosts));
}

test "dashboard loopback transport applies security headers and reads the declared JSON body" {
    const t = std.testing;
    var listener = try listen(0);
    defer listener.deinit();
    const port = listener.listen_address.getPort();
    const expected = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    try t.expect(std.net.Address.eql(expected, listener.listen_address));

    const Mock = struct {
        calls: *usize,

        pub fn api(self: @This(), _: std.mem.Allocator, req: Request) !Response {
            self.calls.* += 1;
            try t.expectEqual(.queue, req.route);
            try t.expectEqualStrings("{}", req.body);
            return .{ .status = .accepted, .body = "{\"queued\":true}" };
        }
    };
    var calls: usize = 0;
    var stack_lookups: LookupCount = .init(0);
    var ip_buffer: [32]u8 = undefined;
    var localhost_buffer: [32]u8 = undefined;
    const hosts = try Hosts.init(port, &ip_buffer, &localhost_buffer);
    const client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    {
        const conn = try listener.accept();
        defer conn.stream.close();
        var request: [512]u8 = undefined;
        const bytes = try std.fmt.bufPrint(
            &request,
            "POST /api/queue HTTP/1.1\r\nHost: {s}\r\nOrigin: http://{s}\r\nX-Talos-Request: 1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{{}}",
            .{ hosts.ip, hosts.ip },
        );
        var timer = try std.time.Timer.start();
        try sendAll(client.handle, bytes, &timer);
        try handle(conn.stream.handle, hosts, &stack_lookups, Mock{ .calls = &calls });
    }
    var buffer: [1024]u8 = undefined;
    var reader = client.reader(&.{});
    const size = try reader.interface().readSliceShort(&buffer);
    const response = buffer[0..size];
    try t.expect(std.mem.startsWith(u8, response, "HTTP/1.1 202 Accepted\r\n"));
    try t.expect(std.mem.indexOf(u8, response, "Cache-Control: no-store\r\n") != null);
    try t.expect(std.mem.indexOf(u8, response, "frame-ancestors 'none'") != null);
    try t.expect(std.mem.indexOf(u8, response, "Access-Control-Allow-Origin:") == null);
    try t.expect(std.mem.endsWith(u8, response, "\r\n\r\n{\"queued\":true}"));
    try t.expectEqual(@as(usize, 1), calls);
}
