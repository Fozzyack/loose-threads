const std = @import("std");
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_zig() ?*const ts.TSLanguage;

pub fn check() !void {
    const parser = ts.ts_parser_new() orelse
        return error.OutOfMemory;
    defer ts.ts_parser_delete(parser);

    const language = tree_sitter_zig() orelse
        return error.MissingZigGrammar;

    if (!ts.ts_parser_set_language(parser, language)) {
        return error.IncompatibleGrammar;
    }
}
