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



pub fn create_homepage(posts: []entries.Entry, public_dir: Dir, io: Io, allocator: Allocator) !void {
    var file = try public_dir.createFile(io, "index.html", .{ .read = true, .exclusive = true});

    var post_list_html: []u8 = &.{};

    for (posts) | post | {
        post_list_html;
    }


}
