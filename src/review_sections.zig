const std = @import("std");

pub const bytes_per_section = 36 * 1024;
const max_hunk_bytes = 52 * 1024;
const max_sections = 10;

pub const Sections = struct {
    parts: []const Part,
    total_units: usize,
    included_units: usize,

    pub fn omitted(self: Sections) bool {
        return self.included_units != self.total_units;
    }
};

pub const Part = struct { patch: []const u8, units: usize };

const Block = struct { start: usize, end: usize, file: bool, header_only: bool };

fn nextBlock(patch: []const u8, offset: *usize) ?Block {
    const start = offset.*;
    if (start == patch.len) return null;
    const file = std.mem.startsWith(u8, patch[start..], "diff --git ");
    offset.* = lineEnd(patch, start);
    while (offset.* < patch.len and
        !std.mem.startsWith(u8, patch[offset.*..], "diff --git ") and
        !std.mem.startsWith(u8, patch[offset.*..], "@@ "))
    {
        offset.* = lineEnd(patch, offset.*);
    }
    return .{ .start = start, .end = offset.*, .file = file, .header_only = file and std.mem.startsWith(u8, patch[offset.*..], "@@ ") };
}

pub const Counts = struct { total_units: usize, included_units: usize };

// A unit is one hunk or a file change with metadata and no hunks.
pub fn countUnits(patch: []const u8, end: usize) Counts {
    var counts: Counts = .{ .total_units = 0, .included_units = 0 };
    var offset: usize = 0;
    while (nextBlock(patch, &offset)) |block| {
        if (block.header_only) continue;
        counts.total_units += 1;
        counts.included_units += @intFromBool(block.end <= end);
    }
    return counts;
}

// Preserve whole Git hunks and repeat the file header when they span sections.
// Sections keep Git's priority order and never depend on another section for
// the file name or line numbers.
pub fn split(a: std.mem.Allocator, patch: []const u8) !Sections {
    var parts: std.ArrayList(Part) = .empty;
    var section: std.ArrayList(u8) = .empty;
    var counts: Counts = .{ .total_units = 0, .included_units = 0 };
    var section_units: usize = 0;
    var offset: usize = 0;
    var file_header: []const u8 = "";
    var included_header = false;
    while (nextBlock(patch, &offset)) |item| {
        const block = patch[item.start..item.end];
        if (item.file) {
            file_header = block;
            included_header = false;
            if (item.header_only) continue;
        }
        counts.total_units += 1;
        if (parts.items.len == max_sections) continue;
        const standalone_header = if (item.file) "" else file_header;
        const header = if (included_header) "" else standalone_header;
        if (standalone_header.len + block.len > max_hunk_bytes or !std.unicode.utf8ValidateSlice(block) or !std.unicode.utf8ValidateSlice(standalone_header)) {
            continue;
        }
        // Give a large hunk its own section. The planner still checks its
        // encoded prompt against the context budget before a reviewer starts.
        if (section.items.len != 0 and section.items.len + header.len + block.len > bytes_per_section) {
            try parts.append(a, .{ .patch = try section.toOwnedSlice(a), .units = section_units });
            section_units = 0;
            if (parts.items.len == max_sections) continue;
            try section.appendSlice(a, standalone_header);
        } else {
            try section.appendSlice(a, header);
        }
        try section.appendSlice(a, block);
        section_units += 1;
        counts.included_units += 1;
        included_header = true;
    }
    if (section.items.len != 0) try parts.append(a, .{ .patch = section.items, .units = section_units });
    return .{ .parts = parts.items, .total_units = counts.total_units, .included_units = counts.included_units };
}

fn lineEnd(patch: []const u8, offset: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, patch, offset, '\n')) |end| end + 1 else patch.len;
}

test "sections preserve late hunks and repeat their file headers" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const header = "diff --git a/file b/file\n--- a/file\n+++ b/file\n";
    const first = "@@ -100,1 +100,1 @@\n+first" ++ "x" ** 20000 ++ "\n";
    const last = "@@ -300,1 +300,1 @@\n+last" ++ "y" ** 20000 ++ "\n";
    const sections = try split(arena.allocator(), header ++ first ++ last);
    try t.expect(!sections.omitted());
    try t.expectEqual(@as(usize, 2), sections.parts.len);
    try t.expectEqual(@as(usize, 2), sections.total_units);
    try t.expectEqualStrings(header ++ first, sections.parts[0].patch);
    try t.expectEqualStrings(header ++ last, sections.parts[1].patch);
}

test "a hunk above the cap is reported without hiding later files" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const last = "diff --git a/last b/last\n@@ -1 +1 @@\n-last\n+first\n";
    const sections = try split(arena.allocator(), "diff --git a/big b/big\n@@ -1 +1 @@\n+" ++ "x" ** max_hunk_bytes ++ "\n" ++ last);
    try t.expect(sections.omitted());
    try t.expectEqual(@as(usize, 1), sections.parts.len);
    try t.expectEqual(@as(usize, 2), sections.total_units);
    try t.expectEqual(@as(usize, 1), sections.included_units);
    try t.expectEqualStrings(last, sections.parts[0].patch);
}

test "a large hunk gets its own section with intact line coordinates" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const header = "diff --git a/file b/file\n--- a/file\n+++ b/file\n";
    const first = "@@ -10 +10 @@\n+first\n";
    const middle = "@@ -70 +70 @@\n+" ++ "x" ** (47 * 1024) ++ "\n";
    const last = "@@ -300 +300 @@\n+last\n";
    const sections = try split(arena.allocator(), header ++ first ++ middle ++ last);
    try t.expect(!sections.omitted());
    try t.expectEqual(@as(usize, 3), sections.parts.len);
    try t.expectEqualStrings(header ++ first, sections.parts[0].patch);
    try t.expectEqualStrings(header ++ middle, sections.parts[1].patch);
    try t.expectEqualStrings(header ++ last, sections.parts[2].patch);
}

test "source plan counts clipped hunks and metadata separately" {
    const t = std.testing;
    const metadata = "diff --git a/x b/x\nold mode 100644\nnew mode 100755\n";
    const file = "diff --git a/y b/y\n--- a/y\n+++ b/y\n";
    const hunk = "@@ -1 +1 @@\n-old\n+new\n";
    const patch = metadata ++ file ++ hunk;
    try t.expectEqual(Counts{ .total_units = 2, .included_units = 1 }, countUnits(patch, patch.len - 2));
    try t.expectEqual(Counts{ .total_units = 2, .included_units = 2 }, countUnits(patch, patch.len));
}

test "the section budget records every remaining source unit" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = "diff --git a/a b/a\n--- a/a\n+++ b/a\n";
    const hunk = "@@ -1 +1 @@\n-old\n+" ++ "z" ** 30_000 ++ "\n";
    const patch = try std.mem.concat(a, u8, &.{ file, hunk ** (max_sections + 2) });
    const sections = try split(a, patch);
    try t.expectEqual(max_sections + 2, sections.total_units);
    try t.expectEqual(max_sections, sections.included_units);
    try t.expect(sections.omitted());
}
