const std = @import("std");
const log = @import("log.zig");
const reset_public = @import("generate_site.zig").reset_public;
const generate_site = @import("generate_site.zig").generate_site;

const Dir = std.Io.Dir;

/// Recreates `public`, copies CSS from `static`, and prints the names and rendered
/// content of entries read from `markdown`, using the process arena for allocations.
pub fn main(init: std.process.Init) !void {
    log.init(init.io);

    const public_dir = try reset_public(init.io);
    try generate_site(public_dir, init.io, init.arena.allocator());
}

test {
    _ = @import("generate_site.zig");
}
