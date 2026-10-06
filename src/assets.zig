const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const mem = std.mem;
const Allocator = mem.Allocator;

/// Recursively copies `.css` files into `public_dir` using their basenames.
/// Files with matching basenames share the same destination path.
pub fn copy_assets(css_dir: Dir, markdown_dir: Dir, public_dir: Dir, io: Io, allocator: Allocator) !void {
    var css_walker = try Dir.walk(css_dir, allocator);
    defer css_walker.deinit();

    while (try css_walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".css") and
            !mem.endsWith(u8, entry.basename, ".png") and
            !mem.endsWith(u8, entry.basename, ".jpg") and
            !mem.endsWith(u8, entry.basename, ".jpeg") and
            !mem.endsWith(u8, entry.basename, ".svg") and
            !mem.endsWith(u8, entry.basename, ".js") and
            !mem.endsWith(u8, entry.basename, ".gif") and
            !mem.endsWith(u8, entry.basename, ".js")) continue;
        try Dir.copyFile(css_dir, entry.path, public_dir, entry.basename, io, .{});
    }

    var markdown_walker = try Dir.walk(markdown_dir, allocator);
    defer markdown_walker.deinit();

    while (try markdown_walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".png") and
            !mem.endsWith(u8, entry.basename, ".jpg") and
            !mem.endsWith(u8, entry.basename, ".jpeg") and
            !mem.endsWith(u8, entry.basename, ".svg") and
            !mem.endsWith(u8, entry.basename, ".gif")) continue;
        try Dir.copyFile(markdown_dir, entry.path, public_dir, entry.basename, io, .{});
    }
}
