const std = @import("std");
const Io = std.Io;

const Dir = Io.Dir;
const File = Io.File;

const mem = std.mem;

const Allocator = std.mem.Allocator;

const print = std.debug.print;

const Entry = struct {
    name: []u8,
    content: []u8 = &.{},

    pub fn init(self: *Entry, name: []const u8) void {
        self.name = name;
        return self;
    }

    pub fn add_content(self: *Entry, content: []u8, allocator: Allocator) !void {
        try mem.concat(allocator, u8, .{ self.content, content });
    }
};

fn copy_css(css_dir: Dir, public_dir: Dir, io: Io, allocator: Allocator) !void {
    var walker = try Dir.walk(css_dir, allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".css")) continue;
        try Dir.copyFile(css_dir, entry.path, public_dir, entry.basename, io, .{});
    }
}

fn parse_markdown(markdown_dir: Dir, io: Io, allocator: Allocator) !void {
    var walker = try Dir.walk(markdown_dir, allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".md")) continue;

        // Read file
        var file = try markdown_dir.openFile(io, entry.path, .{});
        defer file.close(io);
    }
}

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
}
