const std = @import("std");
const Io = std.Io;

const Dir = Io.Dir;
const File = Io.File;

const mem = std.mem;

const Allocator = std.mem.Allocator;

const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    Dir.cwd().deleteTree(init.io, "public") catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try Dir.cwd().createDir(init.io, "public", .default_dir);

    const public_dir = try Dir.cwd().openDir(init.io, "public", .{ .iterate = true });
    defer public_dir.close(init.io);

    const css_dir = try Dir.cwd().openDir(init.io, "static", .{ .iterate = true });
    defer css_dir.close(init.io);

    var walker = try Dir.walk(css_dir, init.arena.allocator());
    defer walker.deinit();

    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".css")) continue;
        try Dir.copyFile(css_dir, entry.path, public_dir, entry.basename, init.io, .{});
    }
}
