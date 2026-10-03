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

const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

pub const Entry = struct {
    name: []const u8 = undefined,
    content: []const u8 = &.{},
    description: []const u8 = &.{},
    slug: []const u8 = &.{},
    date: []const u8 = &.{},
    timestamp: ?u64 = null,

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

    /// Stores an allocator-owned YYYY-MM-DD date.
    /// Rejects malformed dates and dates outside the Gregorian calendar.
    pub fn add_date(self: *Entry, date: []const u8, allocator: Allocator) !void {
        if (date.len != 10 or date[4] != '-' or date[7] != '-') return error.InvalidMetadataDate;
        for (date, 0..) |character, index| {
            if (index == 4 or index == 7) continue;
            if (character < '0' or character > '9') return error.InvalidMetadataDate;
        }
        const year = try std.fmt.parseInt(u16, date[0..4], 10);
        const month = try std.fmt.parseInt(u8, date[5..7], 10);
        const day = try std.fmt.parseInt(u8, date[8..10], 10);
        if (year == 0 or month == 0 or month > 12 or day == 0) return error.InvalidMetadataDate;
        const leap_year = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
        const days_in_month = [_]u8{ 31, if (leap_year) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        if (day > days_in_month[month - 1]) return error.InvalidMetadataDate;
        const owned_date = try allocator.dupe(u8, date);
        if (self.date.len > 0) allocator.free(self.date);
        self.date = owned_date;
    }

    /// Stores decimal Unix seconds without allocating.
    /// Accepts timestamps from 1970-01-01 through 9999-12-31; malformed values
    /// or values outside that range return `error.InvalidMetadataTimestamp`.
    pub fn add_timestamp(self: *Entry, value: []const u8) !void {
        if (value.len == 0) return error.InvalidMetadataTimestamp;
        for (value) |character| {
            if (character < '0' or character > '9') return error.InvalidMetadataTimestamp;
        }
        const timestamp = std.fmt.parseInt(u64, value, 10) catch return error.InvalidMetadataTimestamp;
        if (timestamp > 253402300799) return error.InvalidMetadataTimestamp;
        self.timestamp = timestamp;
    }

    /// Appends one post-date paragraph, preferring the timestamp's UTC date and time.
    /// Falls back to the stored date when no timestamp is present.
    fn render_date(self: *Entry, allocator: Allocator) !void {
        if (self.timestamp) |timestamp| {
            const seconds: epoch.EpochSeconds = .{ .secs = timestamp };
            const year_day = seconds.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const time = seconds.getDaySeconds();
            const paragraph = try std.fmt.allocPrint(allocator, "<p class=\"post-date\">{s} {d}, {d} at {d:0>2}:{d:0>2}:{d:0>2} UTC</p>\n", .{
                months[month_day.month.numeric() - 1],
                @as(u8, month_day.day_index) + 1,
                year_day.year,
                time.getHoursIntoDay(),
                time.getMinutesIntoHour(),
                time.getSecondsIntoMinute(),
            });
            defer allocator.free(paragraph);
            try self.add_content(paragraph, allocator);
        } else if (self.date.len > 0) {
            const month = try std.fmt.parseInt(u8, self.date[5..7], 10);
            const day = try std.fmt.parseInt(u8, self.date[8..10], 10);
            const paragraph = try std.fmt.allocPrint(allocator, "<p class=\"post-date\">{s} {d}, {s}</p>\n", .{ months[month - 1], day, self.date[0..4] });
            defer allocator.free(paragraph);
            try self.add_content(paragraph, allocator);
        }
    }

    /// Frees the entry's metadata and content using their original allocator.
    pub fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.content);
        allocator.free(self.description);
        allocator.free(self.slug);
        allocator.free(self.date);
    }
};

test "create entry" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{};
    try entry.add_name("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    try expect(eql(u8, "test entry", entry.name));
}

test "add_content" {
    const test_allocator = std.testing.allocator;
    var entry: Entry = .{};
    try entry.add_name("test entry", test_allocator);
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
