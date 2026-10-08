const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("vendor/tree-sitter/lib/include/tree_sitter/api.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const exe = b.addExecutable(.{
        .name = "blog-generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("./src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.link_libc = true;
    exe.root_module.addImport("tree_sitter", translator.mod);
    exe.root_module.addIncludePath(
        b.path("vendor/tree-sitter/lib/include"),
    );
    exe.root_module.addIncludePath(
        b.path("vendor/tree-sitter/lib/src"),
    );
    exe.root_module.addCSourceFiles(.{
        .files = &.{"vendor/tree-sitter/lib/src/lib.c"},
        .flags = &.{"-std=gnu17"},
    });
    // Keep each grammar's private headers scoped to its own C sources.
    inline for (.{ "zig", "python", "c", "json", "bash" }) |grammar| {
        exe.root_module.addCSourceFiles(.{
            .root = b.path("vendor/tree-sitter-" ++ grammar ++ "/src"),
            .files = if (std.mem.eql(u8, grammar, "python") or std.mem.eql(u8, grammar, "bash"))
                &.{ "parser.c", "scanner.c" }
            else
                &.{"parser.c"},
            // C23 makes scanner create() definitions match the runtime's
            // create(void) callback type under ReleaseSafe's function sanitizer.
            .flags = &.{
                if (std.mem.eql(u8, grammar, "python") or std.mem.eql(u8, grammar, "bash")) "-std=gnu23" else "-std=gnu17",
                "-Ivendor/tree-sitter-" ++ grammar ++ "/src",
            },
        });
    }

    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run generator and syntax-highlighting tests");
    test_step.dependOn(&run_tests.step);

    const format_html = b.addSystemCommand(&.{ "prettier", "--ignore-path", ".prettierignore", "--write", "public/**/*.html" });
    format_html.setCwd(b.path("."));
    const format_step = b.step("format-html", "Format generated HTML in public/ with Prettier (optional)");
    format_step.dependOn(&format_html.step);
}
