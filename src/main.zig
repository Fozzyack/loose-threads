const std = @import("std");
const entries = @import("entries.zig");

const Io = std.Io;
const Dir = Io.Dir;
const mem = std.mem;
const Allocator = mem.Allocator;

const print = std.debug.print;

/// Recursively copies `.css` files into `public_dir` using their basenames.
/// Files with matching basenames share the same destination path.
fn copy_css(css_dir: Dir, public_dir: Dir, io: Io, allocator: Allocator) !void {
    var walker = try Dir.walk(css_dir, allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".css")) continue;
        try Dir.copyFile(css_dir, entry.path, public_dir, entry.basename, io, .{});
    }
}


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
    try copy_css(css_dir, public_dir, init.io, init.arena.allocator());

    const markdown_dir = try Dir.cwd().openDir(init.io, "markdown", .{ .iterate = true });
    defer markdown_dir.close(init.io);

    const posts: []entries.Entry = try entries.create_entries(markdown_dir, init.io, init.arena.allocator());
    defer init.arena.allocator().free(posts);
    for (entries) |*post| {
        print("{s}\n", .{post.name});
        print("{s}\n", .{post.content});
        defer post.deinit(init.arena.allocator());
    }
}
