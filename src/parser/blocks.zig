const std = @import("std");
const Entry = @import("../entries.zig").Entry;
const highlight = @import("../highlight.zig");
const state = @import("state.zig");
const FileParserState = state.FileParserState;
const BlockQuoteType = state.BlockQuoteType;
const parse_inline = @import("inline.zig").parse_inline;
const Io = std.Io;
const mem = std.mem;
const eql = mem.eql;
const Allocator = mem.Allocator;

/// Appends a section as an HTML heading or paragraph followed by a newline.
/// Recognizes one to five leading `#` characters followed by a space and skips
/// empty sections. Text is copied without HTML escaping; a section consisting
/// only of recognized heading markers returns `error.InvalidLine`.
pub fn parse_section(parser_state: *FileParserState, section_end: usize, entry: *Entry, allocator: Allocator) !void {
    var section: []u8 = parser_state.read_buffer[0..section_end];
    if (section.len == 0) return;
    if (section[0] == '>' and (section.len == 1 or section[1] == ' ')) {
        blk: {
            if (parser_state.section != .QUOTE_BLOCK) {
                parser_state.block_quote_type = .NONE;
                const text_start: usize = @min(2, section.len);
                const block_quote_type = std.mem.trim(u8, section[text_start..], " \t\r");
                if (BlockQuoteType.from_marker(block_quote_type)) |quote_type| {
                    parser_state.block_quote_type = quote_type;
                } else {
                    try parser_state.add_quote_text(section[text_start..], allocator);
                    break :blk;
                }
            }
        }
        parser_state.section = .QUOTE_BLOCK;
        return;
    }
    if (section.len >= 3 and mem.find(u8, section[0..3], "```") != null) {
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
    var is_list = false;
    while (count < section.len and section[count] == '#' and parser_state.section != .METADATA) : (count += 1) {
        if (count >= 5) break;
    }
    if (count >= section.len) return error.InvalidLine;
    if (count > 0 and section[count] == ' ') {
        is_header = true;
        count += 1;
        const header = try std.fmt.allocPrint(allocator, "<h{d} id=\"header-{d}\">", .{ count - 1, parser_state.header_count });
        defer allocator.free(header);
        try entry.add_content(header, allocator);
    } else if (section[count] == '-' and count + 1 < section.len) {
        is_list = true;
        try entry.add_content("<li>", allocator);
        count += 1;
    } else {
        const header = try std.fmt.allocPrint(allocator, "<p>", .{});
        defer allocator.free(header);
        try entry.add_content(header, allocator);
    }
    header_count = count;

    var content: Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    try parse_inline(section[count..], &content.writer, allocator);
    if (is_header) try parser_state.add_header(section[count..], allocator);
    try entry.add_content(content.written(), allocator);

    if (is_header) {
        const close_tag = try std.fmt.allocPrint(allocator, "</h{d}>", .{header_count - 1});
        defer allocator.free(close_tag);
        try entry.add_content(close_tag, allocator);
    } else if (is_list) {
        try entry.add_content("</li>", allocator);
    } else {
        try entry.add_content("</p>", allocator);
    }
    try entry.add_content("\n", allocator);
}

pub fn parse_quote_block(parser_state: *FileParserState, entry: *Entry, allocator: Allocator) !void {
    var html: Io.Writer.Allocating = .init(allocator);
    defer html.deinit();
    const quote_type = parser_state.block_quote_type.css_name();
    try html.writer.print("<div class=\"quote-block-{s}\">\n", .{quote_type});
    try html.writer.writeAll(parser_state.block_quote_text);
    try html.writer.writeAll("</div>\n");

    try entry.add_content(html.written(), allocator);
    parser_state.deinit_block_text(allocator);
}

// Parse Code block
pub fn parse_code_block(parser_state: *FileParserState, entry: *Entry, allocator: Allocator) !void {
    var html: Io.Writer.Allocating = .init(allocator);
    defer html.deinit();
    const language = parser_state.code_language[0..parser_state.code_language_len];
    const icon = if (eql(u8, language, "zig")) "zig" else if (eql(u8, language, "c")) "c" else if (eql(u8, language, "python")) "python" else "code";
    const label = if (eql(u8, language, "zig")) "Zig" else if (eql(u8, language, "c")) "C" else if (eql(u8, language, "python")) "Python" else if (language.len == 0) "Code" else language;
    try html.writer.print("<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-{s}.svg\" alt=\"\" width=\"20\" height=\"20\"><span>", .{icon});
    // Render the label as escaped plain text, never as markup or an asset path.
    try highlight.render(label, "", &html.writer);
    try html.writer.writeAll("</span></div>");
    // Only known language names are included in HTML attributes.
    try html.writer.writeAll(if (eql(u8, language, "zig"))
        "<pre>\n<code class=\"language-zig\">"
    else
        "<pre>\n<code>");
    try highlight.render(parser_state.code_block_text, language, &html.writer);
    try html.writer.writeAll("</code></pre></div>\n");
    try entry.add_content(html.written(), allocator);
}
