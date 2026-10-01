const std = @import("std");
const print = std.debug.print;

pub fn build(b: *std.Build) !void {
    print(" ______________ BUILDING _________________", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "blog-generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("./src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);
}
