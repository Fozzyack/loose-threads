const std = @import("std");
const ts = @import("tree_sitter");

extern fn tree_sitter_zig() ?*const ts.TSLanguage;
extern fn tree_sitter_python() ?*const ts.TSLanguage;
extern fn tree_sitter_c() ?*const ts.TSLanguage;
extern fn tree_sitter_json() ?*const ts.TSLanguage;
extern fn tree_sitter_bash() ?*const ts.TSLanguage;

const TreeSitterParserError = error{ OutOfMemory, ParseFailed, MissingGrammar, IncompatibleGrammar, InvalidHighlightQuery, OverlappingErrors, UnknownCapture, CodeBlockTooLarge };

const Grammar = enum { zig, python, c, json, bash };

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

/// Writes escaped code with the selected language's token highlighting.
/// Unknown or omitted languages are rendered as plain escaped text.
pub fn render(source: []const u8, language_name: []const u8, writer: *std.Io.Writer) !void {
    const grammar: Grammar = if (std.mem.eql(u8, language_name, "zig")) .zig else if (std.mem.eql(u8, language_name, "python")) .python else if (std.mem.eql(u8, language_name, "c")) .c else if (std.mem.eql(u8, language_name, "json")) .json else if (std.mem.eql(u8, language_name, "sh") or std.mem.eql(u8, language_name, "bash")) .bash else {
        try writeEscaped(writer, source);
        return;
    };
    if (source.len > std.math.maxInt(u32)) return TreeSitterParserError.CodeBlockTooLarge;

    const parser = ts.ts_parser_new() orelse
        return TreeSitterParserError.OutOfMemory;
    defer ts.ts_parser_delete(parser);

    const language = (switch (grammar) {
        .zig => tree_sitter_zig(),
        .python => tree_sitter_python(),
        .c => tree_sitter_c(),
        .json => tree_sitter_json(),
        .bash => tree_sitter_bash(),
    }) orelse return TreeSitterParserError.MissingGrammar;

    if (!ts.ts_parser_set_language(parser, language)) {
        return TreeSitterParserError.IncompatibleGrammar;
    }

    const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return TreeSitterParserError.ParseFailed;
    defer ts.ts_tree_delete(tree);

    const root = ts.ts_tree_root_node(tree);

    const query_source = switch (grammar) {
        .zig => @embedFile("queries/zig.scm"),
        .python => @embedFile("queries/python.scm"),
        .c => @embedFile("queries/c.scm"),
        .json => @embedFile("queries/json.scm"),
        .bash => @embedFile("queries/bash.scm"),
    };
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
    var emitted_start: usize = 0;
    var match: ts.TSQueryMatch = undefined;
    var capture_index: u32 = 0;

    while (ts.ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
        const capture = match.captures[capture_index];

        const start = ts.ts_node_start_byte(capture.node);
        const end = ts.ts_node_end_byte(capture.node);

        var name_len: u32 = 0;
        const name = ts.ts_query_capture_name_for_id(query, capture.index, &name_len);

        const capture_name = name[0..name_len];

        // Whole strings can contain captured interpolation/substitution nodes.
        // Keep the outer capture, but never silently discard partial overlaps.
        if (start < position) {
            if (start >= emitted_start and end <= position) continue;
            return TreeSitterParserError.OverlappingErrors;
        }

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
        else if (std.mem.eql(u8, capture_name, "variable"))
            "<span class=\"tok-variable\">"
        else if (std.mem.eql(u8, capture_name, "parameter"))
            "<span class=\"tok-parameter\">"
        else if (std.mem.eql(u8, capture_name, "operator"))
            "<span class=\"tok-operator\">"
        else if (std.mem.eql(u8, capture_name, "bracket"))
            "<span class=\"tok-bracket\">"
        else if (std.mem.eql(u8, capture_name, "field")) field: {
            if (grammar != .zig) break :field "<span class=\"tok-field\">";
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
        emitted_start = start;
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
    for ([_][]const u8{ "", "rust", "unknown", "<img>&", "Python" }) |language| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render("\t<a> & 42\n\n", language, &html.writer);
        try std.testing.expectEqualStrings("\t&lt;a&gt; &amp; 42\n\n", html.written());
    }
}

// Removing only our span tags must reproduce the escaped input byte for byte.
fn expectSourcePreserved(source: []const u8, html: []const u8) !void {
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    try writeEscaped(&expected.writer, source);
    var actual: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer actual.deinit();
    var position: usize = 0;
    while (position < html.len) {
        if (std.mem.startsWith(u8, html[position..], "<span class=\"tok-") or
            std.mem.startsWith(u8, html[position..], "</span>"))
        {
            position += (std.mem.findScalar(u8, html[position..], '>') orelse return error.InvalidHtml) + 1;
        } else {
            try actual.writer.writeByte(html[position]);
            position += 1;
        }
    }
    try std.testing.expectEqualStrings(expected.written(), actual.written());
}

// Even empty input creates the external scanner. Run in ReleaseSafe to catch
// constructor callback type mismatches before query/highlighting behavior.
test "external scanner constructors match the runtime callback ABI" {
    for ([_]?*const ts.TSLanguage{ tree_sitter_python(), tree_sitter_bash() }) |language| {
        const parser = ts.ts_parser_new() orelse return error.OutOfMemory;
        defer ts.ts_parser_delete(parser);
        try std.testing.expect(ts.ts_parser_set_language(parser, language orelse return error.MissingGrammar));
        const tree = ts.ts_parser_parse_string(parser, null, "", 0) orelse return error.ParseFailed;
        defer ts.ts_tree_delete(tree);
        try std.testing.expect(!ts.ts_node_has_error(ts.ts_tree_root_node(tree)));
    }
}

test "render highlights Python C JSON and shell while preserving escaped source" {
    const cases = [_]struct { language: []const u8, source: []const u8, fragments: []const []const u8 }{
        .{ .language = "python", .source = "def greet():\n\treturn 42, True, \"< & >\" # comment\n", .fragments = &.{
            "<span class=\"tok-keyword\">def</span>",                "<span class=\"tok-function\">greet</span>",
            "<span class=\"tok-number\">42</span>",                  "<span class=\"tok-constant\">True</span>",
            "<span class=\"tok-string\">\"&lt; &amp; &gt;\"</span>", "<span class=\"tok-comment\"># comment</span>",
        } },
        .{ .language = "c", .source = "int greet(void) { return 42; } /* < & > */\nconst char *text = \"< & >\";", .fragments = &.{
            "<span class=\"tok-type\">int</span>",                   "<span class=\"tok-function\">greet</span>",
            "<span class=\"tok-keyword\">return</span>",             "<span class=\"tok-number\">42</span>",
            "<span class=\"tok-string\">\"&lt; &amp; &gt;\"</span>", "<span class=\"tok-comment\">/* &lt; &amp; &gt; */</span>",
        } },
        .{ .language = "json", .source = "{\"key\": [42, true, false, null, \"< & >\"]}\n", .fragments = &.{
            "<span class=\"tok-field\">\"key\"</span>",              "<span class=\"tok-number\">42</span>",
            "<span class=\"tok-constant\">true</span>",              "<span class=\"tok-constant\">null</span>",
            "<span class=\"tok-string\">\"&lt; &amp; &gt;\"</span>", "<span class=\"tok-bracket\">[</span>",
        } },
        .{ .language = "bash", .source = "if true; then\n echo \"< & >\" # comment\nfi\nx=$((42 + 1))\n", .fragments = &.{
            "<span class=\"tok-keyword\">if</span>",                 "<span class=\"tok-function\">echo</span>",
            "<span class=\"tok-string\">\"&lt; &amp; &gt;\"</span>", "<span class=\"tok-comment\"># comment</span>",
            "<span class=\"tok-number\">42</span>",                  "<span class=\"tok-operator\">+</span>",
        } },
    };
    for (cases) |case| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render(case.source, case.language, &html.writer);
        for (case.fragments) |fragment| try std.testing.expect(std.mem.find(u8, html.written(), fragment) != null);
        try expectSourcePreserved(case.source, html.written());
    }
}

test "render keeps nested f-string and shell substitution captures inside whole strings" {
    const cases = [_]struct { language: []const u8, source: []const u8, string: []const u8 }{
        .{ .language = "python", .source = "text = f\"< & > {greet(42)} {f'{1 + 2}'}\"\n", .string = "<span class=\"tok-string\">f\"&lt; &amp; &gt; {greet(42)} {f'{1 + 2}'}\"</span>" },
        .{ .language = "bash", .source = "echo \"< & > $(echo \"$(printf '%s' 42)\") ${value:-$(echo 1)}\"\n", .string = "<span class=\"tok-string\">\"&lt; &amp; &gt; $(echo \"$(printf '%s' 42)\") ${value:-$(echo 1)}\"</span>" },
    };
    for (cases) |case| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render(case.source, case.language, &html.writer);
        try std.testing.expect(std.mem.find(u8, html.written(), case.string) != null);
        try expectSourcePreserved(case.source, html.written());
    }
}

test "render shell aliases identically and accepts empty source for every language" {
    var bash: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bash.deinit();
    var sh: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sh.deinit();
    const source = "if true; then echo \"$(echo 42)\"; fi\n";
    try render(source, "bash", &bash.writer);
    try render(source, "sh", &sh.writer);
    try std.testing.expectEqualStrings(bash.written(), sh.written());
    try expectSourcePreserved(source, sh.written());
    for ([_][]const u8{ "zig", "python", "c", "json", "sh", "bash", "", "unknown" }) |language| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render("", language, &html.writer);
        try std.testing.expectEqualStrings("", html.written());
    }
}

test "render escapes Zig comparisons and handles empty source" {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try render("", "zig", &html.writer);
    try std.testing.expectEqualStrings("", html.written());
    const source = "const result = a < b and b > c;\n";
    try render(source, "zig", &html.writer);
    try std.testing.expect(std.mem.find(u8, html.written(), "a <span class=\"tok-operator\">&lt;</span> b") != null);
    try expectSourcePreserved(source, html.written());
}

test "render highlights Python parameters and prioritizes methods over attributes" {
    const source = "@obj.decorate\ndef run(plain, typed: int, default=1, both: str=\"<&>\", *args: int, **kwargs: str):\n\tobj.inner.method(key=obj.field)\n\treturn lambda item, fallback=2, *rest, **options: item\n";
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try render(source, "python", &html.writer);
    for ([_][]const u8{ "plain", "typed", "default", "both", "args", "kwargs", "item", "fallback", "rest", "options" }) |name| {
        const fragment = try std.fmt.allocPrint(std.testing.allocator, "<span class=\"tok-parameter\">{s}</span>", .{name});
        defer std.testing.allocator.free(fragment);
        try std.testing.expect(std.mem.find(u8, html.written(), fragment) != null);
    }
    for ([_][]const u8{
        "obj.<span class=\"tok-function\">decorate</span>",
        "obj.<span class=\"tok-field\">inner</span>.<span class=\"tok-function\">method</span>",
        "obj.<span class=\"tok-field\">field</span>",
        "<span class=\"tok-type\">int</span>",
        "<span class=\"tok-string\">\"&lt;&amp;&gt;\"</span>",
    }) |fragment| try std.testing.expect(std.mem.find(u8, html.written(), fragment) != null);
    try std.testing.expect(std.mem.find(u8, html.written(), "tok-field\">method") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html.written(), "<span class=\"tok-function\">method</span>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html.written(), "<span class=\"tok-function\">decorate</span>"));
    try std.testing.expect(std.mem.find(u8, html.written(), "tok-parameter\">obj") == null);
    try expectSourcePreserved(source, html.written());
}

test "render highlights C function pointers and direct pointer and array parameters" {
    const source = "int (*callback)(int value, const char *text);\nint (**indirect)(int count);\nint (*handlers[2])(int index);\nvoid run(int direct, char **argv, int items[3], int (*visit)(int element)) { obj.field; callback(direct, \"<&>\"); }\n";
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try render(source, "c", &html.writer);
    for ([_][]const u8{ "callback", "indirect", "handlers", "run", "visit" }) |name| {
        const fragment = try std.fmt.allocPrint(std.testing.allocator, "<span class=\"tok-function\">{s}</span>", .{name});
        defer std.testing.allocator.free(fragment);
        try std.testing.expect(std.mem.find(u8, html.written(), fragment) != null);
    }
    for ([_][]const u8{ "value", "text", "count", "index", "direct", "argv", "items", "element" }) |name| {
        const fragment = try std.fmt.allocPrint(std.testing.allocator, "<span class=\"tok-parameter\">{s}</span>", .{name});
        defer std.testing.allocator.free(fragment);
        try std.testing.expect(std.mem.find(u8, html.written(), fragment) != null);
    }
    try std.testing.expect(std.mem.find(u8, html.written(), "<span class=\"tok-field\">field</span>") != null);
    try std.testing.expect(std.mem.find(u8, html.written(), "<span class=\"tok-type\">int</span>") != null);
    try expectSourcePreserved(source, html.written());
}

test "render highlights shell assignments and unquoted expansions but keeps strings whole" {
    const source = "value=42\n\techo $value ${value:-fallback} $? \"$value ${value} <&>\"\n";
    for ([_][]const u8{ "sh", "bash" }) |language| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render(source, language, &html.writer);
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, html.written(), "<span class=\"tok-variable\">value</span>"));
        try std.testing.expect(std.mem.find(u8, html.written(), "<span class=\"tok-constant\">?</span>") != null);
        try std.testing.expect(std.mem.find(u8, html.written(), "<span class=\"tok-string\">\"$value ${value} &lt;&amp;&gt;\"</span>") != null);
        try expectSourcePreserved(source, html.written());
    }
}

test "render highlights grammar supported Zig operators without duplicate captures" {
    const operators = [_][]const u8{ "%", "==", "!=", "<", "<=", ">", ">=", "&", "|", "^", "<<", ">>", "+%", "-%", "*%", "+|", "-|", "*|", "<<|", "++", "**", "||" };
    for (operators) |operator| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "const result = a {s} b;\n", .{operator});
        defer std.testing.allocator.free(source);
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render(source, "zig", &html.writer);
        var escaped: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer escaped.deinit();
        try writeEscaped(&escaped.writer, operator);
        const fragment = try std.fmt.allocPrint(std.testing.allocator, "<span class=\"tok-operator\">{s}</span>", .{escaped.written()});
        defer std.testing.allocator.free(fragment);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html.written(), fragment));
        try expectSourcePreserved(source, html.written());
    }
    for ([_][]const u8{ "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "+%=", "-%=", "*%=", "+|=", "-|=", "*|=", "<<|=" }) |operator| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "fn run() void {{ a {s} b; }}\n", .{operator});
        defer std.testing.allocator.free(source);
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render(source, "zig", &html.writer);
        var escaped: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer escaped.deinit();
        try writeEscaped(&escaped.writer, operator);
        const fragment = try std.fmt.allocPrint(std.testing.allocator, "<span class=\"tok-operator\">{s}</span>", .{escaped.written()});
        defer std.testing.allocator.free(fragment);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html.written(), fragment));
        try expectSourcePreserved(source, html.written());
    }
}

test "render highlights Zig unary pointer range and switch operators" {
    const cases = [_]struct { source: []const u8, operators: []const []const u8 }{
        .{ .source = "const value = !flag; const bits = ~mask; const ptr = &value;", .operators = &.{ "!", "~", "&amp;" } },
        .{ .source = "const value = ptr.*; const unwrapped = optional.?; var maybe: ?u8 = null;", .operators = &.{ ".*", ".?", "?" } },
        .{ .source = "const slice = values[0..2]; const result = switch (value) { 0...2 => 1, else => 0 };", .operators = &.{ "..", "...", "=&gt;" } },
    };
    for (cases) |case| {
        var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer html.deinit();
        try render(case.source, "zig", &html.writer);
        for (case.operators) |operator| {
            const fragment = try std.fmt.allocPrint(std.testing.allocator, "<span class=\"tok-operator\">{s}</span>", .{operator});
            defer std.testing.allocator.free(fragment);
            try std.testing.expect(std.mem.find(u8, html.written(), fragment) != null);
        }
        try expectSourcePreserved(case.source, html.written());
    }
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
