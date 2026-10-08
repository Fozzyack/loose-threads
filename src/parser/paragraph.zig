const std = @import("std");
const Entry = @import("../entries.zig").Entry;
const FileParserState = @import("state.zig").FileParserState;
const mem = std.mem;
const eql = mem.eql;
const Allocator = mem.Allocator;
const expect = std.testing.expect;


pub fn parse_paragraph(parser_state: *FileParserState, entry: *Entry, allocator: Allocator) !void {
    if (parser_state.paragraph.len == 0) return;
    defer parser_state.deinit_paragraph(allocator);
    try parser_state.add_paragraph("</p>\n", allocator);
    try entry.add_content(parser_state.paragraph, allocator);
}
