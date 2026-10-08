const std = @import("std");
const log = @import("../log.zig");
const Entry = @import("../entries.zig").Entry;
const FileParserState = @import("state.zig").FileParserState;
const blocks = @import("blocks.zig");
const parse_metadata = @import("metadata.zig").parse_metadata;
const create_toc = @import("toc.zig").create_toc;
const Io = std.Io;
const Dir = Io.Dir;
const mem = std.mem;
const Allocator = mem.Allocator;

/// Recursively reads `.md` files into entries using their metadata, appending a
/// post-date paragraph and rendered newline-ended sections.
/// The caller owns the returned slice and must deinitialize each entry and free
/// the slice using `allocator`.
pub fn create_entries(markdown_dir: Dir, io: Io, allocator: Allocator) ![]Entry {
    var walker = try Dir.walk(markdown_dir, allocator);
    defer walker.deinit();

    var entries: []Entry = &.{};
    errdefer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".md")) continue;
        var file = try markdown_dir.openFile(io, entry.path, .{});
        defer file.close(io);

        try log.print("parsing ... {s}\n", .{entry.path});

        var parser_state: FileParserState = .{ .file = file };
        defer parser_state.deinit(allocator);

        var new_entry: Entry = .{ .name = &.{} };
        errdefer new_entry.deinit(allocator);

        while (true) {
            (try parser_state.read_section(io)) orelse break;
            parser_state.strip_newlines();

            while (true) {
                if (parser_state.used == 0) break;
                if (parser_state.section == .METADATA) {
                    const metadata_start: usize = mem.find(u8, parser_state.read_buffer[0..parser_state.used], "---\n") orelse break;
                    if (metadata_start != 0) return error.IncorrectMetadataDelimiter;
                    const metadata_end: usize = mem.find(u8, parser_state.read_buffer[0..parser_state.used], "\n---\n") orelse break;
                    try parse_metadata(&parser_state, metadata_end, &new_entry, allocator);
                    parser_state.strip_section(metadata_end + 3);
                    parser_state.strip_newlines();
                    parser_state.section = .NORMAL_MODE;
                } else if (parser_state.section == .CODE_BLOCK) {
                    const _code_end: ?usize = mem.find(u8, parser_state.read_buffer[0..3], "```");
                    if (_code_end) |code_end| {
                        try blocks.parse_code_block(&parser_state, &new_entry, allocator);
                        parser_state.strip_section(code_end + 3);
                        parser_state.strip_newlines();
                        parser_state.deinit_code_text(allocator);
                        parser_state.section = .NORMAL_MODE;
                    } else {
                        const newline_idx: usize = mem.findScalar(u8, parser_state.read_buffer[0..parser_state.used], '\n') orelse break;
                        try parser_state.add_code_text(newline_idx + 1, allocator);
                        parser_state.strip_section(newline_idx);
                    }
                } else if (parser_state.section == .QUOTE_BLOCK) {
                    if (parser_state.read_buffer[0] != '>') {
                        try blocks.parse_quote_block(&parser_state, &new_entry, allocator);
                        parser_state.section = .NORMAL_MODE;
                        continue;
                    }
                    const newline_idx: usize = mem.findScalar(u8, parser_state.read_buffer[0..parser_state.used], '\n') orelse break;
                    const text_start: usize = if (newline_idx > 1 and parser_state.read_buffer[1] == ' ') 2 else 1;
                    try parser_state.add_quote_text(parser_state.read_buffer[text_start..newline_idx], allocator);
                    parser_state.strip_section(newline_idx);
                } else {
                    const newline_idx = mem.findScalar(u8, parser_state.read_buffer[0..parser_state.used], '\n') orelse break;
                    try blocks.parse_section(&parser_state, newline_idx, &new_entry, allocator);
                    parser_state.strip_section(newline_idx);
                    parser_state.strip_newlines();
                }
            }
        }

        if (parser_state.section == .QUOTE_BLOCK) {
            if (parser_state.used > 0 and parser_state.read_buffer[0] == '>') {
                const text_start: usize = if (parser_state.used > 1 and parser_state.read_buffer[1] == ' ') 2 else 1;
                try parser_state.add_quote_text(parser_state.read_buffer[text_start..parser_state.used], allocator);
            }
            try blocks.parse_quote_block(&parser_state, &new_entry, allocator);
        }

        if (parser_state.has_toc) try create_toc(&parser_state, &new_entry, allocator);
        entries = try allocator.realloc(entries, entries.len + 1);
        entries[entries.len - 1] = new_entry;
    }

    return entries;
}

test {
    _ = @import("tests.zig");
}
