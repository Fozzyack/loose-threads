const std = @import("std");
const Entry = @import("../entries.zig").Entry;
const FileParserState = @import("state.zig").FileParserState;
const Io = std.Io;

pub fn create_toc(parser_state: *FileParserState, entry: *Entry) !void {
    if (parser_state.headers.len == 0) return;
    var html: Io.Writer.Allocating = .init(parser_state.allocator);
    defer html.deinit();
    try html.writer.writeAll("<nav class=\"table-of-contents\" aria-label=\"Table of contents\">\n<h2>Table of Contents</h2>\n<ol>\n");
    for (parser_state.headers, 0..) |header, idx| {
        try html.writer.print("<li><a href=\"#header-{d}\">{s}</a></li>\n", .{ idx, header });
    }
    try html.writer.writeAll("</ol>\n</nav>");
    try entry.add_toc(html.written(), parser_state.allocator);
}

test "create_toc omits empty headings and renders working anchor links" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .allocator = allocator, .file = undefined };
    defer state.deinit();
    var entry: Entry = .{};
    try entry.add_name("Post", allocator);
    defer entry.deinit(allocator);

    try create_toc(&state, &entry);
    try std.testing.expectEqualStrings("", entry.table_of_contents);

    try state.add_header("Introduction");
    try state.add_header("Next section");
    try create_toc(&state, &entry);
    try std.testing.expectEqualStrings(
        "<nav class=\"table-of-contents\" aria-label=\"Table of contents\">\n" ++
            "<h2>Table of Contents</h2>\n<ol>\n" ++
            "<li><a href=\"#header-0\">Introduction</a></li>\n" ++
            "<li><a href=\"#header-1\">Next section</a></li>\n" ++
            "</ol>\n</nav>",
        entry.table_of_contents,
    );
}
