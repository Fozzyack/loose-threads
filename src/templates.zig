const std = @import("std");
const entries = @import("entries.zig");
const Io = std.Io;

const Dir = Io.Dir;
const File = Io.File;

const epoch = std.time.epoch;

const mem = std.mem;

const Allocator = std.mem.Allocator;

const expect = std.testing.expect;
const eql = std.mem.eql;

const print = std.debug.print;

pub fn read_html(template_name: []const u8, templates_dir: Dir, io: Io, allocator: Allocator) !void {
    var file = try templates_dir.openFile(io, template_name, .{});
    defer file.close(io);

    var page_buffer: []u8 = &.{};
    var read_buffer: [4096]u8 = undefined;
    var offset: usize = 0;

    while (true) {
        const bytes_read = try file.readPositionalAll(io, &read_buffer, offset);
        if (bytes_read == 0) break;
        offset += bytes_read;
        try allocator.realloc(page_buffer, page_buffer.len + bytes_read);
        @memmove(&page_buffer, &read_buffer);
    }
}

pub fn create_homepage(posts: []entries.Entry, templates_dir: Dir, public_dir: Dir, io: Io, allocator: Allocator) !void {
    for (posts) |post| {}
}
