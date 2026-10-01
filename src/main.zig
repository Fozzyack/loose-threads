const std = @import("std");
const Io = std.Io;

const Dir = Io.Dir;
const File = Io.File;

const epoch = std.time.epoch;

const mem = std.mem;

const Allocator = std.mem.Allocator;

const expect = std.testing.expect;
const eql = std.mem.eql;

const print = std.debug.print;

const Entry = struct {
    name: []const u8,
    content: []const u8 = &.{},

    fn init(name: []const u8, allocator: Allocator) !Entry {
        return .{ .name = try allocator.dupe(u8, name) };
    }

    fn add_content(self: *Entry, content: []const u8, allocator: Allocator) !void {
        const strs: []const []const u8 = &[_][]const u8{ self.content, content };
        const new_content = try mem.concat(allocator, u8, strs);
        if (self.content.len > 0) allocator.free(self.content);
        self.content = new_content;
    }

    fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.content);
    }
};

test "create entry" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = try Entry.init("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    try expect(eql(u8, "test entry", entry.name));
}

test "add_content" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = try Entry.init("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    try entry.add_content("This is some test\n", test_allocator);
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
    if (section.len == 0) return;
    var count: usize = 0;
    var has_headers = false;
    while (count < section.len and section[count] == '#') : (count += 1) {
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
    try entry.add_content(section[count..section.len], allocator);
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
    const test_allocator: std.mem.Allocator = std.testing.allocator;
    var entry: Entry = try Entry.init("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    const section: []const u8 = "# Test header";
    try parse_section(section, &entry, test_allocator);
    try expect(eql(u8, "<h1>Test header</h1>\n", entry.content));
}

test "parse_section with header 2" {
    const test_allocator: std.mem.Allocator = std.testing.allocator;
    var entry: Entry = try Entry.init("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    const section: []const u8 = "## Test header";
    try parse_section(section, &entry, test_allocator);
    try expect(eql(u8, "<h2>Test header</h2>\n", entry.content));
}

test "parse_section paragraph" {
    const test_allocator: std.mem.Allocator = std.testing.allocator;
    var entry: Entry = try Entry.init("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    const section: []const u8 = "some # test entry!";
    try parse_section(section, &entry, test_allocator);
    try expect(eql(u8, "<p>some # test entry!</p>\n", entry.content));
}

fn get_date(file: File, entry: *Entry, io: Io, allocator: Allocator) !void {
    const file_stat: File.Stat = try file.stat(io);
    const ts: Io.Timestamp = file_stat.atime orelse file_stat.mtime;
    const secs: i64 = ts.toSeconds();
    const es = epoch.EpochSeconds{ .secs = @intCast(secs) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_hours = es.getDaySeconds().getHoursIntoDay();
    const day_minutes = es.getDaySeconds().getMinutesIntoHour();
    const day_seconds = es.getDaySeconds().getSecondsIntoMinute();

    const month_str: []const u8 = switch (month_day.month) {
        .jan => "January",
        .feb => "Febuary",
        .mar => "March",
        .apr => "April",
        .may => "May",
        .jun => "June",
        .jul => "July",
        .aug => "August",
        .sep => "September",
        .oct => "October",
        .nov => "November",
        .dec => "December",
    };

    const output = .{
        month_str,
        month_day.day_index + 1,
        year_day.year,
        day_hours,
        day_minutes,
        day_seconds,
    };

    const content: []u8 = try std.fmt.allocPrint(allocator, "<p class=\"post-date\">{s} {d:0>2}, {d:0>4} @ {d:0>2}:{d:0>2}:{d:0>2} UTC</p>\n", output);
    defer allocator.free(content);
    try entry.add_content(content, allocator);
}

test "markdown file stat" {
    const test_allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = try Dir.cwd().openDir(io, "markdown", .{ .iterate = true });
    defer Dir.close(dir, io);
    var entry: Entry = try Entry.init("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    const file = try dir.openFile(io, "hello_world.md", .{});
    defer file.close(io);
    try get_date(file, &entry, io, test_allocator);

    // Note this test may have to be updated if the markdown file is modifiled
    try expect(eql(u8, "<p class=\"post-date\">October 01, 2026 @ 19:49:27 UTC</p>\n", entry.content));
}

fn strip_newline(buffer: []u8, used: *usize) void {
    if (buffer.len == 0) return;
    var newline_count: usize = 0;
    for (buffer[0..used.*], 0..used.*) |character, index| {
        if (character != '\n') {
            newline_count = index;
            break;
        }
    }
    mem.copyForwards(u8, buffer, buffer[newline_count..]);
    used.* -= newline_count;
}

test "strip newline" {
    var test_buffer: [9]u8 = "\n\n\n\ntest\n".*;
    var used: usize = test_buffer.len;
    strip_newline(&test_buffer, &used);
    try expect(eql(u8, "test\n", test_buffer[0..used]));
}

test "strip newline no newline" {
    var test_buffer: [5]u8 = "test\n".*;
    var used: usize = test_buffer.len;
    strip_newline(&test_buffer, &used);
    try expect(eql(u8, "test\n", test_buffer[0..used]));
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

        // Read file
        var file = try markdown_dir.openFile(io, entry.path, .{});
        defer file.close(io);

        var new_entry: Entry = try Entry.init(entry.path[0 .. entry.path.len - 3], allocator);
        try get_date(file, &new_entry, io, allocator);

        while (true) {
            const bytes_read: usize = try file.readPositionalAll(io, read_buffer[used..], offset);
            if (bytes_read == 0) break;
            offset += bytes_read;
            used += bytes_read;
            strip_newline(&read_buffer, &used);

            while (true) {
                const newline_idx = mem.findScalar(u8, read_buffer[0..used], '\n') orelse break;
                try parse_section(read_buffer[0..newline_idx], &new_entry, allocator);
                mem.copyForwards(u8, &read_buffer, read_buffer[newline_idx + 1 ..]);
                used -= newline_idx + 1;
                strip_newline(&read_buffer, &used);
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
    for (entries) |*entry| {
        print("{s}\n", .{entry.name});
        print("{s}\n", .{entry.content});
        defer entry.deinit(init.arena.allocator());
    }
}
