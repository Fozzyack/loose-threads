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

pub fn read_html(template_name: []const u8, templates_dir: Dir, io: Io, allocator: Allocator) ![]u8 {
    var file = try templates_dir.openFile(io, template_name, .{});
    defer file.close(io);

    var page_buffer: []u8 = &.{};
    var read_buffer: [8192]u8 = undefined;
    var offset: usize = 0;

    while (true) {
        const bytes_read = try file.readPositionalAll(io, &read_buffer, offset);
        if (bytes_read == 0) break;
        page_buffer = try allocator.realloc(page_buffer, page_buffer.len + bytes_read);
        @memmove(page_buffer[offset .. offset + bytes_read], read_buffer[0..bytes_read]);
        offset += bytes_read;
    }
    return page_buffer;
}

test "read_html" {
    const io = std.testing.io;
    const test_allocator = std.testing.allocator;
    const template_dir = try Dir.cwd().openDir(io, "templates", .{ .iterate = true });

    const page_html = try read_html("index.html", template_dir, io, test_allocator);
    defer test_allocator.free(page_html);
}
