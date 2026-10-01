const std = @import("std");
const entries = @import("entries.zig");
const assets = @import("assets.zig");
const template = @import("templates.zig");

const Dir = std.Io.Dir;

const print = std.debug.print;

/// Recreates `public`, copies CSS from `static`, and prints the names and rendered
/// content of entries read from `markdown`, using the process arena for allocations.
pub fn main(init: std.process.Init) !void {
    Dir.cwd().deleteTree(init.io, "public") catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try Dir.cwd().createDir(init.io, "public", .default_dir);

    const public_dir = try Dir.cwd().openDir(init.io, "public", .{ .iterate = true });
    defer public_dir.close(init.io);

    const css_dir = try Dir.cwd().openDir(init.io, "static", .{ .iterate = true });
    defer css_dir.close(init.io);
    try assets.copy_css(css_dir, public_dir, init.io, init.arena.allocator());

    const markdown_dir = try Dir.cwd().openDir(init.io, "markdown", .{ .iterate = true });
    defer markdown_dir.close(init.io);

    const posts: []entries.Entry = try entries.create_entries(markdown_dir, init.io, init.arena.allocator());
    defer init.arena.allocator().free(posts);
    for (posts) |*post| {
        print("{s}\n", .{post.name});
        print("{s}\n", .{post.content});
        defer post.deinit(init.arena.allocator());
    }
}
