const std = @import("std");

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

    exe.root_module.link_libc = true;
    exe.root_module.addIncludePath(
        b.path("vendor/tree-sitter/lib/include"),
    );
    exe.root_module.addIncludePath(
        b.path("vendor/tree-sitter/lib/src"),
    );
    exe.root_module.addIncludePath(
        b.path("vendor/tree-sitter-zig/src"),
    );

    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/tree-sitter/lib/src/lib.c",
            "vendor/tree-sitter-zig/src/parser.c",
        },
        .flags = &.{"-std=gnu17"},
    });

    b.installArtifact(exe);

    const format_html = b.addSystemCommand(&.{ "prettier", "--ignore-path", ".prettierignore", "--write", "public/**/*.html" });
    format_html.setCwd(b.path("."));
    const format_step = b.step("format-html", "Format generated HTML in public/ with Prettier (optional)");
    format_step.dependOn(&format_html.step);
}
