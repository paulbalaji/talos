const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
    });
    b.installArtifact(b.addExecutable(.{ .name = "talos", .root_module = module }));
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run the Talos tests").dependOn(&b.addRunArtifact(tests).step);
}
