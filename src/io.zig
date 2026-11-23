const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
});

pub const A = std.mem.Allocator;
pub const eq = std.mem.eql;
pub const trim = std.mem.trim;
const output_limit = 32 * 1024 * 1024;

pub fn fmt(a: A, comptime pattern: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(a, pattern, args);
}

pub fn json(a: A, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}

pub fn parse(a: A, comptime T: type, input: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, input, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn out(comptime pattern: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try writer.interface.print(pattern, args);
    try writer.interface.flush();
}

pub fn temp(a: A) ![:0]const u8 {
    const template = try a.dupeZ(u8, "/tmp/talos-XXXXXX");
    if (c.mkdtemp(template.ptr) == null) return error.TempDirectory;
    return template;
}

pub fn write(dir: std.fs.Dir, name: []const u8, data: []const u8) !void {
    var file = try dir.atomicFile(name, .{ .mode = 0o600, .write_buffer = &.{} });
    defer file.deinit();
    try file.file_writer.file.writeAll(data);
    try file.file_writer.file.sync();
    try file.finish();
    // macOS filesystems can reject fsync on directory handles.
    _ = c.fsync(file.dir.fd);
}

pub fn executable(a: A, path: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (!std.fs.path.isAbsolute(name)) return error.ExecutableMustBeAbsolute;
        if (c.access(try a.dupeZ(u8, name), c.X_OK) != 0) return error.ExecutableNotFound;
        return name;
    }
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        const file = try std.fs.path.join(a, &.{ dir, name });
        if (c.access(try a.dupeZ(u8, file), c.X_OK) == 0) return file;
    }
    std.log.err("executable not found on PATH: {s}", .{name});
    return error.ExecutableNotFound;
}

pub const Command = struct {
    a: A,
    env: *const std.process.EnvMap,
    cwd: [:0]const u8,
    dir: std.fs.Dir,

    // Unlinked files bound memory usage and avoid stdin/stdout pipe deadlocks.
    fn stream(self: Command, name: []const u8) !std.fs.File {
        const file = try self.dir.createFile(name, .{ .read = true, .exclusive = true, .mode = 0o600 });
        errdefer file.close();
        try self.dir.deleteFile(name);
        return file;
    }

    pub fn run(self: Command, args: []const []const u8, input: []const u8, seconds: u32) ![]const u8 {
        const a = self.a;
        const argv = try a.allocSentinel(?[*:0]const u8, args.len, null);
        var initialized: usize = 0;
        defer {
            for (argv[0..initialized]) |arg| a.free(std.mem.span(arg.?));
            a.free(argv);
        }
        for (args, argv) |arg, *ptr| {
            ptr.* = try a.dupeZ(u8, arg);
            initialized += 1;
        }
        const envp = try std.process.createNullDelimitedEnvMap(a, self.env);
        defer {
            for (envp) |entry| a.free(std.mem.span(entry.?));
            a.free(envp);
        }
        const stdin = try self.stream("stdin");
        defer stdin.close();
        const stdout = try self.stream("stdout");
        defer stdout.close();
        const stderr = try self.stream("stderr");
        defer stderr.close();
        try stdin.writeAll(input);
        try stdin.seekTo(0);

        var timer = try std.time.Timer.start();
        const pid = c.fork();
        if (pid < 0) return error.SpawnFailed;
        if (pid == 0) {
            if (c.setpgid(0, 0) != 0 or c.chdir(self.cwd) != 0 or
                c.dup2(stdin.handle, 0) < 0 or c.dup2(stdout.handle, 1) < 0 or
                c.dup2(stderr.handle, 2) < 0) c._exit(126);
            _ = c.execve(argv[0].?, @ptrCast(argv.ptr), @ptrCast(envp.ptr));
            c._exit(127);
        }
        _ = c.setpgid(pid, pid);
        var status: c_int = 0;
        var reaped = false;
        defer {
            _ = c.kill(-pid, c.SIGKILL);
            if (!reaped) {
                _ = c.kill(pid, c.SIGKILL);
                while (c.waitpid(pid, &status, 0) < 0 and std.posix.errno(-1) == .INTR) {}
            }
        }
        while (true) {
            const result = c.waitpid(pid, &status, c.WNOHANG);
            if (result == pid) {
                reaped = true;
                break;
            }
            if (result < 0 and std.posix.errno(-1) != .INTR) return error.WaitFailed;
            if (timer.read() >= @as(u64, seconds) * std.time.ns_per_s) return error.SubprocessTimeout;
            if (try stdout.getEndPos() > output_limit or try stderr.getEndPos() > output_limit)
                return error.SubprocessOutputLimit;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        // The wrappers identify the failed step. Child diagnostics can contain credentials or PR text.
        if (status != 0) return error.SubprocessFailed;
        if (try stdout.getEndPos() > output_limit or try stderr.getEndPos() > output_limit)
            return error.SubprocessOutputLimit;
        try stdout.seekTo(0);
        return stdout.readToEndAlloc(a, output_limit);
    }
};
