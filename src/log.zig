// Simple file to help log

const std = @import("std");
const Io = std.Io;

var log_io : ?Io = null;

pub fn init(io: Io) void {
    log_io = io;
}

pub fn print(comptime msg: []const u8, args: anytype) !void {
    if (@import("builtin").is_test) return;

    const io = log_io orelse return error.LogIoNotSet;
    var buffer: [1024] u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print(msg, args);
    try stdout.flush();
}
