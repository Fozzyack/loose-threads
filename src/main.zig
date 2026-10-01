const std = @import("std");
const Io = std.Io;

const Dir = Io.Dir;
const File = Io.File;

const mem = std.mem;

const Allocator = std.mem.Allocator;

const expect = std.testing.expect;
const eql = std.mem.eql;

const print = std.debug.print;

const Entry = struct {
    name: []const u8,
    content: []const u8 = &.{},

    fn init(name: []const u8) Entry {
        return .{ .name = name };
    }

    fn add_content(self: *Entry, content: []const u8, allocator: Allocator) !void {
        const strs: []const []const u8 = &[_][]const u8{ self.content, content };
        const new_content = try mem.concat(allocator, u8, strs);
        if (self.content.len > 0) allocator.free(self.content);
        self.content = new_content;
    }
};

test "create entry" {
    const entry: Entry = Entry.init("test entry");
    try expect(eql(u8, "test entry", entry.name));
}

test "add_content" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = Entry.init("test entry");
    try entry.add_content("This is some test\n", test_allocator);
    defer test_allocator.free(entry.content);
    try expect(eql(u8, "This is some test\n", entry.content));
    try entry.add_content("another section\n", test_allocator);
    try expect(eql(u8, "This is some test\nanother section\n", entry.content));
}

fn copy_css(css_dir: Dir, public_dir: Dir, io: Io, allocator: Allocator) !void {
    var walker = try Dir.walk(css_dir, allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".css")) continue;
        try Dir.copyFile(css_dir, entry.path, public_dir, entry.basename, io, .{});
    }
}

fn parse_section(section: []const u8, entry: *Entry, allocator: Allocator) !void {
    var count: usize = 0;
    var has_headers = false;
    while (section[count] == '#') : (count += 1) {
        if (count >= 5) break;
    }
    if (count >= section.len) return error.InvalidLine;
    if (count > 0 and section[count] == ' ') {
        has_headers = true;
        count += 1;
        const header = try std.fmt.allocPrint(allocator, "<h{d}>", .{count - 1});
        defer allocator.free(header);
        try entry.add_content(header, allocator);
    } else {
        const header = try std.fmt.allocPrint(allocator, "<p>", .{});
        defer allocator.free(header);
        try entry.add_content(header, allocator);
    }
    try entry.add_content(section[count .. section.len - 1], allocator);
    if (has_headers) {
        const close_tag = try std.fmt.allocPrint(allocator, "</h{d}>", .{count - 1});
        defer allocator.free(close_tag);
        try entry.add_content(close_tag, allocator);
    } else {
        const close_tag = try std.fmt.allocPrint(allocator, "</p>", .{});
        defer allocator.free(close_tag);
        try entry.add_content(close_tag, allocator);
    }
    try entry.add_content("\n", allocator);
}

test "parse_section with header" {
    var entry: Entry = Entry.init("test entry");
    const section: []const u8 = "## Test header\n";
    var testing_allocator: std.mem.Allocator = std.testing.allocator;
    try parse_section(section, &entry, testing_allocator);
    defer testing_allocator.free(entry.content);
    try expect(eql(u8, "<h2>Test header</h2>\n", entry.content));
}

test "parse_section paragraph" {
    var entry: Entry = Entry.init("test entry");
    const section: []const u8 = "some # test entry!\n";
    var testing_allocator: std.mem.Allocator = std.testing.allocator;
    try parse_section(section, &entry, testing_allocator);
    defer testing_allocator.free(entry.content);
    try expect(eql(u8, "<p>some # test entry!</p>\n", entry.content));
}

fn create_entries(markdown_dir: Dir, io: Io, allocator: Allocator) ![]Entry {
    var walker = try Dir.walk(markdown_dir, allocator);
    defer walker.deinit();

    var read_buffer: [8192]u8 = undefined;
    var offset: usize = 0;
    var used: usize = 0;
    var entries: []Entry = &.{};

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".md")) continue;
        var new_entry: Entry = Entry.init(entry.path);

        // Read file
        var file = try markdown_dir.openFile(io, entry.path, .{});
        defer file.close(io);

        while (true) {
            const bytes_read: usize = try file.readPositionalAll(io, read_buffer[used..], offset);
            if (bytes_read == 0) break;
            offset += bytes_read;
            used += bytes_read;
            while (true) {
                const new_line = mem.findScalar(u8, &read_buffer, '\n') orelse break;
                try parse_section(read_buffer[0..new_line], &new_entry, allocator);
                mem.copyBackwards(u8, &read_buffer, read_buffer[new_line..]);
                used -= new_line;
            }
        }

        entries = try allocator.realloc(entries, entries.len + 1);
        entries[entries.len - 1] = new_entry;
    }
    return entries;
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

    const entries: []Entry = try create_entries(markdown_dir, init.io, init.arena.allocator());
    defer init.arena.allocator().free(entries);
    for (entries) |entry| {
        print("{s}\n", .{entry.content});
    }
}
