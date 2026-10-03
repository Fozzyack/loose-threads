const std = @import("std");
const print = std.debug.print;

pub fn build(b: *std.Build) !void {
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

    const format_html = b.addSystemCommand(&.{ "prettier", "--ignore-path", ".prettierignore", "--write", "public/**/*.html" });
    format_html.setCwd(b.path("."));
    const format_step = b.step("format-html", "Format generated HTML in public/ with Prettier (optional)");
    format_step.dependOn(&format_html.step);
}
