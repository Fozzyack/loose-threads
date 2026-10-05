const std = @import("std");
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() ?*const ts.TSLanguage;

const ParserError = error{ OutOfMemory, ParseFailed, MissingZigGrammar, IncompatibleGrammar };

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
}
