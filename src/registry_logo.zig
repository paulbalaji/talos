const std = @import("std");
const eql = std.mem.eql;
const trim = std.mem.trim;
const whitespace = " \t\r\n";

pub fn isLogo(path: []const u8) bool {
    const roots = [_][]const u8{ "chains/", "deployments/warp_routes/" };
    for (roots) |root| {
        if (!std.mem.startsWith(u8, path, root)) continue;
        const rest = path[root.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
        if (slash == 0) return false;
        for (rest[0..slash]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
        }
        const name = rest[slash + 1 ..];
        return eql(u8, name, "logo.svg") or eql(u8, name, "darkmode-logo.svg");
    }
    return false;
}

pub fn candidate(files: anytype, patch: []const u8) bool {
    if (files.len == 0 or files.len > 8) return false;
    var logos: usize = 0;
    var changesets: usize = 0;
    for (files) |file| {
        if (file.previous_filename != null) return false;
        if (isLogo(file.filename) and eql(u8, file.status, "modified")) {
            logos += 1;
        } else if (std.mem.startsWith(u8, file.filename, ".changeset/") and
            std.mem.endsWith(u8, file.filename, ".md") and eql(u8, file.status, "added"))
        {
            changesets += 1;
        } else return false;
    }
    if (logos == 0 or changesets > 1) return false;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    var headers: usize = 0;
    const prefix = "diff --git a/";
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "old mode ") or std.mem.startsWith(u8, line, "new mode ")) return false;
        if (!std.mem.startsWith(u8, line, "diff --git ")) continue;
        if (!std.mem.startsWith(u8, line, prefix)) return false;
        const paths = line[prefix.len..];
        const split = std.mem.indexOf(u8, paths, " b/") orelse return false;
        const path = paths[0..split];
        if (!eql(u8, path, paths[split + 3 ..])) return false;
        for (files) |file| {
            if (eql(u8, path, file.filename)) break;
        } else return false;
        headers += 1;
    }
    return headers == files.len;
}

pub fn patchChangeset(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!eql(u8, trim(u8, lines.next() orelse return false, whitespace), "---")) return false;
    const entry = trim(u8, lines.next() orelse return false, whitespace);
    if (!eql(u8, entry, "'@hyperlane-xyz/registry': patch") and !eql(u8, entry, "\"@hyperlane-xyz/registry\": patch")) return false;
    return eql(u8, trim(u8, lines.next() orelse return false, whitespace), "---");
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |allowed| if (eql(u8, name, allowed)) return true;
    return false;
}

fn plainValue(value: []const u8) bool {
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, " #.,%+-\t\r\n", c) == null) return false;
    return true;
}

fn simpleFillStyle(text: []const u8) bool {
    const body = trim(u8, text, whitespace);
    if (body.len == 0) return true;
    if (body[0] != '.' or body[body.len - 1] != '}') return false;
    const brace = std.mem.indexOfScalar(u8, body, '{') orelse return false;
    const selector = trim(u8, body[1..brace], whitespace);
    for (selector) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    const rule = trim(u8, body[brace + 1 .. body.len - 1], whitespace);
    if (!std.mem.startsWith(u8, rule, "fill:") or !std.mem.endsWith(u8, rule, ";")) return false;
    const color = trim(u8, rule[5 .. rule.len - 1], whitespace);
    if ((color.len != 4 and color.len != 7) or color[0] != '#') return false;
    for (color[1..]) |c| if (!std.ascii.isHex(c)) return false;
    return selector.len != 0;
}

// Route a small, passive SVG subset. The full reviewer still checks XML and
// geometry. Anything outside this subset gets the normal risk routing.
pub fn staticSvg(text: []const u8) bool {
    const xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
    var rest = trim(u8, text, whitespace);
    if (std.mem.startsWith(u8, rest, xml)) rest = trim(u8, rest[xml.len..], whitespace);
    if (!std.mem.startsWith(u8, rest, "<svg ") or !std.mem.endsWith(u8, rest, "</svg>")) return false;
    var in_style = false;
    while (std.mem.indexOfScalar(u8, rest, '<')) |left| {
        const content = trim(u8, rest[0..left], whitespace);
        if (content.len != 0 and (!in_style or !simpleFillStyle(content))) return false;
        const right = std.mem.indexOfScalarPos(u8, rest, left + 1, '>') orelse return false;
        var tag = trim(u8, rest[left + 1 .. right], whitespace);
        const closing = std.mem.startsWith(u8, tag, "/");
        if (closing) tag = tag[1..];
        const end = std.mem.indexOfAny(u8, tag, whitespace ++ "/") orelse tag.len;
        const name = tag[0..end];
        if (!containsName(&.{ "svg", "defs", "style", "g", "path", "polygon", "polyline", "rect", "circle", "ellipse", "line" }, name)) return false;
        if (in_style and (!closing or !eql(u8, name, "style"))) return false;
        in_style = !closing and eql(u8, name, "style");
        var attrs = trim(u8, tag[end..], whitespace);
        while (attrs.len != 0 and !eql(u8, attrs, "/")) {
            if (closing) return false;
            const sep = std.mem.indexOfScalar(u8, attrs, '=') orelse return false;
            const key = trim(u8, attrs[0..sep], whitespace);
            attrs = trim(u8, attrs[sep + 1 ..], whitespace);
            if (attrs.len < 2 or (attrs[0] != '\'' and attrs[0] != '"')) return false;
            const quote = std.mem.indexOfScalarPos(u8, attrs, 1, attrs[0]) orelse return false;
            const value = attrs[1..quote];
            if (eql(u8, key, "xmlns")) {
                if (!eql(u8, name, "svg") or !eql(u8, value, "http://www.w3.org/2000/svg")) return false;
            } else if (!containsName(&.{
                "id", "data-name", "class",   "viewBox", "width", "height", "fill", "stroke", "stroke-width", "fill-rule", "clip-rule",
                "d",  "points",    "x",       "y",       "x1",    "y1",     "x2",   "y2",     "cx",           "cy",        "r",
                "rx", "ry",        "opacity",
            }, key) or !plainValue(value)) return false;
            attrs = trim(u8, attrs[quote + 1 ..], whitespace);
        }
        rest = rest[right + 1 ..];
    }
    return !in_style and trim(u8, rest, whitespace).len == 0;
}

test "only pinned passive registry logo replacements qualify for the narrow review" {
    const t = std.testing;
    const LogoFile = @import("github.zig").File;
    const files = [_]LogoFile{ .{ .filename = "chains/aleo/logo.svg", .status = "modified" }, .{ .filename = ".changeset/logo.md", .status = "added" } };
    const headers = "diff --git a/chains/aleo/logo.svg b/chains/aleo/logo.svg\ndiff --git a/.changeset/logo.md b/.changeset/logo.md\n";
    try t.expect(candidate(&files, headers));
    try t.expect(!candidate(&files, headers ++ "diff --git a/src/consumer.ts b/src/consumer.ts\n"));
    try t.expect(!candidate(&files, headers ++ "old mode 100644\nnew mode 120000\n"));
    try t.expect(patchChangeset("---\n'@hyperlane-xyz/registry': patch\n---\n\nPad the logo.\n"));
    try t.expect(!patchChangeset("---\n'@hyperlane-xyz/registry': major\n---\n"));
    const open = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 80 80\">";
    try t.expect(staticSvg(open ++ "<defs><style>.cls-1 { fill: #fff; }</style></defs><polygon class=\"cls-1\" points=\"1 1 2 2 3 1\"/></svg>"));
    for ([_][]const u8{
        "<script>function f() {}</script>",
        "<use href=\"asset.svg\"/>",
        "<path onload=\"doSomething\"/>",
        "<path fill=\"url(#paint)\"/>",
        "<style>@import 'asset.css';</style>",
        "<foreignObject/>",
        "<!DOCTYPE svg>",
    }) |active| {
        const svg = try std.mem.concat(t.allocator, u8, &.{ open, active, "</svg>" });
        defer t.allocator.free(svg);
        try t.expect(!staticSvg(svg));
    }
}
