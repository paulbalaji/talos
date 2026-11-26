const std = @import("std");
const core = @import("core.zig");
const io = @import("io.zig");

pub const max_stacks = 8;
pub const max_members = 8;
pub const context_members = 4;
const diff_bytes = 640;
const finding_bytes = 480;

pub const RepositoryRef = struct { nameWithOwner: []const u8 };
pub const NativeRef = struct { id: []const u8, number: u32 };

pub const Pin = struct {
    number: u32,
    headRefOid: []const u8,
    baseRefOid: []const u8,
    headRefName: []const u8,
    baseRefName: []const u8,
    headRepository: ?RepositoryRef,
    repository: ?RepositoryRef = null,
    nativeStack: ?NativeRef = null,
    state: enum { OPEN, MERGED, CLOSED },
    isDraft: bool,

    pub fn valid(self: Pin) bool {
        return self.number != 0 and core.validOid(self.headRefOid) and core.validOid(self.baseRefOid);
    }

    pub fn reviewable(self: Pin) bool {
        return self.state == .OPEN;
    }

    pub fn pull(self: Pin) core.Pull {
        return .{
            .number = self.number,
            .headRefOid = self.headRefOid,
            .baseRefOid = self.baseRefOid,
            .headRefName = self.headRefName,
            .baseRefName = self.baseRefName,
            .headRepository = self.headRepository,
            .nativeStack = self.nativeStack,
            .isDraft = self.isDraft,
            .state = @tagName(self.state),
        };
    }

    fn fromOpen(pr: core.Pull) ?Pin {
        if (!core.isReviewable(pr) or !core.validOid(pr.headRefOid) or !core.validOid(pr.baseRefOid) or
            pr.headRefName.len == 0 or pr.baseRefName.len == 0) return null;
        return .{
            .number = pr.number,
            .headRefOid = pr.headRefOid,
            .baseRefOid = pr.baseRefOid,
            .headRefName = pr.headRefName,
            .baseRefName = pr.baseRefName,
            .headRepository = pr.headRepository,
            .nativeStack = pr.nativeStack,
            .state = .OPEN,
            .isDraft = pr.isDraft,
        };
    }
};

pub const Digest = struct {
    diff: []const u8,
    findings: []const u8 = "",

    pub fn make(a: io.A, evidence: []const u8, result: ?core.Payload) !Digest {
        var findings: std.ArrayList(u8) = .empty;
        if (result) |review| {
            // Reserve space for the inline findings so the summary cannot consume it all.
            try findings.appendSlice(a, review.body[0..core.safePrefix(review.body, finding_bytes / 2)]);
            for (review.comments) |comment| {
                const remaining = finding_bytes - findings.items.len;
                if (remaining <= 3) break;
                const text = try io.fmt(a, "\n{s}:{d} {s}", .{ comment.path, comment.line, comment.body });
                try findings.appendSlice(a, text[0..core.safePrefix(text, remaining)]);
            }
        }
        return .{ .diff = evidence[0..core.safePrefix(evidence, diff_bytes)], .findings = findings.items };
    }
};

pub const Member = struct {
    pin: Pin,
    // A merged PR's base ref may move to the merge commit. Keep the last
    // verified open pin's base when its head survives unchanged.
    diff_base: []const u8,
    digest: ?Digest = null,
};

pub const Stack = struct {
    name: []const u8,
    automatic: bool = false,
    native: ?NativeRef = null,
    members: []Member,
};

pub const NativeGroup = struct {
    ref: NativeRef,
    pins: []Pin,
};

pub const Ancestor = struct {
    number: u32,
    head: []const u8,
    base: []const u8,
    state: []const u8,
    diff_excerpt: []const u8,
    review_excerpt: []const u8,
};

pub const Context = struct {
    pins: []const Pin = &.{},
    ancestors: []const Ancestor = &.{},
    native: ?NativeRef = null,
};

pub fn inheritsAllModels(context: Context, jobs: []const core.Job) bool {
    if (context.pins.len < 2) return false;
    for (context.pins[0 .. context.pins.len - 1]) |pin| {
        if (!pin.reviewable()) continue;
        const job = matchingJob(jobs, pin) orelse continue;
        const report = job.route_report orelse continue;
        const input = job.review_input orelse continue;
        if (job.phase == .complete and report.all_models and io.eq(u8, input.base.oid, pin.baseRefOid))
            return true;
    }
    return false;
}

pub const Position = struct { stack_index: usize, member_index: usize };

pub fn find(stacks: []const Stack, number: u32) ?Position {
    for (stacks, 0..) |item, stack_index| {
        for (item.members, 0..) |member, member_index| {
            if (member.pin.number == number) return .{ .stack_index = stack_index, .member_index = member_index };
        }
    }
    return null;
}

pub fn named(stacks: []const Stack, name: []const u8) ?usize {
    for (stacks, 0..) |item, index| {
        if (!item.automatic and std.ascii.eqlIgnoreCase(item.name, name)) return index;
    }
    return null;
}

fn inExplicit(stacks: []const Stack, number: u32) bool {
    const position = find(stacks, number) orelse return false;
    return !stacks[position.stack_index].automatic;
}

fn inNative(stacks: []const Stack, number: u32) bool {
    const position = find(stacks, number) orelse return false;
    return stacks[position.stack_index].native != null;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

pub fn validateRegistration(entry: core.Entry, name: []const u8, members: []const u32) !void {
    if (!validName(name)) return error.InvalidStackName;
    if (members.len < 2 or members.len > max_members) return error.InvalidStackSize;
    var explicit: usize = 0;
    for (entry.stacks) |item| {
        if (!item.automatic) explicit += 1;
    }
    if (explicit >= max_stacks) return error.StackLimit;
    if (named(entry.stacks, name) != null) return error.StackAlreadyExists;
    for (members, 0..) |number, index| {
        if (inExplicit(entry.stacks, number) or inNative(entry.stacks, number) or std.mem.indexOfScalar(u32, members[0..index], number) != null)
            return error.StackMemberAlreadyListed;
    }
}

pub fn register(entry: *core.Entry, a: io.A, name: []const u8, pins: []const Pin) !void {
    if (pins.len < 2 or pins.len > max_members) return error.InvalidStackSize;
    var numbers_buffer: [max_members]u32 = undefined;
    for (pins, numbers_buffer[0..pins.len]) |pin, *number| number.* = pin.number;
    try validateRegistration(entry.*, name, numbers_buffer[0..pins.len]);
    for (pins, 0..) |pin, index| {
        if (pin.nativeStack != null) return error.PreferGitHubStack;
        if (!pin.valid() or !pin.reviewable()) return error.PullRequestNotReady;
        if (index > 0 and !linked(entry.repo.name, pins[index - 1], pin)) return error.InvalidStackDependency;
    }
    const members = try a.alloc(Member, pins.len);
    for (members, pins) |*member, pin| member.* = .{ .pin = pin, .diff_base = pin.baseRefOid };
    var stacks: std.ArrayList(Stack) = .empty;
    var local_count: usize = 1;
    for (entry.stacks) |item| {
        if (!item.automatic or item.native != null) {
            try stacks.append(a, item);
            if (item.native == null) local_count += 1;
        }
    }
    try stacks.append(a, .{ .name = name, .members = members });
    for (entry.stacks) |item| {
        if (local_count >= max_stacks) break;
        if (!item.automatic or item.native != null) continue;
        for (item.members) |member| {
            if (std.mem.indexOfScalar(u32, numbers_buffer[0..pins.len], member.pin.number) != null) break;
        } else {
            try stacks.append(a, item);
            local_count += 1;
        }
    }
    for (pins) |pin| try entry.queue(a, pin.pull(), null);
    entry.stacks = stacks.items;
}

pub fn remove(entry: *core.Entry, a: io.A, name: []const u8) !void {
    const index = named(entry.stacks, name) orelse return error.UnknownStack;
    entry.stacks = try std.mem.concat(a, Stack, &.{ entry.stacks[0..index], entry.stacks[index + 1 ..] });
}

pub fn linked(repo: []const u8, before: Pin, after: Pin) bool {
    const head_repo = before.headRepository orelse return false;
    return std.ascii.eqlIgnoreCase(repo, head_repo.nameWithOwner) and
        io.eq(u8, before.headRefName, after.baseRefName) and io.eq(u8, before.headRefOid, after.baseRefOid);
}

pub fn samePin(before: Pin, after: Pin) bool {
    const same_head_repo = if (before.headRepository) |repository|
        if (after.headRepository) |other| std.ascii.eqlIgnoreCase(repository.nameWithOwner, other.nameWithOwner) else false
    else
        after.headRepository == null;
    return before.number == after.number and before.state == after.state and
        sameRef(before.nativeStack, after.nativeStack) and
        io.eq(u8, before.headRefOid, after.headRefOid) and io.eq(u8, before.baseRefOid, after.baseRefOid) and
        io.eq(u8, before.headRefName, after.headRefName) and io.eq(u8, before.baseRefName, after.baseRefName) and same_head_repo;
}

pub fn sameRef(before: ?NativeRef, after: ?NativeRef) bool {
    const left = before orelse return after == null;
    const right = after orelse return false;
    return left.number == right.number and io.eq(u8, left.id, right.id);
}

const BranchPin = struct { name: []const u8, oid: []const u8 };
const BranchContext = struct {
    pub fn hash(_: BranchContext, pin: BranchPin) u64 {
        var digest = std.hash.Wyhash.init(0);
        digest.update(pin.name);
        digest.update(pin.oid);
        return digest.final();
    }

    pub fn eql(_: BranchContext, before: BranchPin, after: BranchPin) bool {
        return io.eq(u8, before.name, after.name) and io.eq(u8, before.oid, after.oid);
    }
};

const Node = struct {
    pin: Pin,
    parent: ?usize = null,
    child: ?usize = null,
    branched: bool = false,
    ambiguous: bool = false,
};

pub fn autogroup(entry: *core.Entry, a: io.A, pulls: []const core.Pull) !void {
    var groups: std.ArrayList(Stack) = .empty;
    var local_count: usize = 0;
    for (entry.stacks) |item| {
        if (!item.automatic or item.native != null) {
            try groups.append(a, item);
            if (item.native == null) local_count += 1;
        }
    }
    if (local_count == max_stacks) {
        entry.stacks = groups.items;
        return;
    }
    var pending: std.HashMapUnmanaged(core.Seen, void, core.SeenContext, std.hash_map.default_max_load_percentage) = .empty;
    defer pending.deinit(a);
    for (entry.jobs) |job| {
        if (job.phase != .complete) try pending.put(a, .{ .number = job.number, .head = job.head }, {});
    }
    var nodes: std.ArrayList(Node) = .empty;
    for (pulls) |pr| {
        const pin = Pin.fromOpen(pr) orelse continue;
        try nodes.append(a, .{
            .pin = pin,
            .ambiguous = pin.nativeStack != null or inNative(entry.stacks, pin.number) or inExplicit(entry.stacks, pin.number),
        });
    }
    var heads: std.HashMapUnmanaged(BranchPin, usize, BranchContext, std.hash_map.default_max_load_percentage) = .empty;
    defer heads.deinit(a);
    var identities: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer identities.deinit(a);
    for (nodes.items, 0..) |*node, index| {
        const identity = try identities.getOrPut(a, node.pin.number);
        if (identity.found_existing) {
            node.ambiguous = true;
            nodes.items[identity.value_ptr.*].ambiguous = true;
        } else identity.value_ptr.* = index;
        const repository = node.pin.headRepository orelse continue;
        if (!std.ascii.eqlIgnoreCase(entry.repo.name, repository.nameWithOwner)) continue;
        const head = try heads.getOrPut(a, .{ .name = node.pin.headRefName, .oid = node.pin.headRefOid });
        if (head.found_existing) {
            node.ambiguous = true;
            nodes.items[head.value_ptr.*].ambiguous = true;
        } else head.value_ptr.* = index;
    }
    for (nodes.items, 0..) |*node, index| {
        const parent_index = heads.get(.{ .name = node.pin.baseRefName, .oid = node.pin.baseRefOid }) orelse continue;
        node.parent = parent_index;
        const parent = &nodes.items[parent_index];
        if (parent.child != null) parent.branched = true;
        parent.child = index;
    }
    var idle: [max_stacks]Stack = undefined;
    var idle_count: usize = 0;
    roots: for (nodes.items, 0..) |root, index| {
        if (local_count == max_stacks) break;
        if (root.parent != null) continue;
        var chain: [max_members]Member = undefined;
        const merged = mergedPrefix(entry.stacks, root.pin.number);
        @memcpy(chain[0..merged.len], merged);
        var count = merged.len;
        var active = false;
        var next: ?usize = index;
        while (next) |current| {
            const node = nodes.items[current];
            if (node.ambiguous or node.branched or count == max_members) continue :roots;
            chain[count] = retainedMember(entry.stacks, node.pin, chain[0..count]);
            active = active or pending.contains(.{ .number = node.pin.number, .head = node.pin.headRefOid });
            count += 1;
            next = node.child;
        }
        if (count < 2 or (!active and idle_count == max_stacks)) continue;
        const item: Stack = .{
            .name = try io.fmt(a, "auto-{d}", .{chain[0].pin.number}),
            .automatic = true,
            .members = try a.dupe(Member, chain[0..count]),
        };
        if (active) {
            try groups.append(a, item);
            local_count += 1;
        } else {
            idle[idle_count] = item;
            idle_count += 1;
        }
    }
    try groups.appendSlice(a, idle[0..@min(idle_count, max_stacks - local_count)]);
    entry.stacks = groups.items;
}

fn mergedPrefix(stacks: []const Stack, number: u32) []const Member {
    const position = find(stacks, number) orelse return &.{};
    const item = stacks[position.stack_index];
    if (!item.automatic) return &.{};
    const prefix = item.members[0..position.member_index];
    for (prefix) |ancestor| {
        if (ancestor.pin.state != .MERGED) return &.{};
    }
    return prefix;
}

fn retainedMember(stacks: []const Stack, pin: Pin, ancestry: []const Member) Member {
    const position = find(stacks, pin.number) orelse return .{ .pin = pin, .diff_base = pin.baseRefOid };
    const item = stacks[position.stack_index];
    var member = item.members[position.member_index];
    if (!samePin(member.pin, pin)) return .{ .pin = pin, .diff_base = pin.baseRefOid };
    const previous = item.members[0..position.member_index];
    if (!sameAncestry(previous, ancestry)) {
        if (member.digest) |*digest| digest.findings = "";
    }
    return member;
}

fn sameAncestry(before: []const Member, after: []const Member) bool {
    if (before.len != after.len) return false;
    for (before, after) |left, right| {
        if (!samePin(left.pin, right.pin)) return false;
    }
    return true;
}

pub fn numbers(a: io.A, stacks: []const Stack) ![]u32 {
    var count: usize = 0;
    var list: std.ArrayList(u32) = .empty;
    for (stacks) |item| {
        if (item.native != null) continue;
        count += 1;
        if (count > max_stacks) return error.StackLimit;
        if (item.members.len < 2 or item.members.len > max_members) return error.InvalidStackSize;
        for (item.members) |member| try list.append(a, member.pin.number);
    }
    return list.items;
}

pub fn refresh(entry: *core.Entry, a: io.A, observed: []const Pin) !void {
    var expected: usize = 0;
    for (entry.stacks) |item| {
        if (item.native != null) continue;
        for (item.members) |member| {
            if (expected == observed.len or member.pin.number != observed[expected].number or !observed[expected].valid())
                return error.StackObservationMismatch;
            expected += 1;
        }
    }
    if (expected != observed.len) return error.StackObservationMismatch;
    var offset: usize = 0;
    for (entry.stacks) |item| {
        if (item.native != null) continue;
        var prefix_changed = false;
        for (item.members) |*member| {
            const updated = observed[offset];
            offset += 1;
            if (prefix_changed) {
                if (member.digest) |*digest| digest.findings = "";
            }
            if (samePin(member.pin, updated)) {
                member.pin = updated;
                if (prefix_changed) try refreshJob(entry, a, updated, item.automatic);
                continue;
            }
            prefix_changed = true;
            if (updated.state != .MERGED or !io.eq(u8, member.pin.headRefOid, updated.headRefOid)) {
                member.digest = null;
                member.diff_base = updated.baseRefOid;
            }
            member.pin = updated;
            try refreshJob(entry, a, updated, item.automatic);
        }
    }
}

fn nativeItem(entry: *core.Entry, a: io.A, group: NativeGroup) !Stack {
    var previous: []const Member = &.{};
    for (entry.stacks) |item| {
        if (sameRef(item.native, group.ref)) {
            previous = item.members;
            break;
        }
    }
    var indices: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer indices.deinit(a);
    for (previous, 0..) |member, index| try indices.put(a, member.pin.number, index);
    const members = try a.alloc(Member, group.pins.len);
    var prefix_changed = false;
    for (members, group.pins, 0..) |*member, pin, index| {
        member.* = .{ .pin = pin, .diff_base = pin.baseRefOid };
        if (indices.get(pin.number)) |old_index| {
            const old = previous[old_index];
            const unchanged = samePin(old.pin, pin);
            if (unchanged or (pin.state == .MERGED and io.eq(u8, old.pin.headRefOid, pin.headRefOid))) {
                member.diff_base = old.diff_base;
                member.digest = old.digest;
            }
            if (prefix_changed or old_index != index) {
                if (member.digest) |*digest| digest.findings = "";
            }
            prefix_changed = prefix_changed or old_index != index or !unchanged;
            if (prefix_changed) try refreshJob(entry, a, pin, true);
        } else {
            prefix_changed = true;
        }
    }
    return .{
        .name = try io.fmt(a, "github-{d}", .{group.ref.number}),
        .automatic = true,
        .native = group.ref,
        .members = members,
    };
}

pub fn syncNative(entry: *core.Entry, a: io.A, discovered: []const NativeGroup) !void {
    // Validate the complete observation before changing persisted work. A
    // concurrent re-stack must not assign a PR to two different stacks.
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(a);
    for (discovered) |group| {
        if (group.pins.len == 0) return error.GitHubStackChanged;
        for (group.pins) |pin| {
            const slot = try seen.getOrPut(a, pin.number);
            if (slot.found_existing or !pin.valid() or !sameRef(pin.nativeStack, group.ref))
                return error.GitHubStackChanged;
        }
    }
    var groups: std.ArrayList(Stack) = .empty;
    for (discovered) |group| try groups.append(a, try nativeItem(entry, a, group));
    for (entry.stacks) |item| {
        if (item.native != null) continue;
        for (item.members) |member| {
            if (seen.contains(member.pin.number)) break;
        } else try groups.append(a, item);
    }
    entry.stacks = groups.items;
}

pub fn queueActiveNativeMembers(entry: *core.Entry, a: io.A) !void {
    for (entry.stacks) |item| {
        if (item.native == null) continue;
        const active = for (item.members) |member| {
            if (!member.pin.reviewable()) continue;
            const job = matchingJob(entry.jobs, member.pin) orelse continue;
            if (job.schedulable()) break true;
        } else false;
        if (!active) continue;

        for (item.members) |member| {
            const pin = member.pin;
            if (!pin.reviewable() or matchingJob(entry.jobs, pin) != null) continue;
            // Discovery applies the normal eligibility filters before recording
            // these heads, including exclusions for managed followups.
            for (entry.seen) |pull| {
                if (pull.number == pin.number and io.eq(u8, pull.head, pin.headRefOid)) {
                    try entry.queue(a, pin.pull(), null);
                    break;
                }
            }
        }
    }
}

pub fn queueNative(entry: *core.Entry, a: io.A, group: NativeGroup, options: ?core.ReviewOptions, rerun_completed: bool) !usize {
    var count: usize = 0;
    for (group.pins) |pin| {
        if (pin.reviewable()) count += 1;
    }
    if (count == 0) return error.NoOpenStackMembers;
    var groups: std.ArrayList(NativeGroup) = .empty;
    try groups.append(a, group);
    for (entry.stacks) |item| {
        const identity = item.native orelse continue;
        if (sameRef(identity, group.ref)) continue;
        const pins = try a.alloc(Pin, item.members.len);
        for (pins, item.members) |*pin, member| pin.* = member.pin;
        for (pins) |pin| {
            for (group.pins) |queued| {
                if (queued.number == pin.number) break;
            } else continue;
            break;
        } else try groups.append(a, .{ .ref = identity, .pins = pins });
    }
    try syncNative(entry, a, groups.items);
    for (group.pins) |pin| {
        if (!pin.reviewable()) continue;
        if (options == null and !rerun_completed) {
            if (matchingJob(entry.jobs, pin)) |job| {
                if (job.phase == .complete or (job.phase == .pending and job.attempts == 0)) continue;
            }
        }
        try entry.queueReview(a, pin.pull(), options, rerun_completed);
    }
    return count;
}

fn refreshJob(entry: *core.Entry, a: io.A, pin: Pin, automatic: bool) !void {
    if (!pin.reviewable()) return;
    if (matchingJob(entry.jobs, pin)) |job| {
        if (job.phase == .uncertain) return;
    } else if (automatic) return;
    try entry.queue(a, pin.pull(), null);
}

const fixture_repo = core.Repo{ .name = "example/repo", .login = "author" };
const root_head = "1111111111111111111111111111111111111111";
const parent_head = "2222222222222222222222222222222222222222";
const child_head = "3333333333333333333333333333333333333333";
const updated_head = "4444444444444444444444444444444444444444";
const child_base = "5555555555555555555555555555555555555555";

const fixture_parent: Pin = .{
    .number = 11,
    .headRefOid = parent_head,
    .baseRefOid = root_head,
    .headRefName = "parent",
    .baseRefName = "main",
    .headRepository = .{ .nameWithOwner = "example/repo" },
    .state = .OPEN,
    .isDraft = false,
};
const fixture_child: Pin = .{
    .number = 12,
    .headRefOid = child_head,
    .baseRefOid = parent_head,
    .headRefName = "child",
    .baseRefName = "parent",
    .headRepository = .{ .nameWithOwner = "example/repo" },
    .state = .OPEN,
    .isDraft = false,
};

test "a dependent PR inherits maximum depth only from a reviewed matching ancestor" {
    const t = std.testing;
    var parent = fixture_parent;
    var pins = [_]Pin{ parent, fixture_child };
    const context: Context = .{ .pins = &pins };
    var job: core.Job = .{
        .number = parent.number,
        .head = parent.headRefOid,
        .phase = .complete,
        .review_input = .{ .base = .fromPull(parent.pull()), .merge_base = parent.baseRefOid, .discussion = @splat(0) },
        .route_report = .{ .mode = .adaptive, .suggested = .{}, .applied = .{}, .providers = &.{.codex}, .screen_ms = 0, .review_ms = 0, .all_models = true },
    };
    try t.expect(inheritsAllModels(context, &.{job}));
    job.phase = .pending;
    try t.expect(!inheritsAllModels(context, &.{job}));
    job.phase = .complete;
    pins[0].baseRefOid = child_head;
    try t.expect(!inheritsAllModels(context, &.{job}));
    parent.state = .MERGED;
    pins[0] = parent;
    try t.expect(!inheritsAllModels(context, &.{job}));
}

test "explicit all-model requeue preserves same-head receipt safety and is idempotent" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry: core.Entry = .{ .repo = fixture_repo };
    const pr = fixture_parent.pull();
    const options: core.ReviewOptions = .{ .all_models = true };
    try entry.queue(a, pr, null);
    const job = &entry.jobs[0];
    job.phase = .uncertain;
    job.receipt = 42;
    try t.expectError(error.PublicationUnconfirmed, entry.queue(a, pr, options));
    job.phase = .complete;
    try entry.queue(a, pr, options);
    try t.expectEqual(core.Phase.pending, job.phase);
    try t.expect(job.followup and job.options.all_models);
    try t.expectEqual(@as(?u64, 42), job.receipt);
    const id = job.followup_id;
    job.phase = .complete;
    try entry.queue(a, pr, options);
    try t.expectEqual(core.Phase.complete, job.phase);
    try t.expectEqual(id, job.followup_id);

    try entry.queueReview(a, pr, options, true);
    try t.expectEqual(core.Phase.pending, job.phase);
    try t.expect(job.followup and job.options.all_models);
    try t.expectEqual(@as(?u64, 42), job.receipt);
    try t.expect(!io.eq(u8, &id, &job.followup_id));
    const rerun_id = job.followup_id;
    job.route_progress = .{ .fingerprint = @splat(1), .all_models = true };
    try entry.queueReview(a, pr, options, true);
    try t.expectEqual(rerun_id, job.followup_id);
    try t.expect(job.route_progress != null);
    job.phase = .uncertain;
    try t.expectError(error.PublicationUnconfirmed, entry.queueReview(a, pr, options, true));
    try t.expectEqual(@as(?u64, 42), job.receipt);
}

test "switching focus on a reviewed stack preserves receipts and identical requests keep progress" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry: core.Entry = .{ .repo = fixture_repo };
    const ref: NativeRef = .{ .id = "native-stack", .number = 89 };
    var pins = [_]Pin{ fixture_parent, fixture_child };
    for (&pins) |*pin| pin.nativeStack = ref;
    const group: NativeGroup = .{ .ref = ref, .pins = &pins };
    const security: core.ReviewOptions = .{ .focus = .@"security-maxxing", .explicit_mode = true, .all_models = true };
    const perf: core.ReviewOptions = .{ .focus = .@"perf-maxxing", .explicit_mode = true };
    try t.expectEqual(@as(usize, 2), try queueNative(&entry, a, group, security, false));
    const job = &entry.jobs[0];
    job.phase = .complete;
    job.receipt = 42;
    try entry.queue(a, pins[0].pull(), security);
    try t.expectEqual(core.Phase.complete, job.phase);

    try t.expectEqual(@as(usize, 2), try queueNative(&entry, a, group, perf, false));
    try t.expectEqual(core.Phase.pending, job.phase);
    try t.expectEqual(perf, job.options);
    try t.expectEqual(perf, entry.jobs[1].options);
    try t.expect(job.followup);
    try t.expectEqual(@as(?u64, 42), job.receipt);
    const id = job.followup_id;
    job.route_progress = .{ .fingerprint = @splat(1) };
    _ = try queueNative(&entry, a, group, perf, false);
    try t.expectEqual(id, job.followup_id);
    try t.expect(job.route_progress != null);

    job.phase = .uncertain;
    try t.expectError(error.PublicationUnconfirmed, queueNative(&entry, a, group, security, false));
    try t.expectEqual(@as(?u64, 42), job.receipt);
}

test "stack registration checks order and blocks the child on a failed parent across restart" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = core.Entry{ .repo = fixture_repo };
    try t.expectError(error.InvalidStackDependency, register(&entry, a, "reverse", &.{ fixture_child, fixture_parent }));
    try t.expectError(error.StackMemberAlreadyListed, register(&entry, a, "duplicate", &.{ fixture_parent, fixture_parent }));
    try register(&entry, a, "feature", &.{ fixture_parent, fixture_child });
    try t.expectEqual(@as(usize, 2), entry.jobs.len);
    try t.expect(!blocked(entry, entry.jobs[0]));
    try t.expect(blocked(entry, entry.jobs[1]));
    entry.jobs[0].phase = .failed;
    const state = try io.json(a, entry);
    entry = try io.parse(a, core.Entry, state);
    try t.expect(blocked(entry, entry.jobs[1]));
    const report = try statuses(a, entry);
    try t.expectEqual(@as(u32, 11), report[0].members[1].blocked_by.?.number);
    entry.jobs[0].phase = .complete;
    try t.expect(!blocked(entry, entry.jobs[1]));
}

test "draft descendants wait for review and readiness alone preserves stack results" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = core.Entry{ .repo = fixture_repo };
    var parent = fixture_parent;
    parent.isDraft = true;
    var child = fixture_child;
    child.isDraft = true;
    try register(&entry, a, "drafts", &.{ parent, child });
    try t.expect(!blocked(entry, entry.jobs[0]));
    try t.expect(blocked(entry, entry.jobs[1]));
    entry.jobs[0].phase = .complete;
    entry.jobs[0].awaiting_ready = true;
    parent.isDraft = false;
    try refresh(&entry, a, &.{ parent, child });
    try t.expectEqual(.complete, entry.jobs[0].phase);
    try t.expect(entry.jobs[0].awaiting_ready);
    try t.expect(!blocked(entry, entry.jobs[1]));
    const report = try statuses(a, entry);
    try t.expect(!report[0].members[0].is_draft);
    try t.expect(report[0].members[1].is_draft);
}

test "moving and merging ancestors invalidate descendant local results without losing receipts" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = core.Entry{ .repo = fixture_repo };
    try register(&entry, a, "feature", &.{ fixture_parent, fixture_child });
    entry.jobs[0].phase = .complete;
    entry.jobs[1].phase = .complete;
    entry.stacks[0].members[1].digest = .{ .diff = "exact diff", .findings = "formerly checked" };
    var moved = fixture_parent;
    moved.headRefOid = updated_head;
    var retargeted = fixture_child;
    retargeted.baseRefOid = updated_head;
    try t.expectError(error.StackObservationMismatch, refresh(&entry, a, &.{retargeted}));
    try t.expectEqualStrings(parent_head, entry.stacks[0].members[0].pin.headRefOid);
    try refresh(&entry, a, &.{ moved, retargeted });
    try t.expectEqual(core.Phase.pending, entry.jobs[1].phase);
    try t.expect(blocked(entry, entry.jobs[1]));
    try t.expect(entry.stacks[0].members[1].digest == null);
    entry.jobs[1].phase = .complete;
    entry.jobs[1].receipt = 42;
    entry.stacks[0].members[0].digest = .{ .diff = "pinned parent", .findings = "parent notes" };
    entry.stacks[0].members[1].digest = .{ .diff = "child diff", .findings = "old ancestry" };
    moved.state = .MERGED;
    moved.baseRefOid = child_base;
    try refresh(&entry, a, &.{ moved, retargeted });
    try t.expectEqualStrings(root_head, entry.stacks[0].members[0].diff_base);
    try t.expectEqualStrings("pinned parent", entry.stacks[0].members[0].digest.?.diff);
    try t.expectEqualStrings("", entry.stacks[0].members[1].digest.?.findings);
    try t.expectEqual(@as(?u64, 42), entry.jobs[1].receipt);
    try t.expect(!blocked(entry, entry.jobs[1]));
}

test "an inferred child can use a baselined ancestor without queueing a new review" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = core.Entry{ .repo = fixture_repo };
    try entry.discover(a, &.{fixture_parent.pull()}, true);
    try autogroup(&entry, a, &.{fixture_parent.pull()});
    try t.expectEqual(@as(usize, 0), entry.jobs.len);
    const ready = [_]core.Pull{ fixture_child.pull(), fixture_parent.pull() };
    try entry.discover(a, &ready, false);
    try autogroup(&entry, a, &ready);
    try t.expectEqual(@as(usize, 1), entry.jobs.len);
    try t.expect(entry.stacks[0].automatic);
    try t.expectEqual(@as(u32, 11), entry.stacks[0].members[0].pin.number);
    try t.expectEqual(@as(u32, 12), entry.stacks[0].members[1].pin.number);
    try t.expect(!blocked(entry, entry.jobs[0]));
    try entry.queue(a, fixture_parent.pull(), null);
    entry.jobs[1].phase = .failed;
    try t.expect(blocked(entry, entry.jobs[0]));
    try register(&entry, a, "explicit", &.{ fixture_parent, fixture_child });
    try autogroup(&entry, a, &ready);
    try t.expectEqual(@as(usize, 1), entry.stacks.len);
    try t.expect(!entry.stacks[0].automatic);
    try t.expectEqualStrings("explicit", entry.stacks[0].name);
}

test "inference leaves forks, duplicate heads, and split edges ordinary" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = core.Entry{ .repo = fixture_repo };
    var other_child = fixture_child;
    other_child.number = 13;
    other_child.headRefName = "sibling";
    other_child.headRefOid = updated_head;
    try autogroup(&entry, a, &.{ fixture_parent.pull(), fixture_child.pull(), other_child.pull() });
    try t.expectEqual(@as(usize, 0), entry.stacks.len);
    var other_parent = fixture_parent;
    other_parent.number = 14;
    other_parent.baseRefName = "other-base";
    try autogroup(&entry, a, &.{ fixture_parent.pull(), fixture_child.pull(), other_parent.pull() });
    try t.expectEqual(@as(usize, 0), entry.stacks.len);
    var forked_parent = fixture_parent;
    forked_parent.headRepository = .{ .nameWithOwner = "outside/repo" };
    try autogroup(&entry, a, &.{ forked_parent.pull(), fixture_child.pull() });
    try t.expectEqual(@as(usize, 0), entry.stacks.len);
}

test "active inferred chains take stack slots before idle baselines" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = core.Entry{ .repo = fixture_repo };
    var pulls: [(max_stacks + 1) * 2]core.Pull = undefined;
    for (0..max_stacks + 1) |index| {
        var parent = fixture_parent.pull();
        parent.number = @intCast(100 + index * 2);
        parent.headRefName = try io.fmt(a, "parent-{d}", .{index});
        var child = fixture_child.pull();
        child.number = parent.number + 1;
        child.baseRefName = parent.headRefName;
        child.headRefName = try io.fmt(a, "child-{d}", .{index});
        pulls[index * 2] = parent;
        pulls[index * 2 + 1] = child;
    }
    try entry.discover(a, pulls[0 .. pulls.len - 1], true);
    try entry.discover(a, &pulls, false);
    try autogroup(&entry, a, &pulls);
    try t.expectEqual(@as(usize, max_stacks), entry.stacks.len);
    try t.expectEqual(pulls[pulls.len - 1].number, entry.stacks[0].members[1].pin.number);
    try t.expectEqual(@as(u32, 100), entry.stacks[1].members[0].pin.number);
    try t.expect(!blocked(entry, entry.jobs[0]));
}

test "inferred stacks retain merged ancestors and uncertain receipt backoff" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = core.Entry{ .repo = fixture_repo };
    const before = [_]core.Pull{ fixture_parent.pull(), fixture_child.pull() };
    try entry.discover(a, &before, true);
    try autogroup(&entry, a, &before);
    try entry.queue(a, fixture_child.pull(), null);
    entry.jobs[0].phase = .uncertain;
    entry.jobs[0].attempts = 4;
    entry.jobs[0].next = 1234;
    entry.jobs[0].receipt = 42;
    entry.jobs[0].event = .COMMENT;
    var merged = fixture_parent;
    merged.state = .MERGED;
    merged.baseRefOid = child_base;
    var retargeted = fixture_child;
    retargeted.baseRefOid = child_base;
    retargeted.baseRefName = "main";
    const after = [_]core.Pull{retargeted.pull()};
    try entry.discover(a, &after, false);
    try refresh(&entry, a, &.{ merged, retargeted });
    try autogroup(&entry, a, &after);
    try t.expectEqual(@as(usize, 1), entry.stacks.len);
    try t.expectEqualStrings(root_head, entry.stacks[0].members[0].diff_base);
    try t.expectEqual(@as(usize, 1), entry.jobs.len);
    try t.expectEqual(core.Phase.uncertain, entry.jobs[0].phase);
    try t.expectEqual(@as(u8, 4), entry.jobs[0].attempts);
    try t.expectEqual(@as(i64, 1234), entry.jobs[0].next);
    try t.expectEqual(@as(?u64, 42), entry.jobs[0].receipt);
    try t.expect(!blocked(entry, entry.jobs[0]));
}

test "GitHub order is authoritative for a 26-member stack" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = core.Entry{ .repo = fixture_repo };
    const stack_ref = NativeRef{ .id = "PRS_example", .number = 23 };
    var pins: [26]Pin = undefined;
    var pulls: [25]core.Pull = undefined;
    for (&pins, 0..) |*pin, index| {
        pin.* = fixture_parent;
        pin.number = @intCast(1000 + index);
        pin.nativeStack = stack_ref;
        if (index > 0) {
            // The authoritative native positions survive even when branch
            // metadata cannot establish the same chain during a rebase.
            pin.headRefName = try io.fmt(a, "head-{d}", .{index});
            pin.baseRefName = "rebasing";
            pulls[index - 1] = pin.pull();
        } else {
            pin.state = .MERGED;
        }
    }
    const group: NativeGroup = .{ .ref = stack_ref, .pins = &pins };
    try entry.discover(a, &pulls, true);
    try syncNative(&entry, a, &.{group});
    try autogroup(&entry, a, &pulls);
    try t.expectEqual(@as(usize, 26), entry.stacks[0].members.len);
    try t.expectEqual(@as(usize, 0), entry.jobs.len);
    try t.expectEqual(@as(usize, 0), (try numbers(a, entry.stacks)).len);
    try entry.queue(a, pulls[24], null);
    try t.expect(!blocked(entry, entry.jobs[0]));
    const report = try statuses(a, entry);
    try t.expectEqual(@as(?u32, 23), report[0].native_number);
    try t.expectEqual(@as(u32, 1025), report[0].members[25].number);
    try t.expectEqual(@as(usize, 25), try queueNative(&entry, a, group, null, false));
    try t.expect(blocked(entry, entry.jobs[0]));
    try t.expect(!blocked(entry, entry.jobs[1]));
    pins[1].state = .MERGED;
    try syncNative(&entry, a, &.{group});
    try t.expect(!blocked(entry, entry.jobs[2]));
}

test "an active native stack queues missing open members and preserves saved work" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ref: NativeRef = .{ .id = "PRS_example", .number = 23 };
    var parent = fixture_parent;
    parent.nativeStack = ref;
    var child = fixture_child;
    child.nativeStack = ref;
    var draft = child;
    draft.number = 13;
    draft.isDraft = true;
    draft.headRefOid = updated_head;
    var unobserved = child;
    unobserved.number = 14;
    var pins = [_]Pin{ parent, child, draft, unobserved };
    const group: NativeGroup = .{ .ref = ref, .pins = &pins };
    var entry: core.Entry = .{ .repo = fixture_repo };
    try entry.discover(a, &.{ parent.pull(), child.pull(), draft.pull() }, true);
    try syncNative(&entry, a, &.{group});
    try queueActiveNativeMembers(&entry, a);
    try t.expectEqual(@as(usize, 0), entry.jobs.len);

    try entry.queue(a, child.pull(), null);
    entry.jobs[0].route_progress = .{ .fingerprint = @splat(42) };
    try queueActiveNativeMembers(&entry, a);
    try t.expectEqual(@as(usize, 3), entry.jobs.len);
    try t.expect(blocked(entry, matchingJob(entry.jobs, child).?));
    try t.expect(!blocked(entry, matchingJob(entry.jobs, parent).?));
    try t.expectEqual(core.Phase.pending, matchingJob(entry.jobs, draft).?.phase);
    try t.expect(matchingJob(entry.jobs, unobserved) == null);

    entry.jobs[1].phase = .complete;
    try queueActiveNativeMembers(&entry, a);
    try t.expectEqual(@as(usize, 3), entry.jobs.len);
    try t.expectEqual(core.Phase.complete, matchingJob(entry.jobs, parent).?.phase);
    try t.expectEqual(@as(u8, 42), matchingJob(entry.jobs, child).?.route_progress.?.fingerprint[0]);
    try t.expect(!blocked(entry, matchingJob(entry.jobs, child).?));
}

pub const Block = struct { number: u32, reason: []const u8 };

fn matchingJob(jobs: []const core.Job, pin: Pin) ?core.Job {
    for (jobs) |job| {
        if (job.number == pin.number and io.eq(u8, job.head, pin.headRefOid)) return job;
    }
    return null;
}

pub fn blocker(entry: core.Entry, item: Stack, index: usize) ?Block {
    for (item.members[0 .. index + 1], 0..) |member, member_index| {
        const pin = member.pin;
        if (pin.state == .MERGED and member_index < index) continue;
        if (!pin.reviewable()) return .{ .number = pin.number, .reason = "not open" };
        if (member_index > 0 and item.native == null) {
            const before = item.members[member_index - 1].pin;
            if (before.state != .MERGED and !linked(entry.repo.name, before, pin))
                return .{ .number = pin.number, .reason = "base is not the previous PR head" };
        }
        if (member_index < index) {
            const complete = if (matchingJob(entry.jobs, pin)) |job| job.phase == .complete else item.automatic;
            if (!complete) return .{ .number = pin.number, .reason = "ancestor review pending or failed" };
        }
    }
    return null;
}

pub fn blocked(entry: core.Entry, job: core.Job) bool {
    if (job.phase == .uncertain) return false;
    const position = find(entry.stacks, job.number) orelse return false;
    const item = entry.stacks[position.stack_index];
    const member = item.members[position.member_index];
    return !io.eq(u8, member.pin.headRefOid, job.head) or blocker(entry, item, position.member_index) != null;
}

pub const MemberStatus = struct {
    number: u32,
    head: []const u8,
    base: []const u8,
    state: []const u8,
    is_draft: bool,
    review: []const u8,
    blocked_by: ?Block = null,
};

pub const Status = struct { name: []const u8, automatic: bool, native_number: ?u32, members: []const MemberStatus };

pub fn statuses(a: io.A, entry: core.Entry) ![]Status {
    const result = try a.alloc(Status, entry.stacks.len);
    for (result, entry.stacks) |*output, item| {
        const members = try a.alloc(MemberStatus, item.members.len);
        for (members, item.members, 0..) |*status, member, index| {
            const pin = member.pin;
            const blocked_by = if (pin.state == .MERGED) null else blocker(entry, item, index);
            const review = review: {
                for (entry.jobs) |job| {
                    if (job.number == pin.number and io.eq(u8, pin.headRefOid, job.head))
                        break :review @tagName(job.phase);
                }
                break :review "not queued";
            };
            status.* = .{
                .number = pin.number,
                .head = pin.headRefOid,
                .base = pin.baseRefOid,
                .state = @tagName(pin.state),
                .is_draft = pin.isDraft,
                .review = review,
                .blocked_by = blocked_by,
            };
        }
        output.* = .{ .name = item.name, .automatic = item.automatic, .native_number = if (item.native) |identity| identity.number else null, .members = members };
    }
    return result;
}
