const std = @import("std");
const epoch = std.time.epoch;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const eql = std.mem.eql;

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

    /// Returns allocator-owned homepage `<time>` HTML, preferring the timestamp's
    /// UTC date. Returns an empty string when neither date nor timestamp is set.
    pub fn render_homepage_date(self: Entry, allocator: Allocator) ![]u8 {
        if (self.date.len == 0 and self.timestamp == null) return allocator.dupe(u8, "");

        var year: u16 = undefined;
        var month: u8 = undefined;
        var day: u8 = undefined;
        if (self.timestamp) |timestamp| {
            if (timestamp > 253402300799) return error.InvalidMetadataTimestamp;
            const seconds: epoch.EpochSeconds = .{ .secs = timestamp };
            const year_day = seconds.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            year = year_day.year;
            month = month_day.month.numeric();
            day = @as(u8, month_day.day_index) + 1;
        } else {
            var validated: Entry = .{};
            try validated.add_date(self.date, allocator);
            defer allocator.free(validated.date);
            year = try std.fmt.parseInt(u16, self.date[0..4], 10);
            month = try std.fmt.parseInt(u8, self.date[5..7], 10);
            day = try std.fmt.parseInt(u8, self.date[8..10], 10);
        }
        return std.fmt.allocPrint(allocator, "<time class=\"post-date\" datetime=\"{d:0>4}-{d:0>2}-{d:0>2}\">{s} {d:0>2}, {d:0>4}</time>\n", .{
            year, month, day, months[month - 1][0..3], day, year,
        });
    }

    /// Appends one post-date paragraph, preferring the timestamp's UTC date and time.
    /// Falls back to the stored date when no timestamp is present.
    pub fn render_date(self: *Entry, allocator: Allocator) !void {
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

test "render_homepage_date" {
    const allocator = std.testing.allocator;
    const dated: Entry = .{ .date = "2026-10-01" };
    const date_html = try dated.render_homepage_date(allocator);
    defer allocator.free(date_html);
    try std.testing.expectEqualStrings("<time class=\"post-date\" datetime=\"2026-10-01\">Oct 01, 2026</time>\n", date_html);

    const timestamped: Entry = .{ .date = "2026-10-01", .timestamp = 0 };
    const timestamp_html = try timestamped.render_homepage_date(allocator);
    defer allocator.free(timestamp_html);
    try std.testing.expectEqualStrings("<time class=\"post-date\" datetime=\"1970-01-01\">Jan 01, 1970</time>\n", timestamp_html);

    const undated: Entry = .{};
    const empty = try undated.render_homepage_date(allocator);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const invalid: Entry = .{ .date = "2026-02-30" };
    try std.testing.expectError(error.InvalidMetadataDate, invalid.render_homepage_date(allocator));
    const invalid_timestamp: Entry = .{ .timestamp = 253402300800 };
    try std.testing.expectError(error.InvalidMetadataTimestamp, invalid_timestamp.render_homepage_date(allocator));
}

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
