const std = @import("std");
const entries = @import("entries.zig");
const Io = std.Io;

const Dir = Io.Dir;
const File = Io.File;

const epoch = std.time.epoch;

const mem = std.mem;

const Allocator = std.mem.Allocator;

const expect = std.testing.expect;
const eql = std.mem.eql;

const print = std.debug.print;

const POST_LIST_INSERT: []const u8 = "{{ post_list }}";

fn read_html(template_name: []const u8, templates_dir: Dir, io: Io, allocator: Allocator) ![]u8 {
    var file = try templates_dir.openFile(io, template_name, .{});
    defer file.close(io);

    var page_buffer: []u8 = &.{};
    var read_buffer: [8192]u8 = undefined;
    var offset: usize = 0;

    while (true) {
        const bytes_read = try file.readPositionalAll(io, &read_buffer, offset);
        if (bytes_read == 0) break;
        page_buffer = try allocator.realloc(page_buffer, page_buffer.len + bytes_read);
        @memmove(page_buffer[offset .. offset + bytes_read], read_buffer[0..bytes_read]);
        offset += bytes_read;
    }
    return page_buffer;
}

fn create_homepage_post(post: entries.Entry, allocator: Allocator) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;

    try writer.writeAll("<li>\n<a class=\"post-link\" href=\"");
    // These values are plain text, not rendered Markdown.
    const values = [_][]const u8{ post.slug, post.name, post.description };
    for (values, 0..) |value, index| {
        for (value) |character| {
            switch (character) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                '"' => try writer.writeAll("&quot;"),
                '\'' => try writer.writeAll("&#39;"),
                else => try writer.writeByte(character),
            }
        }
        switch (index) {
            0 => {
                try writer.writeAll(".html\">\n");
                const date_html = try post.render_homepage_date(allocator);
                defer allocator.free(date_html);
                try writer.writeAll(date_html);
                try writer.writeAll("<div class=\"post-summary\">\n<h3>");
            },
            1 => try writer.writeAll("</h3>\n<p>"),
            2 => try writer.writeAll("</p>\n</div>\n<span class=\"post-arrow\" aria-hidden=\"true\">&rarr;</span>\n</a>\n</li>\n"),
            else => unreachable,
        }
    }
    return output.toOwnedSlice();
}

test "create_homepage_post renders a post card" {
    const allocator = std.testing.allocator;
    const post: entries.Entry = .{
        .name = "Hello World",
        .slug = "hello-world",
        .description = "A small beginning: learning Zig by building this blog.",
        .date = "2026-10-01",
    };
    const html = try create_homepage_post(post, allocator);
    defer allocator.free(html);

    const expected =
        "<li>\n" ++
        "<a class=\"post-link\" href=\"hello-world.html\">\n" ++
        "<time class=\"post-date\" datetime=\"2026-10-01\">Oct 01, 2026</time>\n" ++
        "<div class=\"post-summary\">\n" ++
        "<h3>Hello World</h3>\n" ++
        "<p>A small beginning: learning Zig by building this blog.</p>\n" ++
        "</div>\n" ++
        "<span class=\"post-arrow\" aria-hidden=\"true\">&rarr;</span>\n" ++
        "</a>\n</li>\n";
    try std.testing.expectEqualStrings(expected, html);
}

test "create_homepage_post prefers timestamp and escapes metadata" {
    const allocator = std.testing.allocator;
    const post: entries.Entry = .{
        .name = "Zig <HTML> & \"quotes\"",
        .slug = "post\"&'",
        .description = "It's <safe> & escaped.",
        .date = "2026-10-01",
        .timestamp = 0,
    };
    const html = try create_homepage_post(post, allocator);
    defer allocator.free(html);

    try expect(mem.find(u8, html, "href=\"post&quot;&amp;&#39;.html\"") != null);
    try expect(mem.find(u8, html, "<h3>Zig &lt;HTML&gt; &amp; &quot;quotes&quot;</h3>") != null);
    try expect(mem.find(u8, html, "<p>It&#39;s &lt;safe&gt; &amp; escaped.</p>") != null);
    try expect(mem.find(u8, html, "datetime=\"1970-01-01\">Jan 01, 1970</time>") != null);
    try expect(mem.find(u8, html, "2026-10-01") == null);
}

test "create_homepage_post omits missing dates and rejects invalid dates" {
    const allocator = std.testing.allocator;
    const html = try create_homepage_post(.{ .name = "Undated post", .slug = "undated" }, allocator);
    defer allocator.free(html);

    try expect(mem.find(u8, html, "<time") == null);
    try expect(mem.find(u8, html, "<h3>Undated post</h3>\n<p></p>") != null);
    try std.testing.expectError(error.InvalidMetadataDate, create_homepage_post(.{
        .name = "Invalid date",
        .slug = "invalid",
        .date = "2026-02-30",
    }, allocator));
}

test "read_html" {
    const io = std.testing.io;
    const test_allocator = std.testing.allocator;
    const template_dir = try Dir.cwd().openDir(io, "templates", .{ .iterate = true });

    const page_html = try read_html("index.html", template_dir, io, test_allocator);
    defer test_allocator.free(page_html);
}

pub fn create_homepage(posts: []const entries.Entry, template_dir: Dir, public_dir: Dir, io: Io, allocator: Allocator) !void {
    const home_page = try read_html("index.html", template_dir, io, allocator);
    defer allocator.free(home_page);

    var buffer: []u8 = &.{};
    const injection_location = mem.find(u8, home_page, POST_LIST_INSERT) orelse return error.CannotFundInjectionPoint;
    buffer = try allocator.realloc(buffer, injection_location);
    defer allocator.free(buffer);

    @memcpy(buffer, home_page[0..injection_location]);

    var old_len = buffer.len;
    for (posts) |post| {
        const list_entry = try create_homepage_post(post, allocator);
        defer allocator.free(list_entry);
        buffer = try allocator.realloc(buffer, buffer.len + list_entry.len);
        @memcpy(buffer[old_len..], list_entry);
        old_len = buffer.len;
    }
    const remainder = home_page.len - (injection_location + POST_LIST_INSERT.len);
    buffer = try allocator.realloc(buffer, buffer.len + remainder);
    @memcpy(buffer[old_len..], home_page[injection_location + POST_LIST_INSERT.len ..]);

    var file = try public_dir.createFile(io, "index.html", .{ .read = true });
    defer file.close(io);

    try file.writePositionalAll(io, buffer, 0);
}

test "create_homepage" {
    const io = std.testing.io;
    const test_allocator = std.testing.allocator;
    const template_dir = try Dir.cwd().openDir(io, "templates", .{ .iterate = true });
    const public_dir = try Dir.cwd().openDir(io, "public", .{ .iterate = true });
    var post = entries.Entry{};
    try post.add_name("test_name", test_allocator);
    try post.add_description("Some description here", test_allocator);
    try post.add_timestamp("1791014010");
    try post.add_slug("test-name", test_allocator);
    defer post.deinit(test_allocator);
    var post2 = entries.Entry{};
    try post2.add_name("test_post_2", test_allocator);
    try post2.add_description("another post", test_allocator);
    try post2.add_timestamp("1791014300");
    try post2.add_slug("test-2", test_allocator);
    defer post2.deinit(test_allocator);
    const posts = [_]entries.Entry{ post, post2 };
    try create_homepage(&posts, template_dir, public_dir, io, test_allocator);
}
