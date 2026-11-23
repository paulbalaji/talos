const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");
const c = @cImport(@cInclude("unistd.h"));

pub const default_label = "dev.talos.watcher";

fn xml(a: io.A, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (input) |byte| {
        const escaped: ?[]const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            // XML 1.0 rejects these characters even in character references.
            0...8, 11, 12, 14...31 => return error.InvalidLaunchdValue,
            else => null,
        };
        if (escaped) |value| {
            try result.appendSlice(a, value);
        } else {
            try result.append(a, byte);
        }
    }
    return result.toOwnedSlice(a);
}

pub fn manage(cmd: io.Command, home: []const u8, path_env: []const u8, root: []const u8, label: []const u8, install: bool) !void {
    if (builtin.os.tag != .macos) return error.LaunchdRequiresMacOS;
    if (!std.mem.startsWith(u8, label, "dev.talos.") or label.len > 120) return error.InvalidSchedulerLabel;
    for (label) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-') return error.InvalidSchedulerLabel;
    }
    const a = cmd.a;
    const agents = try std.fs.path.join(a, &.{ home, "Library", "LaunchAgents" });
    try std.fs.cwd().makePath(agents);
    var dir = try std.fs.openDirAbsolute(agents, .{});
    defer dir.close();
    const name = try io.fmt(a, "{s}.plist", .{label});
    const full_path = try std.fs.path.join(a, &.{ agents, name });
    const domain = try io.fmt(a, "gui/{d}", .{c.getuid()});
    const service = try io.fmt(a, "{s}/{s}", .{ domain, label });
    const owner = try io.fmt(a, "<key>WorkingDirectory</key><string>{s}</string>", .{try xml(a, root)});
    const existing = dir.readFileAlloc(a, name, 128 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |data| {
        if (std.mem.indexOf(u8, data, owner) == null) return error.SchedulerOwnedByAnotherInstallation;
    }
    if (install) {
        if (existing != null) return error.SchedulerAlreadyInstalled;
        const self = try std.fs.selfExePathAlloc(a);
        const body = try io.fmt(a,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0"><dict>
            \\<key>Label</key><string>{s}</string>
            \\<key>ProgramArguments</key><array><string>{s}</string><string>--home</string><string>{s}</string><string>tick</string></array>
            \\{s}
            \\<key>RunAtLoad</key><true/>
            \\<key>StartInterval</key><integer>15</integer>
            \\<key>EnvironmentVariables</key><dict><key>PATH</key><string>{s}</string></dict>
            \\<key>StandardErrorPath</key><string>{s}/launchd.log</string>
            \\</dict></plist>
            \\
        , .{ label, try xml(a, self), try xml(a, root), owner, try xml(a, path_env), try xml(a, root) });
        try io.write(dir, name, body);
        errdefer dir.deleteFile(name) catch {};
        _ = cmd.run(&.{ "/bin/launchctl", "bootstrap", domain, full_path }, "", 15) catch
            return error.SchedulerBootstrapFailed;
        // An explicitly disabled label stays disabled across removal on macOS.
        errdefer _ = cmd.run(&.{ "/bin/launchctl", "bootout", service }, "", 15) catch "";
        _ = cmd.run(&.{ "/bin/launchctl", "print", service }, "", 15) catch return error.SchedulerVerificationFailed;
        try io.out("Installed {s}\n", .{service});
    } else {
        if (existing == null) return error.SchedulerNotInstalled;
        if (cmd.run(&.{ "/bin/launchctl", "print", service }, "", 15)) |_| {
            _ = cmd.run(&.{ "/bin/launchctl", "bootout", service }, "", 15) catch return error.SchedulerRemovalFailed;
        } else |err| {
            if (err != error.SubprocessFailed) return err;
        }
        try dir.deleteFile(name);
        try io.out("Removed {s}\n", .{service});
    }
}
