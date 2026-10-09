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
                    const is_gif: bool = mem.find(u8, section[tag_idx + 1 .. closing_tag_idx], ".gif") != null;
                    const is_image: bool =
                        mem.find(u8, section[tag_idx + 1 .. closing_tag_idx], ".jpg") != null or
                        mem.find(u8, section[tag_idx + 1 .. closing_tag_idx], ".jpeg") != null or
                        mem.find(u8, section[tag_idx + 1 .. closing_tag_idx], ".png") != null;
                        
                    const name: []const u8 = section[count + 1 .. tag_idx];
                    const link: []const u8 = section[tag_idx + 2 .. closing_tag_idx];
                    if(is_gif) {
                        const tag = try std.fmt.allocPrint(allocator,  "\n<img src=\"{s}\" alt=\"{s}\" class=\"gif\">", .{link, name});
                        defer allocator.free(tag);
                        try content_writer.writeAll(tag);
                    } else if (is_image) {
                        const tag = try std.fmt.allocPrint(allocator, "\n<img src=\"{s}\" alt=\"{s}\" class=\"image\">", .{ link, name });
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

test "parse_inline preserves unmatched and empty emphasis markers" {
    const allocator = std.testing.allocator;
    const sections = [_][]const u8{
        "*",                  "_",                   "**",      "__",      "***",      "___",              "****",               "____",
        "Before *unfinished", "Before __unfinished", "**bold*", "__bold_", "*italic_", "Trailing marker*", "Trailing markers**",
    };
    for (sections) |section| {
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try parse_inline(section, &output.writer, allocator);
        try std.testing.expectEqualStrings(section, output.written());
    }
}

test "parse_inline keeps extra closing markers inside italic text" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { section: []const u8, html: []const u8 }{
        .{ .section = "**what** *test** **what**", .html = "<span class=\"bold\">what</span> <span class=\"italic\">test*</span> <span class=\"bold\">what</span>" },
        .{ .section = "__what__ _test__ __what__", .html = "<span class=\"bold\">what</span> <span class=\"italic\">test_</span> <span class=\"bold\">what</span>" },
        .{ .section = "*test**", .html = "<span class=\"italic\">test*</span>" },
        .{ .section = "*test*** *valid*", .html = "<span class=\"italic\">test**</span> <span class=\"italic\">valid</span>" },
    };
    for (cases) |case| {
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try parse_inline(case.section, &output.writer, allocator);
        try std.testing.expectEqualStrings(case.html, output.written());
    }
}

test "parse_inline renders italic inside bold" {
    const allocator = std.testing.allocator;
    const sections = [_][]const u8{
        "**what *test* what**",
        "__what _test_ what__",
        "**what _test_ what**",
        "__what *test* what__",
    };
    for (sections) |section| {
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try parse_inline(section, &output.writer, allocator);
        try std.testing.expectEqualStrings("<span class=\"bold\">what <span class=\"italic\">test</span> what</span>", output.written());
    }
}

test "parse_inline renders a link" {
    const allocator = std.testing.allocator;
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try parse_inline("[Example](https://example.com)", &output.writer, allocator);

    try std.testing.expectEqualStrings("\n<a href=\"https://example.com\">Example</a>\n", output.written());
}

test "parse_inline renders supported image extensions with alt text" {
    const allocator = std.testing.allocator;
    // This parser identifies images by extension, using [alt](url) without '!'.
    const extensions = [_][]const u8{ "jpg", "jpeg", "png", "gif" };
    for (extensions) |extension| {
        const section = try std.fmt.allocPrint(allocator, "Before [A photo](https://example.com/photo.{s}) after.", .{extension});
        defer allocator.free(section);
        const html = try std.fmt.allocPrint(allocator, "Before \n<img src=\"https://example.com/photo.{s}\" alt=\"A photo\"> after.", .{extension});
        defer allocator.free(html);
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();

        try parse_inline(section, &output.writer, allocator);
        try std.testing.expectEqualStrings(html, output.written());
    }
}

test "parse_inline preserves incomplete link syntax as plain text" {
    const allocator = std.testing.allocator;
    const sections = [_][]const u8{
        "[",
        "[label",
        "[label]",
        "[label](https://example.com",
        "[label] https://example.com",
    };
    for (sections) |section| {
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();

        try parse_inline(section, &output.writer, allocator);
        try std.testing.expectEqualStrings(section, output.written());
    }
}
