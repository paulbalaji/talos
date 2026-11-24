const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");
const stack = @import("stack.zig");
const A = io.A;
const eq = io.eq;

const User = struct { login: []const u8 };
const Page = struct { hasNextPage: bool, endCursor: ?[]const u8 };
fn Connection(comptime T: type) type {
    return struct { nodes: []const T, pageInfo: Page };
}
fn GraphResponse(comptime T: type) type {
    return struct { data: ?T = null, errors: ?[]const std.json.Value = null };
}
const RawThread = struct {
    id: []const u8,
    isResolved: bool,
    isOutdated: bool,
    path: []const u8,
    line: ?u32,
    comments: Connection(core.Reply),
};

pub const File = struct { filename: []const u8, patch: ?[]const u8 = null, status: []const u8 = "", previous_filename: ?[]const u8 = null, additions: ?u32 = null, deletions: ?u32 = null };

pub const FollowupRef = struct {
    number: u32,
    head: struct { ref: []const u8, repo: ?struct { full_name: []const u8 } },
};

const review_comment_page_size = 100;
const ReviewComment = struct {
    id: u64,
    pull_request_review_id: u64,
    in_reply_to_id: ?u64 = null,
    path: []const u8,
    original_commit_id: []const u8,
    original_line: ?u32 = null,
    original_start_line: ?u32 = null,
    side: ?[]const u8 = null,
};

pub const Client = struct {
    cmd: io.Command,
    gh: []const u8,
    repo: []const u8,
    calls: ?*u32 = null,

    fn invoke(self: Client, args: []const []const u8, input: []const u8) ![]const u8 {
        var cmd = self.cmd;
        cmd.transport = .github;
        if (self.calls) |count| count.* +|= 1;
        return cmd.run(args, input, 90);
    }

    fn endpoint(self: Client, suffix: []const u8) ![]const u8 {
        return io.fmt(self.cmd.a, "repos/{s}/{s}", .{ self.repo, suffix });
    }

    fn api(self: Client, endpoint_path: []const u8, extra: []const []const u8, input: []const u8) ![]const u8 {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(self.cmd.a, &.{ self.gh, "api", "--hostname", "github.com", endpoint_path });
        try args.appendSlice(self.cmd.a, extra);
        return self.invoke(args.items, input);
    }

    pub fn identity(self: Client) ![]const u8 {
        const result = self.api("user", &.{}, "") catch |err| return transportFailure(err, error.GitHubIdentityFailed);
        return (try io.parse(self.cmd.a, User, result)).login;
    }

    fn pages(self: Client, comptime T: type, suffix: []const u8) ![]const T {
        const input = try self.api(try self.endpoint(suffix), &.{ "--paginate", "--slurp" }, "");
        const a = self.cmd.a;
        const blocks = try io.parse(a, []const []const T, input);
        var combined: std.ArrayList(T) = .empty;
        for (blocks) |block| try combined.appendSlice(a, block);
        return combined.toOwnedSlice(a);
    }

    const ready_query =
        \\query($owner: String!, $name: String!, $endCursor: String) {
        \\  repository(owner: $owner, name: $name) {
        \\    pullRequests(first: 100, after: $endCursor, states: [OPEN]) {
        \\      pageInfo { hasNextPage endCursor }
        \\      nodes { number headRefOid baseRefOid headRefName baseRefName headRepository { nameWithOwner } isDraft nativeStack:stack { id number } }
        \\    }
        \\  }
        \\}
    ;

    pub fn ready(self: Client) ![]const core.Pull {
        const a = self.cmd.a;
        const fields = try self.repoFields();
        const args = [_][]const u8{
            "--paginate", "--slurp", "-f", try io.fmt(a, "query={s}", .{ready_query}),
        } ++ fields;
        const raw = self.api("graphql", &args, "") catch |err| return transportFailure(err, error.GitHubListFailed);
        return decodeReady(a, raw);
    }

    fn decodeReady(a: A, raw: []const u8) ![]const core.Pull {
        const Data = struct { repository: struct { pullRequests: Connection(core.Pull) } };
        const responses = try io.parse(a, []const GraphResponse(Data), raw);
        if (responses.len == 0) return error.InvalidPagination;
        var pulls: std.ArrayList(core.Pull) = .empty;
        var cursor: ?[]const u8 = null;
        for (responses, 0..) |page, index| {
            try checkGraphErrors(page.errors, error.GitHubListFailed);
            const data = page.data orelse return error.GitHubListFailed;
            const connection = data.repository.pullRequests;
            cursor = try next(connection.pageInfo, cursor);
            if ((cursor == null) != (index + 1 == responses.len)) return error.InvalidPagination;
            try pulls.appendSlice(a, connection.nodes);
        }
        return pulls.toOwnedSlice(a);
    }

    pub fn pull(self: Client, number: u32) !core.Pull {
        const a = self.cmd.a;
        const repository = try io.fmt(a, "github.com/{s}", .{self.repo});
        const input = self.invoke(&.{
            self.gh,                                                                                                       "pr", "view", try io.fmt(a, "{d}", .{number}), "-R", repository, "--json",
            "number,headRefOid,baseRefOid,baseRefName,isDraft,state,title,body,author,statusCheckRollup,mergeStateStatus",
        }, "") catch |err| return transportFailure(err, error.GitHubPullFailed);
        const result = try io.parse(a, core.Pull, input);
        if (result.number != number) return error.GitHubTargetMismatch;
        return result;
    }

    pub fn followupRef(self: Client, branch: []const u8, known: ?u32) !?FollowupRef {
        const a = self.cmd.a;
        if (known) |pr| {
            const endpoint_path = try self.endpoint(try io.fmt(a, "pulls/{d}", .{pr}));
            const data = self.api(endpoint_path, &.{}, "") catch |err| return transportFailure(err, error.GitHubFollowupLookupFailed);
            const result = try io.parse(a, FollowupRef, data);
            if (result.number != pr) return error.GitHubTargetMismatch;
            return result;
        }
        const head = try io.fmt(a, "head={s}:{s}", .{ std.mem.sliceTo(self.repo, '/'), branch });
        const raw = self.api(try self.endpoint("pulls"), &.{ "--method", "GET", "-f", head, "-f", "state=all", "-F", "per_page=2" }, "") catch |err|
            return transportFailure(err, error.GitHubFollowupLookupFailed);
        const matches = try io.parse(a, []const FollowupRef, raw);
        if (matches.len > 1) return error.AmbiguousFollowupDraft;
        return if (matches.len == 1) matches[0] else null;
    }

    pub fn createFollowup(self: Client, branch: []const u8, base: []const u8, title: []const u8, body: []const u8) !void {
        const payload = try io.json(self.cmd.a, .{ .head = branch, .base = base, .title = title, .body = body, .draft = true });
        _ = self.api(try self.endpoint("pulls"), &.{ "--method", "POST", "--input", "-" }, payload) catch |err|
            return transportFailure(err, error.FollowupDraftUnconfirmed);
    }

    pub fn readyFollowup(self: Client, number: u32) !void {
        const a = self.cmd.a;
        const repo = try io.fmt(a, "github.com/{s}", .{self.repo});
        _ = self.invoke(&.{ self.gh, "pr", "ready", try io.fmt(a, "{d}", .{number}), "-R", repo }, "") catch |err|
            return transportFailure(err, error.FollowupReadyUnconfirmed);
    }

    pub fn mergeFollowup(self: Client, number: u32, head: []const u8) !void {
        if (!core.validOid(head)) return error.InvalidFollowupRef;
        const a = self.cmd.a;
        const repo = try io.fmt(a, "github.com/{s}", .{self.repo});
        _ = self.invoke(&.{ self.gh, "pr", "merge", try io.fmt(a, "{d}", .{number}), "-R", repo, "--auto", "--squash", "--match-head-commit", head }, "") catch |err|
            return transportFailure(err, error.FollowupMergeUnconfirmed);
    }

    pub fn followupMergeActive(self: Client, number: u32) !bool {
        const query =
            \\query($owner:String!, $name:String!, $number:Int!) {
            \\  repository(owner:$owner, name:$name) {
            \\    pullRequest(number:$number) { number autoMergeRequest { enabledAt } mergeQueueEntry { id } }
            \\  }
            \\}
        ;
        const a = self.cmd.a;
        const fields = (try self.repoFields()) ++ [_][]const u8{ "-F", try io.fmt(a, "number={d}", .{number}) };
        const Data = struct { repository: struct { pullRequest: struct {
            number: u32,
            autoMergeRequest: ?struct { enabledAt: []const u8 },
            mergeQueueEntry: ?struct { id: []const u8 },
        } } };
        const data = try self.graph(Data, query, &fields, null);
        const result = data.repository.pullRequest;
        if (result.number != number) return error.GitHubTargetMismatch;
        return result.autoMergeRequest != null or result.mergeQueueEntry != null;
    }

    pub fn stackPulls(self: Client, numbers: []const u32) ![]stack.Pin {
        if (numbers.len == 0) return &.{};
        const a = self.cmd.a;
        var query: std.ArrayList(u8) = .empty;
        const writer = query.writer(a);
        try writer.writeAll("query($owner:String!,$name:String!){repository(owner:$owner,name:$name){");
        for (numbers) |number| {
            try writer.print("p{d}:pullRequest(number:{d}){{number headRefOid baseRefOid headRefName baseRefName headRepository{{nameWithOwner}} state isDraft nativeStack:stack{{id number}}}}", .{ number, number });
        }
        try writer.writeAll("}}");
        const args = [_][]const u8{ "-f", try io.fmt(a, "query={s}", .{query.items}) } ++ try self.repoFields();
        const input = self.api("graphql", &args, "") catch |err| return transportFailure(err, error.GitHubStackFailed);
        const response = try io.parse(a, GraphResponse(struct { repository: std.json.Value }), input);
        try checkGraphErrors(response.errors, error.GitHubStackFailed);
        const data = response.data orelse return error.GitHubStackFailed;
        if (data.repository != .object) return error.GitHubStackFailed;
        const pins = try a.alloc(stack.Pin, numbers.len);
        for (numbers, pins) |number, *pin| {
            const node = data.repository.object.get(try io.fmt(a, "p{d}", .{number})) orelse return error.GitHubStackFailed;
            pin.* = try std.json.parseFromValueLeaky(stack.Pin, a, node, .{});
            if (pin.number != number or !pin.valid()) return error.GitHubTargetMismatch;
        }
        return pins;
    }

    const native_query =
        \\query($id:ID!,$cursor:String){
        \\  node(id:$id){... on PullRequestStack {
        \\    id number size entries(first:25,after:$cursor){
        \\      totalCount pageInfo{hasNextPage endCursor}
        \\      nodes{position pullRequest{
        \\        number headRefOid baseRefOid headRefName baseRefName state isDraft
        \\        repository{nameWithOwner} headRepository{nameWithOwner}
        \\      }}
        \\    }
        \\  }}
        \\}
    ;
    const NativePage = struct {
        id: []const u8,
        number: u32,
        size: usize,
        entries: struct {
            totalCount: usize,
            pageInfo: Page,
            nodes: []const struct { position: usize, pullRequest: ?stack.Pin },
        },
    };

    fn nativePage(self: Client, id: []const u8, cursor: ?[]const u8) !NativePage {
        const a = self.cmd.a;
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "-f", try io.fmt(a, "query={s}", .{native_query}), "-f", try io.fmt(a, "id={s}", .{id}) });
        if (cursor) |value| try args.appendSlice(a, &.{ "-f", try io.fmt(a, "cursor={s}", .{value}) });
        const raw = self.api("graphql", args.items, "") catch |err| return transportFailure(err, error.GitHubStackFailed);
        const parsed = try io.parse(a, GraphResponse(struct { node: ?NativePage }), raw);
        try checkGraphErrors(parsed.errors, error.GitHubStackFailed);
        const data = parsed.data orelse return error.GitHubStackFailed;
        return data.node orelse error.GitHubStackChanged;
    }

    pub fn nativeStack(self: Client, stack_ref: stack.NativeRef, prefix: ?usize) !stack.NativeGroup {
        const a = self.cmd.a;
        var pins: std.ArrayList(stack.Pin) = .empty;
        var cursor: ?[]const u8 = null;
        var size: ?usize = null;
        while (true) {
            const response = try self.nativePage(stack_ref.id, cursor);
            if (response.number != stack_ref.number or !eq(u8, response.id, stack_ref.id) or
                response.size == 0 or response.entries.totalCount != response.size or
                (size != null and size.? != response.size)) return error.GitHubStackChanged;
            size = response.size;
            const wanted = prefix orelse response.size;
            if (wanted > response.size or response.entries.nodes.len == 0 or response.entries.nodes.len > 25)
                return error.InvalidPagination;
            for (response.entries.nodes) |entry| {
                if (entry.position != pins.items.len + 1 or entry.position > response.size)
                    return error.GitHubStackChanged;
                var pin = entry.pullRequest orelse return error.GitHubStackChanged;
                const repository = pin.repository orelse return error.GitHubStackChanged;
                if (!pin.valid() or !std.ascii.eqlIgnoreCase(repository.nameWithOwner, self.repo))
                    return error.GitHubStackChanged;
                pin.nativeStack = stack_ref;
                try pins.append(a, pin);
                if (prefix != null and pins.items.len == wanted)
                    return .{ .ref = stack_ref, .pins = pins.items };
            }
            cursor = try next(response.entries.pageInfo, cursor);
            if (cursor == null) {
                if (pins.items.len != wanted) return error.InvalidPagination;
                return .{ .ref = stack_ref, .pins = pins.items };
            }
            if (pins.items.len >= wanted) return error.InvalidPagination;
        }
    }

    pub fn nativeByNumber(self: Client, number: u32) !stack.NativeGroup {
        const a = self.cmd.a;
        const path = try self.endpoint(try io.fmt(a, "stacks/{d}", .{number}));
        const raw = self.api(path, &.{ "-H", "X-GitHub-Api-Version: 2026-03-10" }, "") catch |err|
            return transportFailure(err, error.GitHubStackFailed);
        const response = try io.parse(a, struct { number: u32, node_id: []const u8 }, raw);
        if (response.number != number or response.node_id.len == 0) return error.GitHubTargetMismatch;
        return self.nativeStack(.{ .number = number, .id = response.node_id }, null);
    }

    pub fn nativeGroups(self: Client, pulls: []const core.Pull) ![]stack.NativeGroup {
        const a = self.cmd.a;
        var loaded: std.AutoHashMapUnmanaged(u32, stack.NativeRef) = .empty;
        defer loaded.deinit(a);
        var membership: std.AutoHashMapUnmanaged(u32, stack.NativeRef) = .empty;
        defer membership.deinit(a);
        var groups: std.ArrayList(stack.NativeGroup) = .empty;
        for (pulls) |pull_value| {
            const stack_ref = pull_value.nativeStack orelse continue;
            const slot = try loaded.getOrPut(a, stack_ref.number);
            if (slot.found_existing) {
                if (!stack.sameRef(slot.value_ptr.*, stack_ref)) return error.GitHubStackChanged;
                continue;
            }
            slot.value_ptr.* = stack_ref;
            const group = try self.nativeStack(stack_ref, null);
            for (group.pins) |pin| {
                const member = try membership.getOrPut(a, pin.number);
                if (member.found_existing) return error.GitHubStackChanged;
                member.value_ptr.* = stack_ref;
            }
            try groups.append(a, group);
        }
        for (pulls) |pull_value| {
            if (!stack.sameRef(membership.get(pull_value.number), pull_value.nativeStack))
                return error.GitHubStackChanged;
        }
        return groups.items;
    }

    pub fn reviews(self: Client, number: u32) ![]const core.Prior {
        return self.pages(core.Prior, try io.fmt(self.cmd.a, "pulls/{d}/reviews?per_page=100", .{number})) catch |err|
            transportFailure(err, error.GitHubReviewsFailed);
    }

    pub fn files(self: Client, number: u32) ![]const File {
        return self.pages(File, try io.fmt(self.cmd.a, "pulls/{d}/files?per_page=100", .{number})) catch |err|
            transportFailure(err, error.GitHubFilesFailed);
    }

    pub fn mergeBase(self: Client, base: []const u8, head: []const u8) ![]const u8 {
        if (!core.validOid(base) or !core.validOid(head)) return error.InvalidCommit;
        const a = self.cmd.a;
        // The compare API only returns file patches on page one.
        const target = try self.endpoint(try io.fmt(a, "compare/{s}...{s}?per_page=1&page=2", .{ base, head }));
        const raw = self.api(target, &.{}, "") catch |err| return transportFailure(err, error.GitHubCompareFailed);
        const response = try io.parse(a, struct { merge_base_commit: struct { sha: []const u8 } }, raw);
        const oid = response.merge_base_commit.sha;
        if (!core.validOid(oid)) return error.InvalidMergeBase;
        return oid;
    }

    pub fn post(self: Client, number: u32, payload: core.Payload) !u64 {
        const a = self.cmd.a;
        const target = try self.endpoint(try io.fmt(a, "pulls/{d}/reviews", .{number}));
        const data = self.api(target, &.{ "--method", "POST", "--input", "-" }, try io.json(a, payload)) catch |err|
            return transportFailure(err, error.GitHubPostUnconfirmed);
        return (try io.parse(a, struct { id: u64 }, data)).id;
    }

    pub fn readReview(self: Client, number: u32, id: u64) !core.Prior {
        const a = self.cmd.a;
        const target = try self.endpoint(try io.fmt(a, "pulls/{d}/reviews/{d}", .{ number, id }));
        const data = self.api(target, &.{}, "") catch |err| return transportFailure(err, error.GitHubReadbackFailed);
        return io.parse(a, core.Prior, data);
    }

    pub fn verifyReviewComments(self: Client, number: u32, id: u64, head: []const u8, expected: []const core.Inline) !void {
        if (expected.len >= review_comment_page_size) return error.ReviewReadbackMismatch;
        const a = self.cmd.a;
        const target = try self.endpoint(try io.fmt(a, "pulls/{d}/reviews/{d}/comments?per_page={d}", .{ number, id, review_comment_page_size }));
        const data = self.api(target, &.{}, "") catch |err| return transportFailure(err, error.GitHubReadbackFailed);
        const listed = try io.parse(a, []const ReviewComment, data);
        if (listed.len >= review_comment_page_size or listed.len != expected.len) return error.ReviewReadbackMismatch;

        var matched = std.StaticBitSet(review_comment_page_size).initEmpty();
        for (listed) |summary| {
            if (summary.pull_request_review_id != id or summary.in_reply_to_id != null) return error.ReviewReadbackMismatch;
            // GitHub's review-scoped list can omit the original line and side.
            // Those fields are available on an individual review comment.
            const comment_endpoint = try self.endpoint(try io.fmt(a, "pulls/comments/{d}", .{summary.id}));
            const raw = self.api(comment_endpoint, &.{}, "") catch |err| return transportFailure(err, error.GitHubReadbackFailed);
            const comment = try io.parse(a, ReviewComment, raw);
            const index = try reviewCommentIndex(comment, summary.id, id, head, expected);
            if (matched.isSet(index)) return error.ReviewReadbackMismatch;
            matched.set(index);
        }
    }

    fn reviewCommentIndex(comment: ReviewComment, comment_id: u64, review_id: u64, head: []const u8, expected: []const core.Inline) !usize {
        if (comment.id != comment_id or comment.pull_request_review_id != review_id or comment.in_reply_to_id != null or
            !eq(u8, comment.original_commit_id, head) or comment.original_start_line != null) return error.ReviewReadbackMismatch;
        const line = comment.original_line orelse return error.ReviewReadbackMismatch;
        const side = comment.side orelse return error.ReviewReadbackMismatch;
        for (expected, 0..) |anchor, index| {
            if (line == anchor.line and eq(u8, side, anchor.side) and eq(u8, comment.path, anchor.path)) return index;
        }
        return error.ReviewReadbackMismatch;
    }

    fn graph(self: Client, comptime Data: type, query: []const u8, fields: []const []const u8, cursor: ?[]const u8) !Data {
        const a = self.cmd.a;
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "-f", try io.fmt(a, "query={s}", .{query}) });
        try args.appendSlice(a, fields);
        if (cursor) |value| try args.appendSlice(a, &.{ "-f", try io.fmt(a, "cursor={s}", .{value}) });
        const input = self.api("graphql", args.items, "") catch |err| return transportFailure(err, error.GitHubThreadsFailed);
        const result = try io.parse(a, GraphResponse(Data), input);
        try checkGraphErrors(result.errors, error.GitHubThreadsFailed);
        return result.data orelse error.GitHubThreadsFailed;
    }

    const thread_query =
        \\query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
        \\  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        \\    comments(first: 50) { pageInfo { hasNextPage endCursor }
        \\      nodes { author { login kind: __typename } body url updatedAt association: authorAssociation }
        \\    }
        \\    reviewThreads(first: 50, after: $cursor) { pageInfo { hasNextPage endCursor }
        \\      nodes { id isResolved isOutdated path line
        \\        comments(first: 50) { pageInfo { hasNextPage endCursor }
        \\          nodes { author { login kind: __typename } body url updatedAt association: authorAssociation originalCommit { oid } }
        \\        }
        \\      }
        \\    }
        \\  } }
        \\}
    ;
    const conversation_query =
        \\query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
        \\  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        \\    comments(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor }
        \\      nodes { author { login kind: __typename } body url updatedAt association: authorAssociation }
        \\    }
        \\  } }
        \\}
    ;
    const reply_query =
        \\query($id: ID!, $cursor: String) {
        \\  node(id: $id) { ... on PullRequestReviewThread {
        \\    comments(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor }
        \\      nodes { author { login kind: __typename } body url updatedAt association: authorAssociation originalCommit { oid } }
        \\    }
        \\  } }
        \\}
    ;

    fn next(page: Page, current: ?[]const u8) !?[]const u8 {
        if (!page.hasNextPage) return null;
        const cursor = page.endCursor orelse return error.InvalidPagination;
        if (current != null and eq(u8, cursor, current.?)) return error.InvalidPagination;
        return cursor;
    }

    fn thread(self: Client, raw: RawThread) !core.Thread {
        const a = self.cmd.a;
        var replies: std.ArrayList(core.Reply) = .empty;
        try replies.appendSlice(a, raw.comments.nodes);
        var cursor = try next(raw.comments.pageInfo, null);
        const Data = struct { node: struct { comments: Connection(core.Reply) } };
        while (cursor != null) {
            if (replies.items.len > 800) return error.ThreadContextLimit;
            const data = try self.graph(Data, reply_query, &.{ "-f", try io.fmt(a, "id={s}", .{raw.id}) }, cursor);
            try replies.appendSlice(a, data.node.comments.nodes);
            cursor = try next(data.node.comments.pageInfo, cursor);
        }
        var truncated = false;
        for (replies.items) |*reply| {
            if (reply.body.len > 2400) {
                truncated = true;
                reply.truncated = true;
                reply.body = try io.fmt(a, "{s} [reply truncated]", .{reply.body[0..core.safePrefix(reply.body, 2400)]});
            }
        }
        return .{
            .id = raw.id,
            .isResolved = raw.isResolved,
            .isOutdated = raw.isOutdated,
            .path = raw.path,
            .line = raw.line,
            .replies = replies.items,
            .truncated = truncated,
        };
    }

    fn conversation(self: Client, fields: []const []const u8, page: Connection(core.Reply)) ![]const core.Reply {
        const a = self.cmd.a;
        const Data = struct { repository: struct { pullRequest: struct { comments: Connection(core.Reply) } } };
        var comments: std.ArrayList(core.Reply) = .empty;
        var current = page;
        var cursor: ?[]const u8 = null;
        var total: usize = 0;
        while (true) {
            total += current.nodes.len;
            if (total > 500) return error.ThreadContextLimit;
            for (current.nodes) |reply| {
                if (reply.author) |author| {
                    if (eq(u8, author.kind, "Bot") or std.ascii.endsWithIgnoreCase(author.login, "[bot]")) continue;
                }
                var comment = reply;
                if (comment.body.len > 2400) {
                    comment.truncated = true;
                    comment.body = try io.fmt(a, "{s} [reply truncated]", .{reply.body[0..core.safePrefix(reply.body, 2400)]});
                }
                try comments.append(a, comment);
            }
            cursor = try next(current.pageInfo, cursor);
            if (cursor == null) return comments.items;
            const data = try self.graph(Data, conversation_query, fields, cursor);
            current = data.repository.pullRequest.comments;
        }
    }

    fn repoFields(self: Client) ![4][]const u8 {
        const a = self.cmd.a;
        const slash = std.mem.indexOfScalar(u8, self.repo, '/') orelse return error.InvalidRepository;
        return .{
            "-f", try io.fmt(a, "owner={s}", .{self.repo[0..slash]}),
            "-f", try io.fmt(a, "name={s}", .{self.repo[slash + 1 ..]}),
        };
    }

    pub fn discussion(self: Client, number: u32) !core.Discussion {
        const a = self.cmd.a;
        const fields = (try self.repoFields()) ++ [_][]const u8{ "-F", try io.fmt(a, "number={d}", .{number}) };
        const Data = struct { repository: struct { pullRequest: struct {
            reviewThreads: Connection(RawThread),
            comments: ?Connection(core.Reply) = null,
        } } };
        var collected: std.ArrayList(core.Thread) = .empty;
        var comments: []const core.Reply = &.{};
        var cursor: ?[]const u8 = null;
        while (true) {
            const data = try self.graph(Data, thread_query, &fields, cursor);
            const pr_data = data.repository.pullRequest;
            if (cursor == null) {
                if (pr_data.comments) |page| comments = try self.conversation(&fields, page);
            }
            const connection = pr_data.reviewThreads;
            for (connection.nodes) |raw| try collected.append(a, try self.thread(raw));
            cursor = try next(connection.pageInfo, cursor);
            if (cursor == null) return .{ .threads = try collected.toOwnedSlice(a), .comments = comments };
            if (collected.items.len > 500) return error.ThreadContextLimit;
        }
    }
};

fn transportFailure(err: anyerror, fallback: anyerror) anyerror {
    return if (err == error.GitHubRateLimited) err else fallback;
}

fn checkGraphErrors(errors: ?[]const std.json.Value, fallback: anyerror) !void {
    const items = errors orelse return;
    for (items) |item| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind == .string and eq(u8, kind.string, "RATE_LIMITED")) return error.GitHubRateLimited;
    }
    return fallback;
}

test "a paginated scan rejects partial responses and preserves discovery order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page1 =
        \\{"data":{"repository":{"pullRequests":{"nodes":[{"number":20,"headRefOid":"aaa","isDraft":false}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}
    ;
    const page2 =
        \\{"data":{"repository":{"pullRequests":{"nodes":[{"number":10,"headRefOid":"bbb","isDraft":true}],"pageInfo":{"hasNextPage":false,"endCursor":"final"}}}}}
    ;
    const pulls = try Client.decodeReady(a, "[" ++ page1 ++ "," ++ page2 ++ "]");
    try std.testing.expectEqual(@as(usize, 2), pulls.len);
    try std.testing.expectEqual(@as(u32, 20), pulls[0].number);
    try std.testing.expect(pulls[1].isDraft);
    try std.testing.expectError(error.InvalidPagination, Client.decodeReady(a, "[" ++ page1 ++ "]"));
    try std.testing.expectError(error.InvalidPagination, Client.decodeReady(a, "[" ++ page1 ++ "," ++ page1 ++ "]"));
    try std.testing.expectError(error.GitHubListFailed, Client.decodeReady(a, "[" ++ page1 ++ ",{\"errors\":[{}]}]"));
    try std.testing.expectError(error.GitHubRateLimited, Client.decodeReady(a, "[{\"errors\":[{\"type\":\"RATE_LIMITED\"}]}]"));
}

test "review readback matches original inline coordinates and rejects replies or foreign reviews" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const old = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const new = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const json =
        \\{"id":5,"pull_request_review_id":101,"path":"src/core.zig","side":"RIGHT","original_line":77,"line":null,"original_commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","commit_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
    ;
    const expected = [_]core.Inline{.{ .path = "src/core.zig", .line = 77, .body = "" }};
    const comment = try io.parse(arena.allocator(), ReviewComment, json);
    try t.expectEqual(@as(usize, 0), try Client.reviewCommentIndex(comment, 5, 101, old, &expected));
    try t.expectError(error.ReviewReadbackMismatch, Client.reviewCommentIndex(comment, 5, 101, new, &expected));
    try t.expectError(error.ReviewReadbackMismatch, Client.reviewCommentIndex(comment, 5, 102, old, &expected));
    try t.expectError(error.ReviewReadbackMismatch, Client.reviewCommentIndex(comment, 6, 101, old, &expected));
    var altered = comment;
    altered.side = "LEFT";
    try t.expectError(error.ReviewReadbackMismatch, Client.reviewCommentIndex(altered, 5, 101, old, &expected));
    altered = comment;
    altered.in_reply_to_id = 4;
    try t.expectError(error.ReviewReadbackMismatch, Client.reviewCommentIndex(altered, 5, 101, old, &expected));
}
