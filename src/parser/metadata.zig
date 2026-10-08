const std = @import("std");
const Entry = @import("../entries.zig").Entry;
const FileParserState = @import("state.zig").FileParserState;
const mem = std.mem;
const eql = mem.eql;
const Allocator = mem.Allocator;

/// Parses newline-terminated metadata lines without the `---` delimiters.
/// Accepts `name`, `description`, `slug`, `date`, `timestamp`, and `toc` keys,
/// optionally followed by one space. Trims surrounding spaces from values;
/// strings are allocator-owned copies and timestamps are numeric Unix seconds.
/// After parsing, appends one post-date paragraph: the timestamp's UTC date and
/// time if present, otherwise the date. Metadata order does not affect this choice.
/// Malformed or impossible dates return `error.InvalidMetadataDate`; malformed
/// or out-of-range timestamps return `error.InvalidMetadataTimestamp`.
/// Missing separators or newlines return `error.ErrorParsingMetadata`; unknown keys
/// return `error.InvalidMetadataFlagFound`. Fields already stored remain on failure.
pub fn parse_metadata(parser_state: *FileParserState, metadata_end: usize, entry: *Entry, allocator: Allocator) !void {
    var start: usize = 0;
    var buffer: []u8 = parser_state.read_buffer[4 .. metadata_end + 1];
    while (start < buffer.len) {
        const separator_idx = start + (mem.findScalar(u8, buffer[start..], ':') orelse return error.ErrorParsingMetadata);
        const newline_idx = start + (mem.findScalar(u8, buffer[start..], '\n') orelse return error.ErrorParsingMetadata);
        if (eql(u8, buffer[start..separator_idx], "name") or eql(u8, buffer[start..separator_idx], "name ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            try entry.add_name(value, allocator);
        } else if (eql(u8, buffer[start..separator_idx], "description") or eql(u8, buffer[start..separator_idx], "description ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            try entry.add_description(value, allocator);
        } else if (eql(u8, buffer[start..separator_idx], "slug") or eql(u8, buffer[start..separator_idx], "slug ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            try entry.add_slug(value, allocator);
        } else if (eql(u8, buffer[start..separator_idx], "date") or eql(u8, buffer[start..separator_idx], "date ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            try entry.add_date(value, allocator);
        } else if (eql(u8, buffer[start..separator_idx], "timestamp") or eql(u8, buffer[start..separator_idx], "timestamp ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            try entry.add_timestamp(value);
        } else if (eql(u8, buffer[start..separator_idx], "toc") or eql(u8, buffer[start..separator_idx], "toc ")) {
            const value = mem.trim(u8, buffer[separator_idx + 1 .. newline_idx], " ");
            if (eql(u8, value, "true")) parser_state.has_toc = true;
        } else return error.InvalidMetadataFlagFound;
        start = newline_idx + 1;
    }
    try entry.render_date(allocator);
}
