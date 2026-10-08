const std = @import("std");
const log = @import("../log.zig");
const Entry = @import("../entries.zig").Entry;
const FileParserState = @import("state.zig").FileParserState;
const blocks = @import("blocks.zig");
const parse_metadata = @import("metadata.zig").parse_metadata;
const parse_paragraph = @import("paragraph.zig").parse_paragraph;
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
                    if (newline_idx + 1 < parser_state.used and parser_state.read_buffer[newline_idx + 1] == '\n') try parse_paragraph(&parser_state, &new_entry, allocator);
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

        try parse_paragraph(&parser_state, &new_entry, allocator);

        if (parser_state.has_toc) try create_toc(&parser_state, &new_entry, allocator);
        entries = try allocator.realloc(entries, entries.len + 1);
        entries[entries.len - 1] = new_entry;
    }

    return entries;
}

test "create_entries records complete formatted headings once with matching TOC anchors" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    try markdown.dir.writeFile(io, .{
        .sub_path = "headings.md",
        .data = "---\nname: Headings\ntoc: true\n---\n# Before **bold _nested_** after\nParagraph with *emphasis*.\n## Visit [Example](https://example.com) today\n### Last\n",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqual(@as(usize, 1), posts.len);
    try std.testing.expectEqualStrings(
        "<h1 id=\"header-0\">Before <span class=\"bold\">bold <span class=\"italic\">nested</span></span> after</h1>\n" ++
            "<p>Paragraph with <span class=\"italic\">emphasis</span>.</p>\n" ++
            "<h2 id=\"header-1\">Visit \n<a href=\"https://example.com\">Example</a>\n today</h2>\n" ++
            "<h3 id=\"header-2\">Last</h3>\n",
        posts[0].content,
    );
    try std.testing.expectEqualStrings(
        "<nav class=\"table-of-contents\" aria-label=\"Table of contents\">\n" ++
            "<h2>Table of Contents</h2>\n<ol>\n" ++
            "<li><a href=\"#header-0\">Before **bold _nested_** after</a></li>\n" ++
            "<li><a href=\"#header-1\">Visit [Example](https://example.com) today</a></li>\n" ++
            "<li><a href=\"#header-2\">Last</a></li>\n" ++
            "</ol>\n</nav>",
        posts[0].table_of_contents,
    );
}

fn test_create_entries_allocations(allocator: Allocator, markdown_dir: Dir, io: Io) !void {
    // Allocating writers report allocation failures as WriteFailed; the testing
    // utility expects OutOfMemory for the injected allocator failure.
    const posts = create_entries(markdown_dir, io, allocator) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqual(@as(usize, 2), posts.len);
}

test "create_entries cleans up each allocation failure including previously parsed entries" {
    const io = std.testing.io;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    const data = "---\nname: Post\ntoc: true\n---\n# Heading\nBody\n";
    try markdown.dir.writeFile(io, .{ .sub_path = "first.md", .data = data });
    try markdown.dir.writeFile(io, .{ .sub_path = "second.md", .data = data });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_create_entries_allocations, .{ markdown.dir, io });
}

test "create_entries propagates parse and read errors while freeing partial state" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    const cases = [_]struct { data: []const u8, err: anyerror }{
        .{ .data = "---\nname: Partial\n", .err = error.FailedToParseMetadata },
        .{ .data = "---\nname: Partial\n---\n# Heading\n```zig\nconst x = 1;\n", .err = error.EndOfCodeBlockNotFound },
        .{ .data = "---\nname: Partial\n---\n# Heading\n###\n", .err = error.InvalidLine },
    };
    for (cases) |case| {
        try markdown.dir.writeFile(io, .{ .sub_path = "partial.md", .data = case.data });
        try std.testing.expectError(case.err, create_entries(markdown.dir, io, allocator));
    }
}

test "create_entries preserves quote text and following paragraphs" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    try markdown.dir.writeFile(io, .{
        .sub_path = "quote.md",
        .data = "---\nname: Quote\n---\n> test\n> test quote block\n\nsomething here\n> [!NOTE]\n> note\nAfter\n> [!IMPORTANT]\n> important\nAfter again\n> <last> & quote\n> final",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqualStrings(
        "<div class=\"quote-block-none\">\n<p>test</p>\n<p>test quote block</p>\n</div>\n" ++
            "<p>something here</p>\n" ++
            "<div class=\"quote-block-note\">\n<p>note</p>\n</div>\n<p>After</p>\n" ++
            "<div class=\"quote-block-important\">\n<p>important</p>\n</div>\n<p>After again</p>\n" ++
            "<div class=\"quote-block-none\">\n<p>&lt;last&gt; &amp; quote</p>\n<p>final</p>\n</div>\n",
        posts[0].content,
    );
}

test "create_entries parses each file independently" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    try markdown.dir.writeFile(io, .{
        .sub_path = "first.md",
        .data = "---\nname: First\nslug: first\ndate: 2026-10-01\n---\n\n# First heading\nFirst body.\n",
    });
    try markdown.dir.writeFile(io, .{
        .sub_path = "second.md",
        .data = "---\nname: Second\nslug: second\ntimestamp: 0\n---\n\n## Second heading\nSecond body.\n",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqual(@as(usize, 2), posts.len);
    // Directory traversal order is unspecified.
    for (posts) |post| {
        if (mem.eql(u8, post.slug, "first")) {
            try std.testing.expectEqualStrings("First", post.name);
            try std.testing.expectEqualStrings("<p class=\"post-date\">October 1, 2026</p>\n<h1 id=\"header-0\">First heading</h1>\n<p>First body.</p>\n", post.content);
        } else {
            try std.testing.expectEqualStrings("second", post.slug);
            try std.testing.expectEqualStrings("Second", post.name);
            try std.testing.expectEqualStrings("<p class=\"post-date\">January 1, 1970 at 00:00:00 UTC</p>\n<h2 id=\"header-0\">Second heading</h2>\n<p>Second body.</p>\n", post.content);
        }
    }
    try std.testing.expect(!mem.eql(u8, posts[0].slug, posts[1].slug));
}

test "code block integration highlights Zig" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    try markdown.dir.writeFile(io, .{
        .sub_path = "code.md",
        .data = "---\nname: Code\nslug: code\n---\n```zig\nconst answer = 42;\n```\nAfter\n",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqualStrings(
        "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-zig.svg\" alt=\"\" width=\"20\" height=\"20\"><span>Zig</span></div><pre>\n<code class=\"language-zig\"><span class=\"tok-keyword\">const</span> answer <span class=\"tok-operator\">=</span> <span class=\"tok-number\">42</span>;\n</code></pre></div>\n<p>After</p>\n",
        posts[0].content,
    );
}

test "code block integration escapes plain code without stale languages" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    try markdown.dir.writeFile(io, .{
        .sub_path = "code.md",
        .data = "---\nname: Code\n---\n```zig\nconst x = 42;\n```\n```c\n<a> & 42\n```\n```\nconst x = 42;\n```\n",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqualStrings(
        "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-zig.svg\" alt=\"\" width=\"20\" height=\"20\"><span>Zig</span></div><pre>\n<code class=\"language-zig\"><span class=\"tok-keyword\">const</span> x <span class=\"tok-operator\">=</span> <span class=\"tok-number\">42</span>;\n</code></pre></div>\n" ++
            "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-c.svg\" alt=\"\" width=\"20\" height=\"20\"><span>C</span></div><pre>\n<code>&lt;a&gt; &amp; 42\n</code></pre></div>\n" ++
            "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-code.svg\" alt=\"\" width=\"20\" height=\"20\"><span>Code</span></div><pre>\n<code>const x = 42;\n</code></pre></div>\n",
        posts[0].content,
    );
}
