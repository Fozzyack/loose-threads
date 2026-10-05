const std = @import("std");
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() ?*const ts.TSLanguage;

const ParserError = error{ OutOfMemory, ParseFailed, MissingZigGrammar, IncompatibleGrammar, InvalidHighlightQuery };

pub fn check() !void {
    const parser = ts.ts_parser_new() orelse
        return ParserError.OutOfMemory;
    defer ts.ts_parser_delete(parser);

    const language = tree_sitter_zig() orelse
        return ParserError.MissingZigGrammar;

    if (!ts.ts_parser_set_language(parser, language)) {
        return ParserError.IncompatibleGrammar;
    }

    const source = "const answer = 42;";
    const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return ParserError.ParseFailed;
    defer ts.ts_tree_delete(tree);

    const root = ts.ts_tree_root_node(tree);

    const tree_text = ts.ts_node_string(root);
    if (tree_text == null) return ParserError.OutOfMemory;
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
        return ParserError.InvalidHighlightQuery;
    };
    defer ts.ts_query_delete(query);

    const cursor = ts.ts_query_cursor_new() orelse
        return ParserError.OutOfMemory;
    defer ts.ts_query_cursor_delete(cursor);

    ts.ts_query_cursor_exec(cursor, query, root);
    var match: ts.TSQueryMatch = undefined;
    var capture_index: u32 = 0;

    while (ts.ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
        const capture = match.captures[capture_index];

        const start = ts.ts_node_start_byte(capture.node);
        const end = ts.ts_node_end_byte(capture.node);

        var name_len: u32 = 0;
        const name = ts.ts_query_capture_name_for_id(query, capture.index, &name_len);

        std.debug.print(
            "{s}: '{s}' [{d}..{d}]\n",
            .{ name[0..name_len], source[start..end], start, end },
        );
    }
}
