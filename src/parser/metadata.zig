const std = @import("std");
const Entry = @import("../entries.zig").Entry;
const FileParserState = @import("state.zig").FileParserState;
const mem = std.mem;
const eql = mem.eql;
const Allocator = mem.Allocator;
const expect = std.testing.expect;

/// Parses newline-terminated metadata lines without the `---` delimiters.
/// Accepts `name`, `description`, `slug`, `date`, `timestamp`, and `toc` keys,
/// optionally followed by one space. Trims surrounding spaces from values;
/// strings are allocator-owned copies and timestamps are numeric Unix seconds.
/// After parsing, appends one post-date paragraph: the timestamp's UTC date and
/// time if present, otherwise the date. Metadata order does not affect this choice.
/// Malformed or impossible dates return `error.InvalidMetadataDate`; malformed
/// or out-of-range timestamps return `error.InvalidMetadataTimestamp`.
/// Missing separators or newlines return `error.ErrorParsingMetadata`; unknown keys
/// return `error.InvalidMetadataFlagFound`. Fields already stored remain on failure.
pub fn parse_metadata(parser_state: *FileParserState, metadata_end: usize, entry: *Entry, allocator: Allocator) !void {
    var start: usize = 0;
    var buffer: []u8 = parser_state.read_buffer[4 .. metadata_end + 1];
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
        } else if (eql(u8, buffer[start..separator_idx], "toc") or eql(u8, buffer[start..separator_idx], "toc ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            if (eql(u8, value, "true")) parser_state.has_toc = true;
        } else return error.InvalidMetadataFlagFound;
        start = newline_idx + 1;
    }
    try entry.render_date(allocator);
}

fn test_parse_metadata(metadata: []const u8, entry: *Entry, allocator: Allocator) !void {
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);
    @memcpy(state.read_buffer[0..4], "---\n");
    @memcpy(state.read_buffer[4 .. 4 + metadata.len], metadata);
    state.used = 4 + metadata.len;
    try parse_metadata(&state, state.used - 1, entry, allocator);
}

fn test_append_body(entry: *Entry, allocator: Allocator) !void {
    const section = "Welcome to my blog.";
    var state: FileParserState = .{ .file = undefined, .section = .NORMAL_MODE };
    defer state.deinit(allocator);
    @memcpy(state.read_buffer[0..section.len], section);
    try @import("blocks.zig").parse_section(&state, section.len, entry, allocator);
}

test "parse_metadata trims values and accepts reordered keys" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{};
    defer entry.deinit(test_allocator);
    const metadata = "slug :  my-post  \ndescription:  A post with spaces  \nname:  My blog post  \n";

    try test_parse_metadata(metadata, &entry, test_allocator);

    try expect(eql(u8, "My blog post", entry.name));
    try expect(eql(u8, "A post with spaces", entry.description));
    try expect(eql(u8, "my-post", entry.slug));
}

test "parse_metadata rejects unknown keys and missing delimiters" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(test_allocator);

    try std.testing.expectError(error.InvalidMetadataFlagFound, test_parse_metadata("author: Someone\n", &entry, test_allocator));
    try std.testing.expectError(error.ErrorParsingMetadata, test_parse_metadata("name without a colon\n", &entry, test_allocator));
    try std.testing.expectError(error.ErrorParsingMetadata, test_parse_metadata("name: Missing newline", &entry, test_allocator));
}

test "parse_metadata stores date and generates post-date content before the body" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(test_allocator);
    const metadata = "name: Hello World\ndescription: My first post\nslug: hello-world\ndate :  2026-10-01  \n";

    try test_parse_metadata(metadata, &entry, test_allocator);
    try test_append_body(&entry, test_allocator);

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
        try std.testing.expectError(error.InvalidMetadataDate, test_parse_metadata(metadata, &entry, test_allocator));
        try expect(entry.date.len == 0);
        try expect(entry.content.len == 0);
    }

    try test_parse_metadata("date: 2000-02-29\n", &entry, test_allocator);
    try expect(eql(u8, "2000-02-29", entry.date));
    try expect(eql(u8, "<p class=\"post-date\">February 29, 2000</p>\n", entry.content));
}

test "parse_metadata stores Unix timestamp and displays UTC before the body" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(test_allocator);
    const metadata = "name: Hello World\ndescription: My first post\nslug: hello-world\ndate: 2026-10-01\ntimestamp :  1790858096  \n";

    try test_parse_metadata(metadata, &entry, test_allocator);
    try test_append_body(&entry, test_allocator);

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
        try test_parse_metadata(metadata, &entry, test_allocator);

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
        try test_parse_metadata(case.metadata, &entry, test_allocator);
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
        try std.testing.expectError(error.InvalidMetadataTimestamp, test_parse_metadata(metadata, &entry, test_allocator));
        try expect(entry.timestamp == null);
        try expect(entry.content.len == 0);
    }
}
