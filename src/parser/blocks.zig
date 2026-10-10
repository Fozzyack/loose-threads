const std = @import("std");
const Entry = @import("../entries.zig").Entry;
const highlight = @import("../highlight.zig");
const FileParserState = @import("state.zig").FileParserState;
const BlockQuoteType = @import("state.zig").BlockQuoteType;
const Section = @import("state.zig").Section;
const ListType = @import("state.zig").ListType;
const flush = @import("flush.zig");
const parse_inline = @import("inline.zig").parse_inline;
const Io = std.Io;
const mem = std.mem;
const eql = mem.eql;
const Allocator = mem.Allocator;
const expect = std.testing.expect;

/// Renders a block line, buffering ordinary text until its paragraph ends.
pub fn parse_section(parser_state: *FileParserState, section_end: usize, entry: *Entry) !void {
    const section = mem.trimEnd(u8, parser_state.read_buffer[0..section_end], "\r");
    if (section.len == 0) return;
    var list_type: ListType = .none;
    var text_start: usize = 0;
    if (section.len >= 2 and section[0] == '-' and section[1] == ' ') {
        list_type = .unordered;
        text_start = 2;
    } else {
        var digits: usize = 0;
        while (digits < section.len and std.ascii.isDigit(section[digits])) : (digits += 1) {}
        if (digits > 0 and digits + 1 < section.len and section[digits] == '.' and section[digits + 1] == ' ') {
            list_type = .ordered;
            text_start = digits + 2;
        }
    }
    if (list_type != .none) {
        try flush.flush_paragraph(parser_state, entry);
        if (parser_state.list_type != list_type) {
            try flush.close_list(parser_state, entry);
            try entry.add_content(if (list_type == .unordered) "<ul>\n" else "<ol>\n", parser_state.allocator);
            parser_state.list_type = list_type;
        }
        var item: Io.Writer.Allocating = .init(parser_state.allocator);
        defer item.deinit();
        try item.writer.writeAll("<li>");
        try parse_inline(section[text_start..], &item.writer, parser_state.allocator);
        try item.writer.writeAll("</li>\n");
        try entry.add_content(item.written(), parser_state.allocator);
        return;
    }
    try flush.close_list(parser_state, entry);
    if (eql(u8, section, "---")) {
        try flush.flush_blocks(parser_state, entry);
        try entry.add_content("<hr>\n", parser_state.allocator);
        return;
    }
    if (section[0] == '>' and (section.len == 1 or section[1] == ' ')) {
        try flush.flush_blocks(parser_state, entry);
        blk: {
            if (parser_state.section != .QUOTE_BLOCK) {
                parser_state.block_quote_type = .NONE;
                const quote_start: usize = @min(2, section.len);
                const block_quote_type = std.mem.trim(u8, section[quote_start..], " \t\r");
                if (BlockQuoteType.from_marker(block_quote_type)) |quote_type| {
                    parser_state.block_quote_type = quote_type;
                } else {
                    try parser_state.add_quote_text(section[quote_start..]);
                    break :blk;
                }
            }
        }
        parser_state.section = .QUOTE_BLOCK;
        return;
    }
    if (section.len >= 3 and mem.find(u8, section[0..3], "```") != null) {
        try flush.flush_blocks(parser_state, entry);
        if (parser_state.section != .QUOTE_BLOCK) {
            const language = std.mem.trim(u8, section[3..], " \t\r");
            try parser_state.change_language(language);
        } else return;
        parser_state.section = .CODE_BLOCK;
        return;
    }
    var count: usize = 0;
    var header_count: usize = 0;
    var is_header = false;
    while (count < section.len and section[count] == '#' and parser_state.section != .METADATA) : (count += 1) {
        if (count >= 5) break;
    }
    if (count >= section.len) return error.InvalidLine;
    if (count > 0 and section[count] == ' ') {
        is_header = true;
        count += 1;
        try flush.flush_blocks(parser_state, entry);
        const header = try std.fmt.allocPrint(parser_state.allocator, "<h{d} id=\"header-{d}\">", .{ count - 1, parser_state.header_count });
        defer parser_state.allocator.free(header);
        try entry.add_content(header, parser_state.allocator);
    } else {
        count = 0;
        try parser_state.add_paragraph(if (parser_state.paragraph.len == 0) "<p>" else "\n");
    }
    header_count = count;

    var content: Io.Writer.Allocating = .init(parser_state.allocator);
    defer content.deinit();
    try parse_inline(section[count..], &content.writer, parser_state.allocator);
    if (is_header) try parser_state.add_header(section[count..]);
    if (!is_header) {
        try parser_state.add_paragraph(content.written());
        return;
    }
    try entry.add_content(content.written(), parser_state.allocator);

    if (is_header) {
        const close_tag = try std.fmt.allocPrint(parser_state.allocator, "</h{d}>", .{header_count - 1});
        defer parser_state.allocator.free(close_tag);
        try entry.add_content(close_tag, parser_state.allocator);
    }
    try entry.add_content("\n", parser_state.allocator);
}

pub fn parse_quote_block(parser_state: *FileParserState, entry: *Entry) !void {
    var html: Io.Writer.Allocating = .init(parser_state.allocator);
    defer html.deinit();
    const quote_type = parser_state.block_quote_type.css_name();
    try html.writer.print("<div class=\"quote-block quote-block-{s}\"><p>\n", .{quote_type});
    try parse_inline(parser_state.block_quote_text, &html.writer, parser_state.allocator);
    try html.writer.writeAll("</p></div>\n");

    try entry.add_content(html.written(), parser_state.allocator);
    parser_state.deinit_block_text();
}

// Parse Code block
pub fn parse_code_block(parser_state: *FileParserState, entry: *Entry) !void {
    var html: Io.Writer.Allocating = .init(parser_state.allocator);
    defer html.deinit();
    const language = parser_state.code_language[0..parser_state.code_language_len];
    const icon = if (eql(u8, language, "zig")) "zig" else if (eql(u8, language, "c")) "c" else if (eql(u8, language, "python")) "python" else "code";
    const label = if (eql(u8, language, "zig")) "Zig" else if (eql(u8, language, "c")) "C" else if (eql(u8, language, "python")) "Python" else if (eql(u8, language, "json")) "JSON" else if (eql(u8, language, "bash")) "Bash" else if (eql(u8, language, "sh")) "Shell" else if (language.len == 0) "Code" else language;
    try html.writer.print("<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-{s}.svg\" alt=\"\" width=\"20\" height=\"20\"><span>", .{icon});
    // Render the label as escaped plain text, never as markup or an asset path.
    try highlight.render(label, "", &html.writer);
    try html.writer.writeAll("</span></div>");
    // Only known language names are included in HTML attributes.
    try html.writer.writeAll(if (eql(u8, language, "zig"))
        "<pre>\n<code class=\"language-zig\">"
    else if (eql(u8, language, "python"))
        "<pre>\n<code class=\"language-python\">"
    else if (eql(u8, language, "c"))
        "<pre>\n<code class=\"language-c\">"
    else if (eql(u8, language, "json"))
        "<pre>\n<code class=\"language-json\">"
    else if (eql(u8, language, "sh") or eql(u8, language, "bash"))
        "<pre>\n<code class=\"language-bash\">"
    else
        "<pre>\n<code>");
    try highlight.render(parser_state.code_block_text, language, &html.writer);
    try html.writer.writeAll("</code></pre></div>\n");
    try entry.add_content(html.written(), parser_state.allocator);
}

// Set up the buffered state expected by the parser while keeping test cases concise.
fn test_parse_section(section: []const u8, entry: *Entry, allocator: Allocator) !void {
    var state: FileParserState = .{ .allocator = allocator, .file = undefined, .section = .NORMAL_MODE };
    defer state.deinit();
    @memcpy(state.read_buffer[0..section.len], section);
    state.used = section.len;
    try parse_section(&state, section.len, entry);
    try flush.flush_blocks(&state, entry);
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
        .{ .section = "- An _italic_ item", .html = "<ul>\n<li>An <span class=\"italic\">italic</span> item</li>\n</ul>\n" },
        .{ .section = "*See* [Example](https://example.com) **today**.", .html = "<p><span class=\"italic\">See</span> \n<a href=\"https://example.com\">Example</a>\n <span class=\"bold\">today</span>.</p>\n" },
    };
    for (cases) |case| {
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        try test_parse_section(case.section, &entry, allocator);
        try std.testing.expectEqualStrings(case.html, entry.content);
    }
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
        var state: FileParserState = .{ .allocator = allocator, .file = undefined, .section = .NORMAL_MODE };
        defer state.deinit();
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        const section = try std.fmt.allocPrint(allocator, "> {s}", .{case.marker});
        defer allocator.free(section);
        @memcpy(state.read_buffer[0..section.len], section);
        try parse_section(&state, section.len, &entry);
        try std.testing.expectEqual(Section.QUOTE_BLOCK, state.section);
        try state.add_quote_text("<text> & content");
        try parse_quote_block(&state, &entry);
        const expected = try std.fmt.allocPrint(allocator, "<div class=\"quote-block quote-block-{s}\">\n<p>&lt;text&gt; &amp; content</p>\n</div>\n", .{case.class});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, entry.content);
    }
}

test "unknown quote markers remain ordinary quote text" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .allocator = allocator, .file = undefined, .section = .NORMAL_MODE };
    defer state.deinit();
    var entry: Entry = .{ .name = &.{} };
    defer entry.deinit(allocator);
    const section = "> [!UNKNOWN]";
    @memcpy(state.read_buffer[0..section.len], section);
    try parse_section(&state, section.len, &entry);
    try parse_quote_block(&state, &entry);
    try std.testing.expectEqualStrings("<div class=\"quote-block quote-block-none\">\n<p>[!UNKNOWN]</p>\n</div>\n", entry.content);
}

test "parse_code_block shows Python and safely labels unknown languages" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { language: []const u8, icon: []const u8, label: []const u8, class: []const u8 }{
        .{ .language = "zig", .icon = "zig", .label = "Zig", .class = " class=\"language-zig\"" },
        .{ .language = "python", .icon = "python", .label = "Python", .class = " class=\"language-python\"" },
        .{ .language = "c", .icon = "c", .label = "C", .class = " class=\"language-c\"" },
        .{ .language = "json", .icon = "code", .label = "JSON", .class = " class=\"language-json\"" },
        .{ .language = "sh", .icon = "code", .label = "Shell", .class = " class=\"language-bash\"" },
        .{ .language = "bash", .icon = "code", .label = "Bash", .class = " class=\"language-bash\"" },
        .{ .language = "", .icon = "code", .label = "Code", .class = "" },
        .{ .language = "rust", .icon = "code", .label = "rust", .class = "" },
        .{ .language = "<img>&", .icon = "code", .label = "&lt;img&gt;&amp;", .class = "" },
    };
    for (cases) |case| {
        var state: FileParserState = .{ .allocator = allocator, .file = undefined };
        defer state.deinit();
        try state.change_language(case.language);
        var entry: Entry = .{ .name = &.{} };
        defer entry.deinit(allocator);
        try parse_code_block(&state, &entry);
        const expected = try std.fmt.allocPrint(
            allocator,
            "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-{s}.svg\" alt=\"\" width=\"20\" height=\"20\"><span>{s}</span></div><pre>\n<code{s}></code></pre></div>\n",
            .{ case.icon, case.label, case.class },
        );
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, entry.content);
    }
}
