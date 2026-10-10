const std = @import("std");
const print = @import("../log.zig").print;
const Entry = @import("../entries.zig").Entry;
const FileParserState = @import("state.zig").FileParserState;
const blocks = @import("blocks.zig");
const parse_metadata = @import("metadata.zig").parse_metadata;
const flush_blocks = @import("flush.zig").flush_blocks;
const create_toc = @import("toc.zig").create_toc;
const Thread = std.Thread;
const Mutex = std.Io.Mutex;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const mem = std.mem;
const Allocator = mem.Allocator;

fn parse_file(file: File, io: Io, allocator: Allocator) !Entry {
    var parser_state: FileParserState = .{ .allocator = allocator, .file = file };
    defer parser_state.deinit();

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
                try parse_metadata(&parser_state, metadata_end, &new_entry);
                parser_state.strip_section(metadata_end + 3);
                parser_state.strip_newlines();
                parser_state.section = .NORMAL_MODE;
            } else if (parser_state.section == .CODE_BLOCK) {
                const _code_end: ?usize = mem.find(u8, parser_state.read_buffer[0..3], "```");
                if (_code_end) |code_end| {
                    try blocks.parse_code_block(&parser_state, &new_entry);
                    parser_state.strip_section(code_end + 3);
                    parser_state.strip_newlines();
                    parser_state.deinit_code_text();
                    parser_state.section = .NORMAL_MODE;
                } else {
                    const newline_idx: usize = mem.findScalar(u8, parser_state.read_buffer[0..parser_state.used], '\n') orelse break;
                    try parser_state.add_code_text(newline_idx + 1);
                    parser_state.strip_section(newline_idx);
                }
            } else if (parser_state.section == .QUOTE_BLOCK) {
                if (parser_state.read_buffer[0] != '>') {
                    try blocks.parse_quote_block(&parser_state, &new_entry);
                    parser_state.section = .NORMAL_MODE;
                    continue;
                }
                const newline_idx: usize = mem.findScalar(u8, parser_state.read_buffer[0..parser_state.used], '\n') orelse break;
                const text_start: usize = if (newline_idx > 1 and parser_state.read_buffer[1] == ' ') 2 else 1;
                const text = parser_state.read_buffer[text_start..newline_idx];
                if (mem.trim(u8, text, " \t\r").len == 0) {
                    try parser_state.add_quote_break();
                } else {
                    try parser_state.add_quote_text(parser_state.read_buffer[text_start..newline_idx]);
                }
                parser_state.strip_section(newline_idx);
            } else {
                const newline_idx = mem.findScalar(u8, parser_state.read_buffer[0..parser_state.used], '\n') orelse break;
                try blocks.parse_section(&parser_state, newline_idx, &new_entry);
                if (newline_idx + 1 < parser_state.used and parser_state.read_buffer[newline_idx + 1] == '\n') {
                    try flush_blocks(&parser_state, &new_entry);
                }
                parser_state.strip_section(newline_idx);
                parser_state.strip_newlines();
            }
        }
    }

    if (parser_state.section == .NORMAL_MODE and parser_state.used > 0) {
        try blocks.parse_section(&parser_state, parser_state.used, &new_entry);
        parser_state.used = 0;
        if (parser_state.section == .CODE_BLOCK) return error.EndOfCodeBlockNotFound;
    }

    if (parser_state.section == .QUOTE_BLOCK) {
        if (parser_state.used > 0 and parser_state.read_buffer[0] == '>') {
            const text_start: usize = if (parser_state.used > 1 and parser_state.read_buffer[1] == ' ') 2 else 1;
            try parser_state.add_quote_text(parser_state.read_buffer[text_start..parser_state.used]);
        }
        try blocks.parse_quote_block(&parser_state, &new_entry);
    }

    try flush_blocks(&parser_state, &new_entry);
    if (parser_state.has_toc) try create_toc(&parser_state, &new_entry);
    return new_entry;
}

var parser_mutex: Mutex = .init;
fn parse_file_worker(markdown_dir: Dir, file_path: []const u8, entries: *[]Entry, io: Io, allocator: Allocator) !void {
    defer allocator.free(file_path);

    var file = try Dir.openFile(markdown_dir, io, file_path, .{});
    defer file.close(io);

    try print("parsing ... {s}\n", .{file_path});
    var entry = try parse_file(file, io, allocator);
    errdefer entry.deinit(allocator);

    try parser_mutex.lock(io);
    defer parser_mutex.unlock(io);
    entries.* = try allocator.realloc(entries.*, entries.*.len + 1);
    entries.*[entries.len - 1] = entry;
}

fn worker(markdown_dir: Dir, file_path: []const u8, entries: *[]Entry, io: Io, allocator: Allocator, result: *?anyerror) void {
    parse_file_worker(markdown_dir, file_path, entries, io, allocator) catch |err| {
        result.* = err;
    };
}

/// Recursively reads `.md` files into entries using their metadata, appending a
/// post-date paragraph and rendered newline-ended sections.
/// The caller owns the returned slice and must deinitialize each entry and free
/// the slice using `allocator`.
pub fn create_entries(markdown_dir: Dir, io: Io, allocator: Allocator) ![]Entry {
    var walker = try markdown_dir.walk(allocator);
    defer walker.deinit();
    var entries: []Entry = &.{};
    errdefer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    var count: usize = 0;
    var threads: [16]Thread = undefined;
    var results: [16]?anyerror = @splat(null);
    defer {
        for (threads[0..count]) |thread| thread.join();
    }

    while (try walker.next(io)) |walked_entry| {
        if (walked_entry.kind != .file) continue;
        if (!mem.endsWith(u8, walked_entry.basename, ".md")) continue;

        const file_path = try allocator.dupe(u8, walked_entry.path);

        // concurrency here
        results[count] = null;
        threads[count % 16] = Thread.spawn(.{}, worker, .{ markdown_dir, file_path, &entries, io, allocator, &results[count] }) catch |err| {
            allocator.free(file_path);
            return err;
        };
        count += 1;
        if (count == threads.len) {
            for (threads[0..count]) |thread| thread.join();
            count = 0;
            for (results) |result| if (result) |err| return err;
        }
    }

    for (threads[0..count]) |thread| thread.join();
    const completed = count;
    count = 0;
    for (results[0..completed]) |result| if (result) |err| return err;

    return entries;
}

test "worker records file open errors without appending entries" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    var posts: []Entry = &.{};
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    var result: ?anyerror = null;
    const path = try allocator.dupe(u8, "missing.md");
    const thread = Thread.spawn(.{}, worker, .{ markdown.dir, path, &posts, io, allocator, &result }) catch |err| {
        allocator.free(path);
        return err;
    };
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), result);
    try std.testing.expectEqual(@as(usize, 0), posts.len);
}

test "create_entries parses multiple full batches and a partial batch" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var markdown = std.testing.tmpDir(.{ .iterate = true });
    defer markdown.cleanup();
    for (0..35) |index| {
        const filename = try std.fmt.allocPrint(allocator, "post-{d}.md", .{index});
        defer allocator.free(filename);
        const data = try std.fmt.allocPrint(allocator, "---\nname: Post\nslug: post-{d}\n---\nBody\n", .{index});
        defer allocator.free(data);
        try markdown.dir.writeFile(io, .{ .sub_path = filename, .data = data });
    }
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqual(@as(usize, 35), posts.len);
    var seen: [35]bool = @splat(false);
    for (posts) |post| {
        const index = try std.fmt.parseInt(usize, post.slug[5..], 10);
        try std.testing.expect(index < seen.len);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        try std.testing.expectEqualStrings("<p>Body</p>\n", post.content);
    }
}

test "create_entries propagates partial and full batch errors and frees successful entries" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    for ([_]usize{ 2, 16 }) |file_count| {
        var markdown = std.testing.tmpDir(.{ .iterate = true });
        defer markdown.cleanup();
        for (0..file_count) |index| {
            const filename = try std.fmt.allocPrint(allocator, "post-{d}.md", .{index});
            defer allocator.free(filename);
            const data = if (index == 1)
                "---\nunknown: Invalid\n---\nBody\n"
            else
                "---\nname: Valid\n---\nBody\n";
            try markdown.dir.writeFile(io, .{ .sub_path = filename, .data = data });
        }
        try std.testing.expectError(error.InvalidMetadataFlagFound, create_entries(markdown.dir, io, allocator));
    }
}

test "create_entries separates lists from paragraphs and other blocks" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const cases = [_]struct { markdown: []const u8, html: []const u8 }{
        .{
            .markdown = "Before\ncontinued.\n- First\n- **Second**\nAfter\ncontinued.\n",
            .html = "<p>Before\ncontinued.</p>\n<ul>\n<li>First</li>\n<li><span class=\"bold\">Second</span></li>\n</ul>\n<p>After\ncontinued.</p>\n",
        },
        .{
            .markdown = "1. First\n2. Second\nParagraph.",
            .html = "<ol>\n<li>First</li>\n<li>Second</li>\n</ol>\n<p>Paragraph.</p>\n",
        },
        .{
            .markdown = "- Unordered\n1. Ordered\n- Unordered again",
            .html = "<ul>\n<li>Unordered</li>\n</ul>\n<ol>\n<li>Ordered</li>\n</ol>\n<ul>\n<li>Unordered again</li>\n</ul>\n",
        },
        .{
            .markdown = "- First\n\n- Separate list\n",
            .html = "<ul>\n<li>First</li>\n</ul>\n<ul>\n<li>Separate list</li>\n</ul>\n",
        },
        .{
            .markdown = "- Item\n## Heading\nBody\n---\n-not a list\n1.not a list\n",
            .html = "<ul>\n<li>Item</li>\n</ul>\n<h2 id=\"header-0\">Heading</h2>\n<p>Body</p>\n<hr>\n<p>-not a list\n1.not a list</p>\n",
        },
        .{
            .markdown = "Before\n- Item\n> Quote\nAfter\n```text\ncode\n```\n- Last\n",
            .html = "<p>Before</p>\n<ul>\n<li>Item</li>\n</ul>\n<div class=\"quote-block quote-block-none\">\n<p>Quote</p>\n</div>\n<p>After</p>\n<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-code.svg\" alt=\"\" width=\"20\" height=\"20\"><span>text</span></div><pre>\n<code>code\n</code></pre></div>\n<ul>\n<li>Last</li>\n</ul>\n",
        },
        .{
            .markdown = "- Item\n```\ncode\n```\n> Final quote",
            .html = "<ul>\n<li>Item</li>\n</ul>\n<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-code.svg\" alt=\"\" width=\"20\" height=\"20\"><span>Code</span></div><pre>\n<code>code\n</code></pre></div>\n<div class=\"quote-block quote-block-none\">\n<p>Final quote</p>\n</div>\n",
        },
    };
    for (cases) |case| {
        var markdown = std.testing.tmpDir(.{ .iterate = true });
        defer markdown.cleanup();
        const source = try std.fmt.allocPrint(allocator, "---\nname: List test\nslug: list-test\n---\n\n{s}", .{case.markdown});
        defer allocator.free(source);
        try markdown.dir.writeFile(io, .{ .sub_path = "test.md", .data = source });
        const posts = try create_entries(markdown.dir, io, allocator);
        defer {
            for (posts) |*post| post.deinit(allocator);
            allocator.free(posts);
        }
        try std.testing.expectEqual(@as(usize, 1), posts.len);
        try std.testing.expectEqualStrings(case.html, posts[0].content);
    }
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
    // FailingAllocator is not thread-safe. Exercise worker allocations serially;
    // separate integration tests cover concurrent batches and error propagation.
    var walker = try markdown_dir.walk(allocator);
    defer walker.deinit();
    var posts: []Entry = &.{};
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.basename, ".md")) continue;
        const path = try allocator.dupe(u8, entry.path);
        // The worker owns path, even when parsing fails.
        parse_file_worker(markdown_dir, path, &posts, io, allocator) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
    }
    try std.testing.expectEqual(@as(usize, 2), posts.len);
}

test "parse_file_worker cleans up each allocation failure including previously parsed entries" {
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
        "<div class=\"quote-block quote-block-none\">\n<p>test</p>\n<p>test quote block</p>\n</div>\n" ++
            "<p>something here</p>\n" ++
            "<div class=\"quote-block quote-block-note\">\n<p>note</p>\n</div>\n<p>After</p>\n" ++
            "<div class=\"quote-block quote-block-important\">\n<p>important</p>\n</div>\n<p>After again</p>\n" ++
            "<div class=\"quote-block quote-block-none\">\n<p>&lt;last&gt; &amp; quote</p>\n<p>final</p>\n</div>\n",
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
        .data = "---\nname: Code\n---\n```zig\nconst x = 42;\n```\n```rust\n<a> & 42\n```\n```\nconst x = 42;\n```\n",
    });
    const posts = try create_entries(markdown.dir, io, allocator);
    defer {
        for (posts) |*post| post.deinit(allocator);
        allocator.free(posts);
    }
    try std.testing.expectEqualStrings(
        "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-zig.svg\" alt=\"\" width=\"20\" height=\"20\"><span>Zig</span></div><pre>\n<code class=\"language-zig\"><span class=\"tok-keyword\">const</span> x <span class=\"tok-operator\">=</span> <span class=\"tok-number\">42</span>;\n</code></pre></div>\n" ++
            "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-code.svg\" alt=\"\" width=\"20\" height=\"20\"><span>rust</span></div><pre>\n<code>&lt;a&gt; &amp; 42\n</code></pre></div>\n" ++
            "<div class=\"code-section\"><div class=\"code-header\"><img class=\"code-language-icon\" src=\"./language-code.svg\" alt=\"\" width=\"20\" height=\"20\"><span>Code</span></div><pre>\n<code>const x = 42;\n</code></pre></div>\n",
        posts[0].content,
    );
}

test "code block integration highlights each added language" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const cases = [_]struct { language: []const u8, source: []const u8, fragment: []const u8 }{
        .{ .language = "python", .source = "return 42", .fragment = "<span class=\"tok-keyword\">return</span>" },
        .{ .language = "c", .source = "int answer = 42;", .fragment = "<span class=\"tok-type\">int</span>" },
        .{ .language = "json", .source = "{\"answer\": 42}", .fragment = "<span class=\"tok-field\">\"answer\"</span>" },
        .{ .language = "sh", .source = "echo 42", .fragment = "<span class=\"tok-function\">echo</span>" },
        .{ .language = "bash", .source = "echo 42", .fragment = "<span class=\"tok-function\">echo</span>" },
    };
    for (cases) |case| {
        var markdown = std.testing.tmpDir(.{ .iterate = true });
        defer markdown.cleanup();
        const data = try std.fmt.allocPrint(allocator, "---\nname: Code\n---\n```{s}\n{s}\n```\nAfter\n", .{ case.language, case.source });
        defer allocator.free(data);
        try markdown.dir.writeFile(io, .{ .sub_path = "code.md", .data = data });
        const posts = try create_entries(markdown.dir, io, allocator);
        defer {
            for (posts) |*post| post.deinit(allocator);
            allocator.free(posts);
        }
        try std.testing.expectEqual(@as(usize, 1), posts.len);
        try std.testing.expect(mem.find(u8, posts[0].content, case.fragment) != null);
        try std.testing.expect(mem.endsWith(u8, posts[0].content, "<p>After</p>\n"));
    }
}
