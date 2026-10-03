const std = @import("std");
const Entry = @import("entries.zig").Entry;
const Io = std.Io;

const Dir = Io.Dir;

const mem = std.mem;

const Allocator = std.mem.Allocator;

const expect = std.testing.expect;
const eql = std.mem.eql;

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
    var entry: Entry = .{};
    try entry.add_name("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    const section: []const u8 = "# Test header";
    try parse_section(section, &entry, test_allocator);
    try expect(eql(u8, "<h1>Test header</h1>\n", entry.content));
}

test "parse_section with header 2" {
    const test_allocator: std.mem.Allocator = std.testing.allocator;
    var entry: Entry = .{};
    try entry.add_name("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    const section: []const u8 = "## Test header";
    try parse_section(section, &entry, test_allocator);
    try expect(eql(u8, "<h2>Test header</h2>\n", entry.content));
}

test "parse_section paragraph" {
    const test_allocator: std.mem.Allocator = std.testing.allocator;
    var entry: Entry = .{};
    try entry.add_name("test entry", test_allocator);
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
    @memmove(buffer[0 .. used.* - newline_count], buffer[newline_count..used.*]);
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

/// Parses newline-terminated metadata lines without the `---` delimiters.
/// Accepts `name`, `description`, `slug`, `date`, and `timestamp` keys,
/// optionally followed by one space. Trims surrounding spaces from values;
/// strings are allocator-owned copies and timestamps are numeric Unix seconds.
/// After parsing, appends one post-date paragraph: the timestamp's UTC date and
/// time if present, otherwise the date. Metadata order does not affect this choice.
/// Malformed or impossible dates return `error.InvalidMetadataDate`; malformed
/// or out-of-range timestamps return `error.InvalidMetadataTimestamp`.
/// Missing separators or newlines return `error.ErrorParsingMetadata`; unknown keys
/// return `error.InvalidMetadataFlagFound`. Fields already stored remain on failure.
fn parse_metadata(buffer: []const u8, entry: *Entry, allocator: Allocator) !void {
    var start: usize = 0;
    while (start < buffer.len) {
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
        } else if (eql(u8, buffer[start..separator_idx], "date") or eql(u8, buffer[start..separator_idx], "date ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            try entry.add_date(value, allocator);
        } else if (eql(u8, buffer[start..separator_idx], "timestamp") or eql(u8, buffer[start..separator_idx], "timestamp ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            try entry.add_timestamp(value);
        } else return error.InvalidMetadataFlagFound;
        start = newline_idx + 1;
    }
    try entry.render_date(allocator);
}

test "parse_metadata trims values and accepts reordered keys" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{};
    defer entry.deinit(test_allocator);
    const metadata = "slug :  my-post  \ndescription:  A post with spaces  \nname:  My blog post  \n";

    try parse_metadata(metadata, &entry, test_allocator);

    try expect(eql(u8, "My blog post", entry.name));
    try expect(eql(u8, "A post with spaces", entry.description));
    try expect(eql(u8, "my-post", entry.slug));
}

test "parse_metadata rejects unknown keys and missing delimiters" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(test_allocator);

    try std.testing.expectError(error.InvalidMetadataFlagFound, parse_metadata("author: Someone\n", &entry, test_allocator));
    try std.testing.expectError(error.ErrorParsingMetadata, parse_metadata("name without a colon\n", &entry, test_allocator));
    try std.testing.expectError(error.ErrorParsingMetadata, parse_metadata("name: Missing newline", &entry, test_allocator));
}

test "parse_metadata stores date and generates post-date content before the body" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(test_allocator);
    const metadata = "name: Hello World\ndescription: My first post\nslug: hello-world\ndate :  2026-10-01  \n";

    try parse_metadata(metadata, &entry, test_allocator);
    try parse_section("Welcome to my blog.", &entry, test_allocator);

    try expect(eql(u8, "2026-10-01", entry.date));
    try expect(eql(u8, "<p class=\"post-date\">October 1, 2026</p>\n<p>Welcome to my blog.</p>\n", entry.content));
}

test "parse_metadata validates date format and leap years" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(test_allocator);

    const invalid_dates = [_][]const u8{
        "date: 2026-2-01\n",
        "date: 2026/10/01\n",
        "date: abcd-10-01\n",
        "date: 2026-00-01\n",
        "date: 2026-13-01\n",
        "date: 2026-10-00\n",
        "date: 2026-04-31\n",
        "date: 2026-02-29\n",
        "date: 1900-02-29\n",
    };
    for (invalid_dates) |metadata| {
        try std.testing.expectError(error.InvalidMetadataDate, parse_metadata(metadata, &entry, test_allocator));
        try expect(entry.date.len == 0);
        try expect(entry.content.len == 0);
    }

    try parse_metadata("date: 2000-02-29\n", &entry, test_allocator);
    try expect(eql(u8, "2000-02-29", entry.date));
    try expect(eql(u8, "<p class=\"post-date\">February 29, 2000</p>\n", entry.content));
}

test "parse_metadata stores Unix timestamp and displays UTC before the body" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(test_allocator);
    const metadata = "name: Hello World\ndescription: My first post\nslug: hello-world\ndate: 2026-10-01\ntimestamp :  1790858096  \n";

    try parse_metadata(metadata, &entry, test_allocator);
    try parse_section("Welcome to my blog.", &entry, test_allocator);

    try std.testing.expectEqual(@as(?u64, 1790858096), entry.timestamp);
    try expect(eql(u8, "2026-10-01", entry.date));
    try expect(eql(u8, "<p class=\"post-date\">October 1, 2026 at 12:34:56 UTC</p>\n<p>Welcome to my blog.</p>\n", entry.content));
}

test "parse_metadata renders one paragraph regardless of date and timestamp order" {
    const test_allocator = std.testing.allocator;
    const metadata_orders = [_][]const u8{
        "date: 2026-10-02\ntimestamp: 1790858096\n",
        "timestamp: 1790858096\ndate: 2026-10-02\n",
    };
    for (metadata_orders) |metadata| {
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(test_allocator);
        try parse_metadata(metadata, &entry, test_allocator);

        try expect(eql(u8, "2026-10-02", entry.date));
        try std.testing.expectEqual(@as(?u64, 1790858096), entry.timestamp);
        try expect(eql(u8, "<p class=\"post-date\">October 1, 2026 at 12:34:56 UTC</p>\n", entry.content));
    }
}

test "parse_metadata converts timestamp boundaries and leap day to UTC" {
    const test_allocator = std.testing.allocator;
    const cases = [_]struct { metadata: []const u8, timestamp: u64, content: []const u8 }{
        .{ .metadata = "timestamp: 0\n", .timestamp = 0, .content = "<p class=\"post-date\">January 1, 1970 at 00:00:00 UTC</p>\n" },
        .{ .metadata = "timestamp: 86399\n", .timestamp = 86399, .content = "<p class=\"post-date\">January 1, 1970 at 23:59:59 UTC</p>\n" },
        .{ .metadata = "timestamp: 86400\n", .timestamp = 86400, .content = "<p class=\"post-date\">January 2, 1970 at 00:00:00 UTC</p>\n" },
        .{ .metadata = "timestamp: 1709164800\n", .timestamp = 1709164800, .content = "<p class=\"post-date\">February 29, 2024 at 00:00:00 UTC</p>\n" },
        .{ .metadata = "timestamp: 253402300799\n", .timestamp = 253402300799, .content = "<p class=\"post-date\">December 31, 9999 at 23:59:59 UTC</p>\n" },
    };
    for (cases) |case| {
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(test_allocator);
        try parse_metadata(case.metadata, &entry, test_allocator);
        try std.testing.expectEqual(@as(?u64, case.timestamp), entry.timestamp);
        try expect(eql(u8, case.content, entry.content));
    }
}

test "parse_metadata rejects invalid Unix timestamps" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(test_allocator);
    const invalid_timestamps = [_][]const u8{
        "timestamp: \n",
        "timestamp: -1\n",
        "timestamp: 1.5\n",
        "timestamp: 12abc\n",
        "timestamp: 1_000\n",
        "timestamp: 253402300800\n",
        "timestamp: 18446744073709551616\n",
    };
    for (invalid_timestamps) |metadata| {
        try std.testing.expectError(error.InvalidMetadataTimestamp, parse_metadata(metadata, &entry, test_allocator));
        try expect(entry.timestamp == null);
        try expect(entry.content.len == 0);
    }
}

/// Recursively reads `.md` files into entries using their metadata, appending a
/// post-date paragraph and rendered newline-ended sections.
/// The caller owns the returned slice and must deinitialize each entry and free
/// the slice using `allocator`.
pub fn create_entries(markdown_dir: Dir, io: Io, allocator: Allocator) ![]Entry {
    var walker = try Dir.walk(markdown_dir, allocator);
    defer walker.deinit();

    var entries: []Entry = &.{};

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".md")) continue;

        var read_buffer: [8192]u8 = undefined;
        var has_parsed_metadata: bool = false;
        var offset: usize = 0;
        var used: usize = 0;

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
                    @memmove(read_buffer[0 .. used - (metadata_end + 4)], read_buffer[metadata_end + 4 .. used]);
                    used -= (metadata_end + 4);
                    strip_newline(&read_buffer, &used);
                    has_parsed_metadata = true;
                } else {
                    const newline_idx = mem.findScalar(u8, read_buffer[0..used], '\n') orelse break;
                    try parse_section(read_buffer[0..newline_idx], &new_entry, allocator);
                    @memmove(read_buffer[0 .. used - (newline_idx + 1)], read_buffer[newline_idx + 1 .. used]);
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

test "create_entries parses each file independently" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    try markdown.dir.writeFile(io, .{
        .sub_path = "first.md",
        .data = "---\nname: First\nslug: first\ndate: 2026-10-01\n---\n\n# First heading\nFirst body.\n",
    });
    try markdown.dir.writeFile(io, .{
        .sub_path = "second.md",
        .data = "---\nname: Second\nslug: second\ntimestamp: 0\n---\n\n## Second heading\nSecond body.\n",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqual(@as(usize, 2), posts.len);
    // Directory traversal order is unspecified.
    for (posts) |post| {
        if (eql(u8, post.slug, "first")) {
            try std.testing.expectEqualStrings("First", post.name);
            try std.testing.expectEqualStrings("<p class=\"post-date\">October 1, 2026</p>\n<h1>First heading</h1>\n<p>First body.</p>\n", post.content);
        } else {
            try std.testing.expectEqualStrings("second", post.slug);
            try std.testing.expectEqualStrings("Second", post.name);
            try std.testing.expectEqualStrings("<p class=\"post-date\">January 1, 1970 at 00:00:00 UTC</p>\n<h2>Second heading</h2>\n<p>Second body.</p>\n", post.content);
        }
    }
    try expect(!eql(u8, posts[0].slug, posts[1].slug));
}
