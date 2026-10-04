const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const mem = std.mem;
const Allocator = mem.Allocator;

/// Recursively copies `.css` files into `public_dir` using their basenames.
/// Files with matching basenames share the same destination path.
pub fn copy_assets(css_dir: Dir, public_dir: Dir, io: Io, allocator: Allocator) !void {
    var walker = try Dir.walk(css_dir, allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".css") and
            !mem.endsWith(u8, entry.basename, ".png") and
            !mem.endsWith(u8, entry.basename, ".jpg") and
            !mem.endsWith(u8, entry.basename, ".jpeg") and
            !mem.endsWith(u8, entry.basename, ".gif")) continue;
        try Dir.copyFile(css_dir, entry.path, public_dir, entry.basename, io, .{});
    }
}
