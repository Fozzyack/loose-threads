const std = @import("std");
const Io = std.Io;

const Dir = Io.Dir;
const File = Io.File;

const mem = std.mem;

const Allocator = std.mem.Allocator;

const print = std.debug.print;

fn directory_exists(io: Io, name: []const u8) !bool {
    const dir = Dir.cwd().openDir(io, name, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound, error.NotDir => false,
            else => err,
        };
    };
    defer dir.close(io);
    return true;
}

fn delete_directory(dir: Dir, io: Io, allocator: Allocator) !void {
    var walker = try Dir.walk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        try Dir.deleteFile(dir, io, entry.path);
    }
}

pub fn main(init: std.process.Init) !void {
    if (try directory_exists(init.io, "public")) {
        var dir = try Dir.cwd().openDir(init.io, "public", .{ .iterate = true });
        defer dir.close(init.io);
        try delete_directory(dir, init.io, init.arena.allocator());
    }

    const css_dir = try Dir.cwd().openDir(init.io, "static", .{ .iterate = true });
    defer css_dir.close(init.io);

    var walker = try Dir.walk(css_dir, init.arena.allocator());
    defer walker.deinit();

    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".css")) continue;
        print("{s}\n", .{entry.path});
    }
}
