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

pub const Entry = struct {
    name: []const u8 = undefined,
    content: []const u8 = &.{},
    description: []const u8 = &.{},
    slug: []const u8 = &.{},

    /// Creates an entry with an allocator-owned copy of `name` and empty content.
    /// Release the entry with `deinit` using the same allocator.
    pub fn add_name(self: *Entry, name: []const u8, allocator: Allocator) !void {
        self.name = try allocator.dupe(u8, name);
    }

    /// Appends a copy of `content`, replacing the existing content allocation.
    /// Use the same allocator that owns the entry's content.
    pub fn add_content(self: *Entry, content: []const u8, allocator: Allocator) !void {
        const strs: []const []const u8 = &[_][]const u8{ self.content, content };
        const new_content = try mem.concat(allocator, u8, strs);
        if (self.content.len > 0) allocator.free(self.content);
        self.content = new_content;
    }

    pub fn add_description(self: *Entry, description: []const u8, allocator: Allocator) !void {
        if (self.description.len > 0) allocator.free(self.description);
        self.description = try allocator.dupe(u8, description);
    }

    pub fn add_slug(self: *Entry, slug: []const u8, allocator: Allocator) !void {
        if (self.slug.len > 0) allocator.free(self.slug);
        self.slug = try allocator.dupe(u8, slug);
    }

    /// Frees the entry's name and content using their original allocator.
    pub fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.content);
        allocator.free(self.description);
        allocator.free(self.slug);
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

/// Appends a section as an HTML heading or paragraph followed by a newline.
/// Recognizes one to five leading `#` characters followed by a space and skips
/// empty sections. Text is copied without HTML escaping; a section consisting
/// only of recognized heading markers returns `error.InvalidLine`.
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

/// Shifts past leading newline bytes before the first non-newline byte in the
/// used portion of `buffer` and reduces `used` by the number removed.
/// Leaves all-newline input unchanged; `used` must not exceed `buffer.len`.
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

fn parse_metadata(buffer: []const u8, entry: *Entry, allocator: Allocator) !void {
    var start: usize = 0;
    for (0..3) |_| {
        const separator_idx = start + (mem.findScalar(u8, buffer[start..], ':') orelse return error.ErrorParsingMetadata);
        const newline_idx = start + (mem.findScalar(u8, buffer[start..], '\n') orelse return error.ErrorParsingMetadata);
        if (eql(u8, buffer[start..separator_idx], "name") or eql(u8, buffer[start..separator_idx], "name ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            try entry.add_name(value, allocator);
        } else if (eql(u8, buffer[start..separator_idx], "description") or eql(u8, buffer[start..separator_idx], "description ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            try entry.add_description(value, allocator);
        } else if (eql(u8, buffer[start..separator_idx], "slug") or eql(u8, buffer[start..separator_idx], "slug ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            try entry.add_slug(value, allocator);
        } else return error.InvalidMetadataFlagFound;
        start = newline_idx + 1;
    }
}

/// Recursively reads `.md` files into entries named after their relative paths
/// without the extension, appending a file date and rendered newline-ended sections.
/// The caller owns the returned slice and must deinitialize each entry and free
/// the slice using `allocator`.
pub fn create_entries(markdown_dir: Dir, io: Io, allocator: Allocator) ![]Entry {
    var walker = try Dir.walk(markdown_dir, allocator);
    defer walker.deinit();

    var read_buffer: [8192]u8 = undefined;
    var offset: usize = 0;
    var used: usize = 0;
    var entries: []Entry = &.{};

    var has_parsed_metadata: bool = false;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".md")) continue;

        // Read file
        var file = try markdown_dir.openFile(io, entry.path, .{});
        defer file.close(io);

        var new_entry: Entry = .{};

        while (true) {
            const bytes_read: usize = try file.readPositionalAll(io, read_buffer[used..], offset);
            if (bytes_read == 0) {
                if (has_parsed_metadata == false) return error.FailedToParseMetadata;
                break;
            }

            offset += bytes_read;
            used += bytes_read;
            strip_newline(&read_buffer, &used);

            while (true) {
                if (!has_parsed_metadata) {
                    const metadata_start: usize = mem.find(u8, read_buffer[0..used], "---\n") orelse break;
                    if (metadata_start != 0) return error.IncorrectMetadataDelimiter;
                    const metadata_end: usize = mem.find(u8, read_buffer[0..used], "\n---\n") orelse break;
                    try parse_metadata(read_buffer[4 .. metadata_end + 1], &new_entry, allocator);
                    print("{d} {d}\n", .{ metadata_start, metadata_end });
                    mem.copyForwards(u8, &read_buffer, read_buffer[metadata_end + 4 ..]);
                    used -= (metadata_end + 4);
                    strip_newline(&read_buffer, &used);
                    has_parsed_metadata = true;
                } else {
                    const newline_idx = mem.findScalar(u8, read_buffer[0..used], '\n') orelse break;
                    try parse_section(read_buffer[0..newline_idx], &new_entry, allocator);
                    mem.copyForwards(u8, &read_buffer, read_buffer[newline_idx + 1 ..]);
                    used -= newline_idx + 1;
                    strip_newline(&read_buffer, &used);
                }
            }
        }

        entries = try allocator.realloc(entries, entries.len + 1);
        entries[entries.len - 1] = new_entry;
    }
    return entries;
}
