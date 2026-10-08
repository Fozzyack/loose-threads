const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const entries = @import("entries.zig");
const parser = @import("parser/parser.zig");
const assets = @import("assets.zig");
const template = @import("templates.zig");

const print = @import("log.zig").print;

pub fn reset_public(io: Io) !Dir {
    Dir.cwd().deleteTree(io, "public") catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try Dir.cwd().createDir(io, "public", .default_dir);
    return Dir.cwd().openDir(io, "public", .{ .iterate = true });
}

pub fn generate_site(public_dir: Dir, io: Io, allocator: Allocator) !void {
    const markdown_dir = try Dir.cwd().openDir(io, "markdown", .{ .iterate = true });
    defer markdown_dir.close(io);

    const static_dir = try Dir.cwd().openDir(io, "static", .{ .iterate = true });
    defer static_dir.close(io);
    try assets.copy_assets(static_dir, markdown_dir, public_dir, io, allocator);

    const templates_dir = try Dir.cwd().openDir(io, "templates", .{ .iterate = true });
    defer templates_dir.close(io);

    // parse markdown
    const posts: []entries.Entry = try parser.create_entries(markdown_dir, io, allocator);
    defer allocator.free(posts);

    // generate html
    try template.create_homepage(posts, templates_dir, public_dir, io, allocator);
    try template.create_posts(posts, templates_dir, public_dir, io, allocator);
}

pub fn format_public(io: Io) !void {
    try print("--- Formatting Files ---\n", .{});
    var child = std.process.spawn(io, .{
        .argv = &.{ "prettier", "public/", "--write", "--ignore-path", ".prettierignore" },
        .stdin = .inherit,
        .stderr = .inherit,
        .stdout = .inherit,
    }) catch |err| {
        std.debug.print("Prettier failed. Is Prettier Installed?", .{});
        return err;
    };
    defer child.kill(io);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("Prettier failed", .{});
                return error.PrettierFailed;
            }
        },
        else => {
            std.debug.print("Prettier failed", .{});
            return error.PrettierFailed;
        },
    }
}

test {
    _ = entries;
    _ = parser;
    _ = assets;
    _ = template;
}
