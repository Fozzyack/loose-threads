const std = @import("std");
const ts = @import("tree_sitter");

extern fn tree_sitter_zig() ?*const ts.TSLanguage;

const TreeSitterParserError = error{ OutOfMemory, ParseFailed, MissingZigGrammar, IncompatibleGrammar, InvalidHighlightQuery, OverlappingErrors, UnknownCapture, CodeBlockTooLarge };

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(byte),
        }
    }
}

/// Writes escaped code, highlighting the currently supported Zig tokens.
/// Unknown or omitted languages are rendered as plain escaped text.
pub fn render(source: []const u8, language_name: []const u8, writer: *std.Io.Writer) !void {
    if (!std.mem.eql(u8, language_name, "zig")) {
        try writeEscaped(writer, source);
        return;
    }
    if (source.len > std.math.maxInt(u32)) return TreeSitterParserError.CodeBlockTooLarge;

    const parser = ts.ts_parser_new() orelse
        return TreeSitterParserError.OutOfMemory;
    defer ts.ts_parser_delete(parser);

    const language = tree_sitter_zig() orelse
        return TreeSitterParserError.MissingZigGrammar;

    if (!ts.ts_parser_set_language(parser, language)) {
        return TreeSitterParserError.IncompatibleGrammar;
    }

    const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return TreeSitterParserError.ParseFailed;
    defer ts.ts_tree_delete(tree);

    const root = ts.ts_tree_root_node(tree);

    const query_source = @embedFile("queries/zig.scm");
    var error_offset: u32 = 0;
    var error_type: ts.TSQueryError = ts.TSQueryErrorNone;

    const query = ts.ts_query_new(language, query_source.ptr, @intCast(query_source.len), &error_offset, &error_type) orelse {
        std.debug.print(
            "Invalid highlight query at byte {d}, error type {d}\n",
            .{ error_offset, error_type },
        );
        return TreeSitterParserError.InvalidHighlightQuery;
    };
    defer ts.ts_query_delete(query);

    const cursor = ts.ts_query_cursor_new() orelse
        return TreeSitterParserError.OutOfMemory;
    defer ts.ts_query_cursor_delete(cursor);

    ts.ts_query_cursor_exec(cursor, query, root);
    var position: usize = 0;
    var match: ts.TSQueryMatch = undefined;
    var capture_index: u32 = 0;

    while (ts.ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
        const capture = match.captures[capture_index];

        const start = ts.ts_node_start_byte(capture.node);
        const end = ts.ts_node_end_byte(capture.node);

        var name_len: u32 = 0;
        const name = ts.ts_query_capture_name_for_id(query, capture.index, &name_len);

        const capture_name = name[0..name_len];

        // The query deliberately avoids overlapping captures.
        if (start < position) return TreeSitterParserError.OverlappingErrors;

        try writeEscaped(writer, source[position..start]);

        const opening_tag = if (std.mem.eql(u8, capture_name, "keyword"))
            "<span class=\"tok-keyword\">"
        else if (std.mem.eql(u8, capture_name, "number"))
            "<span class=\"tok-number\">"
        else if (std.mem.eql(u8, capture_name, "string"))
            "<span class=\"tok-string\">"
        else if (std.mem.eql(u8, capture_name, "comment"))
            "<span class=\"tok-comment\">"
        else if (std.mem.eql(u8, capture_name, "constant"))
            "<span class=\"tok-constant\">"
        else if (std.mem.eql(u8, capture_name, "type"))
            "<span class=\"tok-type\">"
        else if (std.mem.eql(u8, capture_name, "builtin"))
            "<span class=\"tok-builtin\">"
        else if (std.mem.eql(u8, capture_name, "function"))
            "<span class=\"tok-function\">"
        else if (std.mem.eql(u8, capture_name, "operator"))
            "<span class=\"tok-operator\">"
        else if (std.mem.eql(u8, capture_name, "bracket"))
            "<span class=\"tok-bracket\">"
        else if (std.mem.eql(u8, capture_name, "field")) field: {
            // A method name is also a field; emit only one capture and retain
            // its function color when the field expression is the call target.
            const parent = ts.ts_node_parent(capture.node);
            const grandparent = ts.ts_node_parent(parent);
            const call_target = ts.ts_node_child_by_field_name(grandparent, "function", 8);
            const is_method = std.mem.eql(u8, std.mem.span(ts.ts_node_type(grandparent)), "call_expression") and
                ts.ts_node_eq(call_target, parent);
            break :field if (is_method) "<span class=\"tok-function\">" else "<span class=\"tok-field\">";
        } else return TreeSitterParserError.UnknownCapture;

        try writer.writeAll(opening_tag);
        try writeEscaped(writer, source[start..end]);
        try writer.writeAll("</span>");
        position = end;
    }

    try writeEscaped(writer, source[position..]);
}

test "writeEscaped preserves whitespace and escapes HTML characters" {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();

    try writeEscaped(&html.writer, "\tif (a < b && b > 0) {\n}\n");
    try std.testing.expectEqualStrings("\tif (a &lt; b &amp;&amp; b &gt; 0) {\n}\n", html.written());
}

test "render highlights Zig keywords and numbers" {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try render("const answer = 42;\n", "zig", &html.writer);
    try std.testing.expectEqualStrings("<span class=\"tok-keyword\">const</span> answer <span class=\"tok-operator\">=</span> <span class=\"tok-number\">42</span>;\n", html.written());
}

test "render escapes unknown and omitted languages" {
    for ([_][]const u8{ "", "c", "unknown" }) |language| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render("\t<a> & 42\n\n", language, &html.writer);
        try std.testing.expectEqualStrings("\t&lt;a&gt; &amp; 42\n\n", html.written());
    }
}

test "render escapes uncaptured Zig source and handles empty source" {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try render("", "zig", &html.writer);
    try std.testing.expectEqualStrings("", html.written());
    try render("a < b && b > c", "zig", &html.writer);
    try std.testing.expectEqualStrings("a &lt; b &amp;&amp; b &gt; c", html.written());
}

test "render highlights additional Zig tokens" {
    const cases = [_]struct { source: []const u8, html: []const u8 }{
        .{
            .source = "pub fn greet() void { return; }",
            .html = "<span class=\"tok-keyword\">pub</span> <span class=\"tok-keyword\">fn</span> <span class=\"tok-function\">greet</span><span class=\"tok-bracket\">(</span><span class=\"tok-bracket\">)</span> <span class=\"tok-type\">void</span> <span class=\"tok-bracket\">{</span> <span class=\"tok-keyword\">return</span>; <span class=\"tok-bracket\">}</span>",
        },
        .{
            .source = "var enabled: bool = true;",
            .html = "<span class=\"tok-keyword\">var</span> enabled: <span class=\"tok-type\">bool</span> <span class=\"tok-operator\">=</span> <span class=\"tok-constant\">true</span>;",
        },
        .{
            .source = "const value: f64 = 3.14;",
            .html = "<span class=\"tok-keyword\">const</span> value: <span class=\"tok-type\">f64</span> <span class=\"tok-operator\">=</span> <span class=\"tok-number\">3.14</span>;",
        },
        .{
            .source = "const text = \"const 42 < & >\\n\"; // return 123 < & >\n",
            .html = "<span class=\"tok-keyword\">const</span> text <span class=\"tok-operator\">=</span> <span class=\"tok-string\">\"const 42 &lt; &amp; &gt;\\n\"</span>; <span class=\"tok-comment\">// return 123 &lt; &amp; &gt;</span>\n",
        },
        .{
            .source = "const letter = '<';",
            .html = "<span class=\"tok-keyword\">const</span> letter <span class=\"tok-operator\">=</span> <span class=\"tok-string\">'&lt;'</span>;",
        },
        .{
            .source = "const text =\n    \\\\const 42 < & >\n;",
            .html = "<span class=\"tok-keyword\">const</span> text <span class=\"tok-operator\">=</span>\n    <span class=\"tok-string\">\\\\const 42 &lt; &amp; &gt;</span>\n;",
        },
        .{
            .source = "const size = @sizeOf(u32);",
            .html = "<span class=\"tok-keyword\">const</span> size <span class=\"tok-operator\">=</span> <span class=\"tok-builtin\">@sizeOf</span><span class=\"tok-bracket\">(</span><span class=\"tok-type\">u32</span><span class=\"tok-bracket\">)</span>;",
        },
        .{
            .source = "const missing = null; var value: u8 = undefined;",
            .html = "<span class=\"tok-keyword\">const</span> missing <span class=\"tok-operator\">=</span> <span class=\"tok-constant\">null</span>; <span class=\"tok-keyword\">var</span> value: <span class=\"tok-type\">u8</span> <span class=\"tok-operator\">=</span> <span class=\"tok-constant\">undefined</span>;",
        },
        .{
            .source = "fn run() void { greet(); object.call(); }",
            .html = "<span class=\"tok-keyword\">fn</span> <span class=\"tok-function\">run</span><span class=\"tok-bracket\">(</span><span class=\"tok-bracket\">)</span> <span class=\"tok-type\">void</span> <span class=\"tok-bracket\">{</span> <span class=\"tok-function\">greet</span><span class=\"tok-bracket\">(</span><span class=\"tok-bracket\">)</span>; object.<span class=\"tok-function\">call</span><span class=\"tok-bracket\">(</span><span class=\"tok-bracket\">)</span>; <span class=\"tok-bracket\">}</span>",
        },
        .{
            .source = "fn run() void { if (false) unreachable; }",
            .html = "<span class=\"tok-keyword\">fn</span> <span class=\"tok-function\">run</span><span class=\"tok-bracket\">(</span><span class=\"tok-bracket\">)</span> <span class=\"tok-type\">void</span> <span class=\"tok-bracket\">{</span> <span class=\"tok-keyword\">if</span> <span class=\"tok-bracket\">(</span><span class=\"tok-constant\">false</span><span class=\"tok-bracket\">)</span> <span class=\"tok-constant\">unreachable</span>; <span class=\"tok-bracket\">}</span>",
        },
    };
    for (cases) |case| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render(case.source, "zig", &html.writer);
        try std.testing.expectEqualStrings(case.html, html.written());
    }
}

test "render highlights arithmetic operators and all brackets" {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try render("const result = (a + b - c) / d * values[index]; const item = .{};", "zig", &html.writer);
    try std.testing.expectEqualStrings(
        "<span class=\"tok-keyword\">const</span> result <span class=\"tok-operator\">=</span> <span class=\"tok-bracket\">(</span>a <span class=\"tok-operator\">+</span> b <span class=\"tok-operator\">-</span> c<span class=\"tok-bracket\">)</span> <span class=\"tok-operator\">/</span> d <span class=\"tok-operator\">*</span> values<span class=\"tok-bracket\">[</span>index<span class=\"tok-bracket\">]</span>; <span class=\"tok-keyword\">const</span> item <span class=\"tok-operator\">=</span> .<span class=\"tok-bracket\">{</span><span class=\"tok-bracket\">}</span>;",
        html.written(),
    );
}

test "render highlights fields without overlapping method names" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "const x = object.field;", .expected = "object.<span class=\"tok-field\">field</span>;" },
        .{ .source = "const x = object.inner.field;", .expected = "object.<span class=\"tok-field\">inner</span>.<span class=\"tok-field\">field</span>;" },
        .{ .source = "const x = .{ .field = 42 };", .expected = ".<span class=\"tok-field\">field</span> <span class=\"tok-operator\">=</span>" },
        .{ .source = "const Item = struct { field: u32 };", .expected = "<span class=\"tok-field\">field</span>: <span class=\"tok-type\">u32</span>" },
        .{ .source = "fn run() void { object.inner.call(); }", .expected = "object.<span class=\"tok-field\">inner</span>.<span class=\"tok-function\">call</span>" },
        .{ .source = "fn run() void { object.call.field(); }", .expected = "object.<span class=\"tok-field\">call</span>.<span class=\"tok-function\">field</span>" },
    };
    for (cases) |case| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render(case.source, "zig", &html.writer);
        try std.testing.expect(std.mem.find(u8, html.written(), case.expected) != null);
    }
}

test "render keeps operators and brackets inside comments and strings unmodified" {
    const cases = [_]struct { source: []const u8, html: []const u8 }{
        .{
            .source = "// + - = / * () [] {} < & >\n",
            .html = "<span class=\"tok-comment\">// + - = / * () [] {} &lt; &amp; &gt;</span>\n",
        },
        .{
            .source = "/// field docs + ()\nconst x = 42;",
            .html = "<span class=\"tok-comment\">/// field docs + ()</span>\n<span class=\"tok-keyword\">const</span> x <span class=\"tok-operator\">=</span> <span class=\"tok-number\">42</span>;",
        },
        .{
            .source = "//! module docs * []\n",
            .html = "<span class=\"tok-comment\">//! module docs * []</span>\n",
        },
        .{
            .source = "const text = \"+ - = / * () [] {}\";",
            .html = "<span class=\"tok-keyword\">const</span> text <span class=\"tok-operator\">=</span> <span class=\"tok-string\">\"+ - = / * () [] {}\"</span>;",
        },
    };
    for (cases) |case| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render(case.source, "zig", &html.writer);
        try std.testing.expectEqualStrings(case.html, html.written());
    }
}
