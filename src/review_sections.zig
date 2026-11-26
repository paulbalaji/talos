const std = @import("std");

const bytes_per_section = 36 * 1024;
const max_sections = 8;

pub const Sections = struct {
    patches: []const []const u8,
    omitted: bool,
};

// Preserve whole Git hunks and repeat the file header when they span sections.
// Sections keep Git's priority order and never depend on another section for
// the file name or line numbers.
pub fn split(a: std.mem.Allocator, patch: []const u8) !Sections {
    var patches: std.ArrayList([]const u8) = .empty;
    var section: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    var file_header: []const u8 = "";
    var included_header = false;
    var omitted = false;
    while (offset < patch.len) {
        const start = offset;
        const file = std.mem.startsWith(u8, patch[start..], "diff --git ");
        offset = lineEnd(patch, offset);
        while (offset < patch.len and
            !std.mem.startsWith(u8, patch[offset..], "diff --git ") and
            !std.mem.startsWith(u8, patch[offset..], "@@ "))
        {
            offset = lineEnd(patch, offset);
        }
        const block = patch[start..offset];
        if (file) {
            file_header = block;
            included_header = false;
            if (std.mem.startsWith(u8, patch[offset..], "@@ ")) continue;
        }
        const header = if (file or included_header) "" else file_header;
        if (header.len + block.len > bytes_per_section or !std.unicode.utf8ValidateSlice(block) or !std.unicode.utf8ValidateSlice(header)) {
            omitted = true;
            continue;
        }
        if (section.items.len + header.len + block.len > bytes_per_section) {
            try patches.append(a, try section.toOwnedSlice(a));
            if (patches.items.len == max_sections) return .{ .patches = patches.items, .omitted = true };
            included_header = false;
            if (!file) {
                if (file_header.len + block.len > bytes_per_section) {
                    omitted = true;
                    continue;
                }
                try section.appendSlice(a, file_header);
            }
        } else {
            try section.appendSlice(a, header);
        }
        try section.appendSlice(a, block);
        included_header = true;
    }
    if (section.items.len != 0) try patches.append(a, section.items);
    return .{ .patches = patches.items, .omitted = omitted };
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
    try t.expect(!sections.omitted);
    try t.expectEqual(@as(usize, 2), sections.patches.len);
    try t.expectEqualStrings(header ++ first, sections.patches[0]);
    try t.expectEqualStrings(header ++ last, sections.patches[1]);
}

test "a hunk above the cap is reported without hiding later files" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const last = "diff --git a/last b/last\n@@ -1 +1 @@\n-last\n+first\n";
    const sections = try split(arena.allocator(), "diff --git a/big b/big\n@@ -1 +1 @@\n+" ++ "x" ** bytes_per_section ++ "\n" ++ last);
    try t.expect(sections.omitted);
    try t.expectEqual(@as(usize, 1), sections.patches.len);
    try t.expectEqualStrings(last, sections.patches[0]);
}
