const std = @import("std");
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() ?*const ts.TSLanguage;

const TreeSitterParserError = error{ OutOfMemory, ParseFailed, MissingZigGrammar, IncompatibleGrammar, InvalidHighlightQuery, OverlappingErrors, UnknownCapture };

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

pub fn check() !void {
    const parser = ts.ts_parser_new() orelse
        return TreeSitterParserError.OutOfMemory;
    defer ts.ts_parser_delete(parser);

    const language = tree_sitter_zig() orelse
        return TreeSitterParserError.MissingZigGrammar;

    if (!ts.ts_parser_set_language(parser, language)) {
        return TreeSitterParserError.IncompatibleGrammar;
    }

    const source = "const answer = 42;";
    const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return TreeSitterParserError.ParseFailed;
    defer ts.ts_tree_delete(tree);

    const root = ts.ts_tree_root_node(tree);

    const tree_text = ts.ts_node_string(root);
    if (tree_text == null) return TreeSitterParserError.OutOfMemory;
    defer ts.free(tree_text);

    std.debug.print("{s}\n", .{std.mem.span(tree_text)});

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
    var html: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer html.deinit();

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

        try writeEscaped(&html.writer, source[position..start]);

        const opening_tag = if (std.mem.eql(u8, capture_name, "keyword"))
            "<span class=\"tok-keyword\">"
        else if (std.mem.eql(u8, capture_name, "number"))
            "<span class=\"tok-number\">"
        else
            return TreeSitterParserError.UnknownCapture;

        try html.writer.writeAll(opening_tag);
        try writeEscaped(&html.writer, source[start..end]);
        try html.writer.writeAll("</span>");
        position = end;
    }

    try writeEscaped(&html.writer, source[position..]);
    std.debug.print("{s}\n", .{html.written()});
}

test "writeEscaped preserves whitespace and escapes HTML characters" {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();

    try writeEscaped(&html.writer, "\tif (a < b && b > 0) {\n}\n");
    try std.testing.expectEqualStrings("\tif (a &lt; b &amp;&amp; b &gt; 0) {\n}\n", html.written());
}

test "check renders keyword and number captures" {
    try check();
}
