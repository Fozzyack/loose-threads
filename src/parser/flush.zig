const std = @import("std");
const Entry = @import("../entries.zig").Entry;
const FileParserState = @import("state.zig").FileParserState;
const Allocator = std.mem.Allocator;

/// Finishes pending text and list blocks at a block boundary or EOF.
pub fn flush_blocks(parser_state: *FileParserState, entry: *Entry, allocator: Allocator) !void {
    try flush_paragraph(parser_state, entry, allocator);
    try close_list(parser_state, entry, allocator);
}

/// Emits buffered paragraph HTML without interrupting a continuing list.
pub fn flush_paragraph(parser_state: *FileParserState, entry: *Entry, allocator: Allocator) !void {
    if (parser_state.paragraph.len == 0) return;
    defer parser_state.deinit_paragraph(allocator);
    try parser_state.add_paragraph("</p>\n", allocator);
    try entry.add_content(parser_state.paragraph, allocator);
}

pub fn close_list(parser_state: *FileParserState, entry: *Entry, allocator: Allocator) !void {
    switch (parser_state.list_type) {
        .none => return,
        .unordered => try entry.add_content("</ul>\n", allocator),
        .ordered => try entry.add_content("</ol>\n", allocator),
    }
    parser_state.list_type = .none;
}
