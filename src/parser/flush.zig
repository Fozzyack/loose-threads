const Entry = @import("../entries.zig").Entry;
const FileParserState = @import("state.zig").FileParserState;

/// Finishes pending text and list blocks at a block boundary or EOF.
pub fn flush_blocks(parser_state: *FileParserState, entry: *Entry) !void {
    try flush_paragraph(parser_state, entry);
    try close_list(parser_state, entry);
}

/// Emits buffered paragraph HTML without interrupting a continuing list.
pub fn flush_paragraph(parser_state: *FileParserState, entry: *Entry) !void {
    if (parser_state.paragraph.len == 0) return;
    defer parser_state.deinit_paragraph();
    try parser_state.add_paragraph("</p>\n");
    try entry.add_content(parser_state.paragraph, parser_state.allocator);
}

pub fn close_list(parser_state: *FileParserState, entry: *Entry) !void {
    switch (parser_state.list_type) {
        .none => return,
        .unordered => try entry.add_content("</ul>\n", parser_state.allocator),
        .ordered => try entry.add_content("</ol>\n", parser_state.allocator),
    }
    parser_state.list_type = .none;
}
