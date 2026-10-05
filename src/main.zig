const std = @import("std");
const entries = @import("entries.zig");
const parser = @import("parser.zig");
const assets = @import("assets.zig");
const template = @import("templates.zig");
const highlight = @import("highlight.zig");

const Dir = std.Io.Dir;

/// Recreates `public`, copies CSS from `static`, and prints the names and rendered
/// content of entries read from `markdown`, using the process arena for allocations.
pub fn main(init: std.process.Init) !void {
    try highlight.check();
    Dir.cwd().deleteTree(init.io, "public") catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try Dir.cwd().createDir(init.io, "public", .default_dir);

    const public_dir = try Dir.cwd().openDir(init.io, "public", .{ .iterate = true });
    defer public_dir.close(init.io);

    const static_dir = try Dir.cwd().openDir(init.io, "static", .{ .iterate = true });
    defer static_dir.close(init.io);
    try assets.copy_assets(static_dir, public_dir, init.io, init.arena.allocator());

    const markdown_dir = try Dir.cwd().openDir(init.io, "markdown", .{ .iterate = true });
    defer markdown_dir.close(init.io);

    const templates_dir = try Dir.cwd().openDir(init.io, "templates", .{ .iterate = true });
    defer templates_dir.close(init.io);

    const posts: []entries.Entry = try parser.create_entries(markdown_dir, init.io, init.arena.allocator());
    defer init.arena.allocator().free(posts);

    try template.create_homepage(posts, templates_dir, public_dir, init.io, init.arena.allocator());
    try template.create_posts(posts, templates_dir, public_dir, init.io, init.arena.allocator());
}
