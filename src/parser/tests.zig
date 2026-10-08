const std = @import("std");
const create_entries = @import("parser.zig").create_entries;
const Entry = @import("../entries.zig").Entry;
const parser_state = @import("state.zig");
const FileParserState = parser_state.FileParserState;
const Section = parser_state.Section;
const strip_newline = parser_state.strip_newline;
const blocks = @import("blocks.zig");
const parse_section = blocks.parse_section;
const parse_code_block = blocks.parse_code_block;
const parse_quote_block = blocks.parse_quote_block;
const parse_metadata = @import("metadata.zig").parse_metadata;
const create_toc = @import("toc.zig").create_toc;
const Io = std.Io;

const Dir = Io.Dir;

const mem = std.mem;

const Allocator = std.mem.Allocator;

const expect = std.testing.expect;
const eql = std.mem.eql;

// Tests and test helpers.

fn test_add_headers(allocator: Allocator) !void {
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);
    try state.add_header("First heading", allocator);
    try state.add_header("Second heading", allocator);
    try std.testing.expectEqual(@as(u8, 2), state.header_count);
    try std.testing.expectEqualStrings("First heading", state.headers[0]);
    try std.testing.expectEqualStrings("Second heading", state.headers[1]);
}

test "FileParserState add_header is safe at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_add_headers, .{});
}

test "FileParserState add_code_text appends only the requested buffer prefix" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    @memcpy(state.read_buffer[0..12], "first\nunused");
    try state.add_code_text(6, allocator);
    try std.testing.expectEqualStrings("first\n", state.code_block_text);

    @memcpy(state.read_buffer[0..13], "second\nunused");
    try state.add_code_text(7, allocator);
    try std.testing.expectEqualStrings("first\nsecond\n", state.code_block_text);
    try std.testing.expectEqualStrings("second\nunused", state.read_buffer[0..13]);
}

test "FileParserState add_code_text accepts zero bytes" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    try state.add_code_text(0, allocator);
    try std.testing.expectEqual(@as(usize, 0), state.code_block_text.len);

    @memcpy(state.read_buffer[0..4], "code");
    try state.add_code_text(4, allocator);
    try state.add_code_text(0, allocator);
    try std.testing.expectEqualStrings("code", state.code_block_text);
}

test "FileParserState add_code_text copies a full read buffer" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    @memset(&state.read_buffer, 'x');
    try state.add_code_text(state.read_buffer.len, allocator);
    try std.testing.expectEqualSlices(u8, &state.read_buffer, state.code_block_text);
}

test "FileParserState add_code_text preserves existing text on allocation failure" {
    var storage: [4]u8 = undefined;
    var fixed_buffer: std.heap.FixedBufferAllocator = .init(&storage);
    const allocator = fixed_buffer.allocator();
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    @memcpy(state.read_buffer[0..4], "code");
    try state.add_code_text(4, allocator);
    try std.testing.expectError(error.OutOfMemory, state.add_code_text(1, allocator));
    try std.testing.expectEqualStrings("code", state.code_block_text);
}

test "FileParserState deinit_code_text clears text and allows reuse" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    @memcpy(state.read_buffer[0..5], "first");
    try state.add_code_text(5, allocator);
    state.deinit_code_text(allocator);
    try std.testing.expectEqual(@as(usize, 0), state.code_block_text.len);

    @memcpy(state.read_buffer[0..6], "second");
    try state.add_code_text(6, allocator);
    try std.testing.expectEqualStrings("second", state.code_block_text);
}

test "FileParserState deinit_code_text accepts empty and already cleared text" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    state.deinit_code_text(allocator);
    @memcpy(state.read_buffer[0..4], "code");
    try state.add_code_text(4, allocator);
    state.deinit_code_text(allocator);
    state.deinit_code_text(allocator);
    try std.testing.expectEqual(@as(usize, 0), state.code_block_text.len);
}

test "FileParserState deinit frees code text and accepts empty text" {
    const allocator = std.testing.allocator;
    var empty: FileParserState = .{ .file = undefined };
    empty.deinit(allocator);

    var populated: FileParserState = .{ .file = undefined };
    defer populated.deinit(allocator);
    populated.code_block_text = try allocator.dupe(u8, "allocated code\n");
    // std.testing.allocator reports a leak if deinit does not free this text.
}

// Set up the buffered state expected by the parser while keeping test cases concise.
fn test_parse_section(section: []const u8, entry: *Entry, allocator: Allocator) !void {
    var state: FileParserState = .{ .file = undefined, .section = .NORMAL_MODE };
    defer state.deinit(allocator);
    @memcpy(state.read_buffer[0..section.len], section);
    state.used = section.len;
    try parse_section(&state, section.len, entry, allocator);
}

fn test_parse_metadata(metadata: []const u8, entry: *Entry, allocator: Allocator) !void {
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);
    @memcpy(state.read_buffer[0..4], "---\n");
    @memcpy(state.read_buffer[4 .. 4 + metadata.len], metadata);
    state.used = 4 + metadata.len;
    try parse_metadata(&state, state.used - 1, entry, allocator);
}

test "parse_section with header" {
    const test_allocator: std.mem.Allocator = std.testing.allocator;
    var entry: Entry = .{};
    try entry.add_name("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    const section: []const u8 = "# Test header";
    try test_parse_section(section, &entry, test_allocator);
    try expect(eql(u8, "<h1 id=\"header-0\">Test header</h1>\n", entry.content));
}

test "parse_section with header 2" {
    const test_allocator: std.mem.Allocator = std.testing.allocator;
    var entry: Entry = .{};
    try entry.add_name("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    const section: []const u8 = "## Test header";
    try test_parse_section(section, &entry, test_allocator);
    try expect(eql(u8, "<h2 id=\"header-0\">Test header</h2>\n", entry.content));
}

test "parse_section paragraph" {
    const test_allocator: std.mem.Allocator = std.testing.allocator;
    var entry: Entry = .{};
    try entry.add_name("test entry", test_allocator);
    defer entry.deinit(test_allocator);
    const section: []const u8 = "some # test entry!";
    try test_parse_section(section, &entry, test_allocator);
    try expect(eql(u8, "<p>some # test entry!</p>\n", entry.content));
}

test "parse_section renders inline bold and italic with both delimiters" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { section: []const u8, html: []const u8 }{
        .{ .section = "*a*", .html = "<p><span class=\"italic\">a</span></p>\n" },
        .{ .section = "_a_", .html = "<p><span class=\"italic\">a</span></p>\n" },
        .{ .section = "**a**", .html = "<p><span class=\"bold\">a</span></p>\n" },
        .{ .section = "__a__", .html = "<p><span class=\"bold\">a</span></p>\n" },
        .{ .section = "Before **bold text** and _italic text_ after.", .html = "<p>Before <span class=\"bold\">bold text</span> and <span class=\"italic\">italic text</span> after.</p>\n" },
        .{ .section = "*one* **two** _three_ __four__", .html = "<p><span class=\"italic\">one</span> <span class=\"bold\">two</span> <span class=\"italic\">three</span> <span class=\"bold\">four</span></p>\n" },
        .{ .section = "**bold***italic*", .html = "<p><span class=\"bold\">bold</span><span class=\"italic\">italic</span></p>\n" },
        .{ .section = "## A **bold** heading", .html = "<h2 id=\"header-0\">A <span class=\"bold\">bold</span> heading</h2>\n" },
        .{ .section = "- An _italic_ item", .html = "<li> An <span class=\"italic\">italic</span> item</li>\n" },
        .{ .section = "*See* [Example](https://example.com) **today**.", .html = "<p><span class=\"italic\">See</span> \n<a href=\"https://example.com\">Example</a>\n <span class=\"bold\">today</span>.</p>\n" },
    };
    for (cases) |case| {
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        try test_parse_section(case.section, &entry, allocator);
        try std.testing.expectEqualStrings(case.html, entry.content);
    }
}

test "parse_section preserves unmatched and empty emphasis markers" {
    const allocator = std.testing.allocator;
    const sections = [_][]const u8{
        "*",                  "_",                   "**",      "__",      "***",      "___",              "****",               "____",
        "Before *unfinished", "Before __unfinished", "**bold*", "__bold_", "*italic_", "Trailing marker*", "Trailing markers**",
    };
    for (sections) |section| {
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        const html = try std.fmt.allocPrint(allocator, "<p>{s}</p>\n", .{section});
        defer allocator.free(html);
        try test_parse_section(section, &entry, allocator);
        try std.testing.expectEqualStrings(html, entry.content);
    }
}

test "parse_section keeps extra closing markers inside italic text" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { section: []const u8, html: []const u8 }{
        .{ .section = "**what** *test** **what**", .html = "<p><span class=\"bold\">what</span> <span class=\"italic\">test*</span> <span class=\"bold\">what</span></p>\n" },
        .{ .section = "__what__ _test__ __what__", .html = "<p><span class=\"bold\">what</span> <span class=\"italic\">test_</span> <span class=\"bold\">what</span></p>\n" },
        .{ .section = "*test**", .html = "<p><span class=\"italic\">test*</span></p>\n" },
        .{ .section = "*test*** *valid*", .html = "<p><span class=\"italic\">test**</span> <span class=\"italic\">valid</span></p>\n" },
    };
    for (cases) |case| {
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        try test_parse_section(case.section, &entry, allocator);
        try std.testing.expectEqualStrings(case.html, entry.content);
    }
}

test "parse_section renders italic inside bold" {
    const allocator = std.testing.allocator;
    const sections = [_][]const u8{
        "**what *test* what**",
        "__what _test_ what__",
        "**what _test_ what**",
        "__what *test* what__",
    };
    for (sections) |section| {
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        try test_parse_section(section, &entry, allocator);
        try std.testing.expectEqualStrings("<p><span class=\"bold\">what <span class=\"italic\">test</span> what</span></p>\n", entry.content);
    }
}

test "parse_section renders a link" {
    const allocator = std.testing.allocator;
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(allocator);

    try test_parse_section("[Example](https://example.com)", &entry, allocator);

    try std.testing.expectEqualStrings("<p>\n<a href=\"https://example.com\">Example</a>\n</p>\n", entry.content);
}

test "parse_section preserves text around links in paragraphs and headings" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { section: []const u8, html: []const u8 }{
        .{
            .section = "Visit [Example](https://example.com) today.",
            .html = "<p>Visit \n<a href=\"https://example.com\">Example</a>\n today.</p>\n",
        },
        .{
            .section = "## Visit [Example](https://example.com)",
            .html = "<h2 id=\"header-0\">Visit \n<a href=\"https://example.com\">Example</a>\n</h2>\n",
        },
        .{
            .section = "[One](https://example.com/one) and [Two](https://example.com/two).",
            .html = "<p>\n<a href=\"https://example.com/one\">One</a>\n and \n<a href=\"https://example.com/two\">Two</a>\n.</p>\n",
        },
    };
    for (cases) |case| {
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        try test_parse_section(case.section, &entry, allocator);
        try std.testing.expectEqualStrings(case.html, entry.content);
    }
}

test "parse_section renders supported image extensions with alt text" {
    const allocator = std.testing.allocator;
    // This parser identifies images by extension, using [alt](url) without '!'.
    const extensions = [_][]const u8{ "jpg", "jpeg", "png", "gif" };
    for (extensions) |extension| {
        const section = try std.fmt.allocPrint(allocator, "Before [A photo](https://example.com/photo.{s}) after.", .{extension});
        defer allocator.free(section);
        const html = try std.fmt.allocPrint(allocator, "<p>Before \n<img src=\"https://example.com/photo.{s}\" alt=\"A photo\"> after.</p>\n", .{extension});
        defer allocator.free(html);
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);

        try test_parse_section(section, &entry, allocator);
        try std.testing.expectEqualStrings(html, entry.content);
    }
}

test "parse_section preserves incomplete link syntax as plain text" {
    const allocator = std.testing.allocator;
    const sections = [_][]const u8{
        "[",
        "[label",
        "[label]",
        "[label](https://example.com",
        "[label] https://example.com",
    };
    for (sections) |section| {
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        const html = try std.fmt.allocPrint(allocator, "<p>{s}</p>\n", .{section});
        defer allocator.free(html);

        try test_parse_section(section, &entry, allocator);
        try std.testing.expectEqualStrings(html, entry.content);
    }
}

test "create_toc omits empty headings and renders working anchor links" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);
    var entry: Entry = .{};
    try entry.add_name("Post", allocator);
    defer entry.deinit(allocator);

    try create_toc(&state, &entry, allocator);
    try std.testing.expectEqualStrings("", entry.table_of_contents);

    try state.add_header("Introduction", allocator);
    try state.add_header("Next section", allocator);
    try create_toc(&state, &entry, allocator);
    try std.testing.expectEqualStrings(
        "<nav class=\"table-of-contents\" aria-label=\"Table of contents\">\n" ++
            "<h2>Table of Contents</h2>\n<ol>\n" ++
            "<li><a href=\"#header-0\">Introduction</a></li>\n" ++
            "<li><a href=\"#header-1\">Next section</a></li>\n" ++
            "</ol>\n</nav>",
        entry.table_of_contents,
    );
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
    try test_parse_section("Welcome to my blog.", &entry, test_allocator);

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
    try test_parse_section("Welcome to my blog.", &entry, test_allocator);

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

test "create_entries records complete formatted headings once with matching TOC anchors" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    try markdown.dir.writeFile(io, .{
        .sub_path = "headings.md",
        .data = "---\nname: Headings\ntoc: true\n---\n# Before **bold _nested_** after\nParagraph with *emphasis*.\n## Visit [Example](https://example.com) today\n### Last\n",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqual(@as(usize, 1), posts.len);
    try std.testing.expectEqualStrings(
        "<h1 id=\"header-0\">Before <span class=\"bold\">bold <span class=\"italic\">nested</span></span> after</h1>\n" ++
            "<p>Paragraph with <span class=\"italic\">emphasis</span>.</p>\n" ++
            "<h2 id=\"header-1\">Visit \n<a href=\"https://example.com\">Example</a>\n today</h2>\n" ++
            "<h3 id=\"header-2\">Last</h3>\n",
        posts[0].content,
    );
    try std.testing.expectEqualStrings(
        "<nav class=\"table-of-contents\" aria-label=\"Table of contents\">\n" ++
            "<h2>Table of Contents</h2>\n<ol>\n" ++
            "<li><a href=\"#header-0\">Before **bold _nested_** after</a></li>\n" ++
            "<li><a href=\"#header-1\">Visit [Example](https://example.com) today</a></li>\n" ++
            "<li><a href=\"#header-2\">Last</a></li>\n" ++
            "</ol>\n</nav>",
        posts[0].table_of_contents,
    );
}

fn test_create_entries_allocations(allocator: Allocator, markdown_dir: Dir, io: Io) !void {
    // Allocating writers report allocation failures as WriteFailed; the testing
    // utility expects OutOfMemory for the injected allocator failure.
    const posts = create_entries(markdown_dir, io, allocator) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqual(@as(usize, 2), posts.len);
}

test "create_entries cleans up each allocation failure including previously parsed entries" {
    const io = std.testing.io;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    const data = "---\nname: Post\ntoc: true\n---\n# Heading\nBody\n";
    try markdown.dir.writeFile(io, .{ .sub_path = "first.md", .data = data });
    try markdown.dir.writeFile(io, .{ .sub_path = "second.md", .data = data });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_create_entries_allocations, .{ markdown.dir, io });
}

test "create_entries propagates parse and read errors while freeing partial state" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    const cases = [_]struct { data: []const u8, err: anyerror }{
        .{ .data = "---\nname: Partial\n", .err = error.FailedToParseMetadata },
        .{ .data = "---\nname: Partial\n---\n# Heading\n```zig\nconst x = 1;\n", .err = error.EndOfCodeBlockNotFound },
        .{ .data = "---\nname: Partial\n---\n# Heading\n###\n", .err = error.InvalidLine },
    };
    for (cases) |case| {
        try markdown.dir.writeFile(io, .{ .sub_path = "partial.md", .data = case.data });
        try std.testing.expectError(case.err, create_entries(markdown.dir, io, allocator));
    }
}

test "create_entries preserves quote text and following paragraphs" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    try markdown.dir.writeFile(io, .{
        .sub_path = "quote.md",
        .data = "---\nname: Quote\n---\n> test\n> test quote block\n\nsomething here\n> [!NOTE]\n> note\nAfter\n> [!IMPORTANT]\n> important\nAfter again\n> <last> & quote\n> final",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqualStrings(
        "<div class=\"quote-block-none\">\n<p>test</p>\n<p>test quote block</p>\n</div>\n" ++
            "<p>something here</p>\n" ++
            "<div class=\"quote-block-note\">\n<p>note</p>\n</div>\n<p>After</p>\n" ++
            "<div class=\"quote-block-important\">\n<p>important</p>\n</div>\n<p>After again</p>\n" ++
            "<div class=\"quote-block-none\">\n<p>&lt;last&gt; &amp; quote</p>\n<p>final</p>\n</div>\n",
        posts[0].content,
    );
}

test "quote markers render their matching CSS classes" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { marker: []const u8, class: []const u8 }{
        .{ .marker = "[!NOTE]", .class = "note" },
        .{ .marker = "[!IMPORTANT]", .class = "important" },
        .{ .marker = "[!DANGER]", .class = "danger" },
        .{ .marker = "[!HELP]", .class = "help" },
        .{ .marker = "[!FAIL]", .class = "fail" },
        .{ .marker = "[!FAILURE]", .class = "failure" },
        .{ .marker = "[!TODO]", .class = "todo" },
        .{ .marker = "[!INFO]", .class = "info" },
        .{ .marker = "[!QUOTE]", .class = "quote" },
    };
    for (cases) |case| {
        var state: FileParserState = .{ .file = undefined, .section = .NORMAL_MODE };
        defer state.deinit(allocator);
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        const section = try std.fmt.allocPrint(allocator, "> {s}", .{case.marker});
        defer allocator.free(section);
        @memcpy(state.read_buffer[0..section.len], section);
        try parse_section(&state, section.len, &entry, allocator);
        try std.testing.expectEqual(Section.QUOTE_BLOCK, state.section);
        try state.add_quote_text("<text> & content", allocator);
        try parse_quote_block(&state, &entry, allocator);
        const expected = try std.fmt.allocPrint(allocator, "<div class=\"quote-block-{s}\">\n<p>&lt;text&gt; &amp; content</p>\n</div>\n", .{case.class});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, entry.content);
    }
}

test "unknown quote markers remain ordinary quote text" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined, .section = .NORMAL_MODE };
    defer state.deinit(allocator);
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(allocator);
    const section = "> [!UNKNOWN]";
    @memcpy(state.read_buffer[0..section.len], section);
    try parse_section(&state, section.len, &entry, allocator);
    try parse_quote_block(&state, &entry, allocator);
    try std.testing.expectEqualStrings("<div class=\"quote-block-none\">\n<p>[!UNKNOWN]</p>\n</div>\n", entry.content);
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
            try std.testing.expectEqualStrings("<p class=\"post-date\">October 1, 2026</p>\n<h1 id=\"header-0\">First heading</h1>\n<p>First body.</p>\n", post.content);
        } else {
            try std.testing.expectEqualStrings("second", post.slug);
            try std.testing.expectEqualStrings("Second", post.name);
            try std.testing.expectEqualStrings("<p class=\"post-date\">January 1, 1970 at 00:00:00 UTC</p>\n<h2 id=\"header-0\">Second heading</h2>\n<p>Second body.</p>\n", post.content);
        }
    }
    try expect(!eql(u8, posts[0].slug, posts[1].slug));
}

test "code block integration highlights Zig" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    try markdown.dir.writeFile(io, .{
        .sub_path = "code.md",
        .data = "---\nname: Code\nslug: code\n---\n```zig\nconst answer = 42;\n```\nAfter\n",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqualStrings(
        "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-zig.svg\" alt=\"\" width=\"20\" height=\"20\"><span>Zig</span></div><pre>\n<code class=\"language-zig\"><span class=\"tok-keyword\">const</span> answer <span class=\"tok-operator\">=</span> <span class=\"tok-number\">42</span>;\n</code></pre></div>\n<p>After</p>\n",
        posts[0].content,
    );
}

test "code block integration escapes plain code without stale languages" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    try markdown.dir.writeFile(io, .{
        .sub_path = "code.md",
        .data = "---\nname: Code\n---\n```zig\nconst x = 42;\n```\n```c\n<a> & 42\n```\n```\nconst x = 42;\n```\n",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqualStrings(
        "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-zig.svg\" alt=\"\" width=\"20\" height=\"20\"><span>Zig</span></div><pre>\n<code class=\"language-zig\"><span class=\"tok-keyword\">const</span> x <span class=\"tok-operator\">=</span> <span class=\"tok-number\">42</span>;\n</code></pre></div>\n" ++
            "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-c.svg\" alt=\"\" width=\"20\" height=\"20\"><span>C</span></div><pre>\n<code>&lt;a&gt; &amp; 42\n</code></pre></div>\n" ++
            "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-code.svg\" alt=\"\" width=\"20\" height=\"20\"><span>Code</span></div><pre>\n<code>const x = 42;\n</code></pre></div>\n",
        posts[0].content,
    );
}

test "code block integration shows Python and safely labels unknown languages" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { language: []const u8, icon: []const u8, label: []const u8 }{
        .{ .language = "python", .icon = "python", .label = "Python" },
        .{ .language = "rust", .icon = "code", .label = "rust" },
        .{ .language = "<img>&", .icon = "code", .label = "&lt;img&gt;&amp;" },
    };
    for (cases) |case| {
        var state: FileParserState = .{ .file = undefined };
        defer state.deinit(allocator);
        try state.change_language(case.language);
        @memcpy(state.read_buffer[0..5], "hello");
        try state.add_code_text(5, allocator);
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        try parse_code_block(&state, &entry, allocator);
        const expected = try std.fmt.allocPrint(
            allocator,
            "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-{s}.svg\" alt=\"\" width=\"20\" height=\"20\"><span>{s}</span></div><pre>\n<code>hello</code></pre></div>\n",
            .{ case.icon, case.label },
        );
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, entry.content);
    }
}
