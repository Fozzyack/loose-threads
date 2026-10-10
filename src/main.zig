const std = @import("std");
const log = @import("log.zig");
const reset_public = @import("generate_site.zig").reset_public;
const generate_site = @import("generate_site.zig").generate_site;
const format_public = @import("generate_site.zig").format_public;

const Dir = std.Io.Dir;

/// Recreates `public`, copies CSS from `static`, and prints the names and rendered
/// content of entries read from `markdown`, using the process arena for allocations.
pub fn main(init: std.process.Init) !void {
    log.init(init.io);

    var format_file: bool = false;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) format_file = true else return error.ArgumentNotRecognized;
    }

    const public_dir = try reset_public(init.io);
    defer public_dir.close(init.io);
    try generate_site(public_dir, init.io, std.heap.smp_allocator);

    if (format_file) try format_public(init.io);
}

test {
    _ = @import("generate_site.zig");
}
