const std = @import("std");
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() ?*const ts.TSLanguage;

const TreeSitterParserError = error{ OutOfMemory, ParseFailed, MissingZigGrammar, IncompatibleGrammar, InvalidHighlightQuery, OverlappingErrors, UnknownCapture, CodeBlockTooLarge };

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(byte),
        }
    }
}

/// Writes escaped code, highlighting the currently supported Zig tokens.
/// Unknown or omitted languages are rendered as plain escaped text.
pub fn render(source: []const u8, language_name: []const u8, writer: *std.Io.Writer) !void {
    if (!std.mem.eql(u8, language_name, "zig")) {
        try writeEscaped(writer, source);
        return;
    }
    if (source.len > std.math.maxInt(u32)) return TreeSitterParserError.CodeBlockTooLarge;

    const parser = ts.ts_parser_new() orelse
        return TreeSitterParserError.OutOfMemory;
    defer ts.ts_parser_delete(parser);

    const language = tree_sitter_zig() orelse
        return TreeSitterParserError.MissingZigGrammar;

    if (!ts.ts_parser_set_language(parser, language)) {
        return TreeSitterParserError.IncompatibleGrammar;
    }

    const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return TreeSitterParserError.ParseFailed;
    defer ts.ts_tree_delete(tree);

    const root = ts.ts_tree_root_node(tree);

    const query_source =
        \\"const" @keyword
        \\(integer) @number
    ;
    var error_offset: u32 = 0;
    var error_type: ts.TSQueryError = ts.TSQueryErrorNone;

    const query = ts.ts_query_new(language, query_source.ptr, @intCast(query_source.len), &error_offset, &error_type) orelse {
        std.debug.print(
            "Invalid highlight query at byte {d}, error type {d}\n",
            .{ error_offset, error_type },
        );
        return TreeSitterParserError.InvalidHighlightQuery;
    };
    defer ts.ts_query_delete(query);

    const cursor = ts.ts_query_cursor_new() orelse
        return TreeSitterParserError.OutOfMemory;
    defer ts.ts_query_cursor_delete(cursor);

    ts.ts_query_cursor_exec(cursor, query, root);
    var position: usize = 0;
    var match: ts.TSQueryMatch = undefined;
    var capture_index: u32 = 0;

    while (ts.ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
        const capture = match.captures[capture_index];

        const start = ts.ts_node_start_byte(capture.node);
        const end = ts.ts_node_end_byte(capture.node);

        var name_len: u32 = 0;
        const name = ts.ts_query_capture_name_for_id(query, capture.index, &name_len);

        const capture_name = name[0..name_len];

        // This initial query produces non-overlapping captures.
        if (start < position) return TreeSitterParserError.OverlappingErrors;

        try writeEscaped(writer, source[position..start]);

        const opening_tag = if (std.mem.eql(u8, capture_name, "keyword"))
            "<span class=\"tok-keyword\">"
        else if (std.mem.eql(u8, capture_name, "number"))
            "<span class=\"tok-number\">"
        else
            return TreeSitterParserError.UnknownCapture;

        try writer.writeAll(opening_tag);
        try writeEscaped(writer, source[start..end]);
        try writer.writeAll("</span>");
        position = end;
    }

    try writeEscaped(writer, source[position..]);
}

test "writeEscaped preserves whitespace and escapes HTML characters" {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();

    try writeEscaped(&html.writer, "\tif (a < b && b > 0) {\n}\n");
    try std.testing.expectEqualStrings("\tif (a &lt; b &amp;&amp; b &gt; 0) {\n}\n", html.written());
}

test "render highlights Zig keywords and numbers" {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try render("const answer = 42;\n", "zig", &html.writer);
    try std.testing.expectEqualStrings("<span class=\"tok-keyword\">const</span> answer = <span class=\"tok-number\">42</span>;\n", html.written());
}

test "render escapes unknown and omitted languages" {
    for ([_][]const u8{ "", "c", "unknown" }) |language| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render("\t<a> & 42\n\n", language, &html.writer);
        try std.testing.expectEqualStrings("\t&lt;a&gt; &amp; 42\n\n", html.written());
    }
}

test "render escapes uncaptured Zig source and handles empty source" {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try render("", "zig", &html.writer);
    try std.testing.expectEqualStrings("", html.written());
    try render("a < b && b > c", "zig", &html.writer);
    try std.testing.expectEqualStrings("a &lt; b &amp;&amp; b &gt; c", html.written());
}
