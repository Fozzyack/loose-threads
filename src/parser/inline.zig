const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;

/// Renders inline content, recursively parsing the text inside emphasis spans.
pub fn parse_inline(section: []const u8, content_writer: *Io.Writer, allocator: Allocator) !void {
    var count: usize = 0;
    var old_count: usize = 0;

    while (count < section.len) {
        if (section[count] == '[') {
            link: {
                const tag_idx = count + (mem.findScalar(u8, section[count..], ']') orelse break :link);
                if (tag_idx + 1 < section.len and section[tag_idx + 1] == '(') {
                    const closing_tag_idx = tag_idx + 1 + (mem.findScalar(u8, section[tag_idx + 1 ..], ')') orelse break :link);
                    try content_writer.writeAll(section[old_count..count]);
                    const is_image: bool =
                        mem.find(u8, section[tag_idx + 1 .. closing_tag_idx], ".jpg") != null or
                        mem.find(u8, section[tag_idx + 1 .. closing_tag_idx], ".jpeg") != null or
                        mem.find(u8, section[tag_idx + 1 .. closing_tag_idx], ".png") != null or
                        mem.find(u8, section[tag_idx + 1 .. closing_tag_idx], ".gif") != null;
                    const name: []const u8 = section[count + 1 .. tag_idx];
                    const link: []const u8 = section[tag_idx + 2 .. closing_tag_idx];
                    if (is_image) {
                        const tag = try std.fmt.allocPrint(allocator, "\n<img src=\"{s}\" alt=\"{s}\">", .{ link, name });
                        defer allocator.free(tag);
                        try content_writer.writeAll(tag);
                    } else {
                        const tag = try std.fmt.allocPrint(allocator, "\n<a href=\"{s}\">{s}</a>\n", .{ link, name });
                        defer allocator.free(tag);
                        try content_writer.writeAll(tag);
                    }
                    count = closing_tag_idx + 1;
                    old_count = count;
                    continue;
                }
            }
        }
        if (section[count] == '_' or section[count] == '*') {
            const is_bold = count + 1 < section.len and section[count + 1] == section[count];
            const delimiter_len: usize = if (is_bold) 2 else 1;
            const delimiter = section[count .. count + delimiter_len];
            const text_start = count + delimiter_len;
            bold_italic: {
                var text_end = text_start + (mem.find(u8, section[text_start..], delimiter) orelse break :bold_italic);
                if (text_end == text_start) break :bold_italic;
                if (!is_bold) {
                    while (text_end + 1 < section.len and section[text_end + 1] == section[count]) : (text_end += 1) {}
                }

                try content_writer.writeAll(section[old_count..count]);
                const class = if (is_bold) "bold" else "italic";
                const tag = try std.fmt.allocPrint(allocator, "<span class=\"{s}\">", .{class});
                defer allocator.free(tag);
                try content_writer.writeAll(tag);
                try parse_inline(section[text_start..text_end], content_writer, allocator);
                try content_writer.writeAll("</span>");
                count = text_end + delimiter_len;
                old_count = count;
                continue;
            }
            count += delimiter_len;
            continue;
        }

        count += 1;
    }
    try content_writer.writeAll(section[old_count..count]);
}
