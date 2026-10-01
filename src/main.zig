const std = @import("std");
const Dir = std.Io.Dir;
const markdown_parser = @import("markdown.zig");

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
    try markdown_parser.copy_css(css_dir, public_dir, init.io, init.arena.allocator());

    const markdown_dir = try Dir.cwd().openDir(init.io, "markdown", .{ .iterate = true });
    defer markdown_dir.close(init.io);

    const entries: []markdown_parser.Entry = try markdown_parser.create_entries(markdown_dir, init.io, init.arena.allocator());
    defer init.arena.allocator().free(entries);
    for (entries) |*entry| {
        print("{s}\n", .{entry.name});
        print("{s}\n", .{entry.content});
        defer entry.deinit(init.arena.allocator());
    }
}
