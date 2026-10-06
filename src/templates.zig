//! Renders homepage post lists and individual post pages from HTML templates.
//! Plain-text metadata is HTML-escaped; rendered post content is inserted verbatim.
const std = @import("std");
const log = @import("log.zig");
const entries = @import("entries.zig");
const Io = std.Io;

const Dir = Io.Dir;
const File = Io.File;

const epoch = std.time.epoch;

const mem = std.mem;

const Allocator = std.mem.Allocator;

const expect = std.testing.expect;
const eql = std.mem.eql;

const POST_LIST_INSERT: []const u8 = "{{ post_list }}";
const POST_CONTENT: []const u8 = "{{ content }}";
const POST_NAME: []const u8 = "{{ name }}";
const POST_DESCRIPTION: []const u8 = "{{ description }}";

/// Renders a linked list item with escaped slug, name, and description.
/// Includes the post's display date when present, preferring its UTC timestamp.
/// The caller owns the returned HTML and must free it with `allocator`.
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

/// Reads an entire template file relative to `templates_dir` without rendering it.
/// The caller owns the returned bytes and must free them with `allocator`.
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

test "read_html" {
    const io = std.testing.io;
    const test_allocator = std.testing.allocator;
    var templates = std.testing.tmpDir(.{});
    defer templates.cleanup();
    const template_dir = templates.dir;
    const expected = "<html><body>{{ post_list }}</body></html>";
    try template_dir.writeFile(io, .{ .sub_path = "index.html", .data = expected });

    const page_html = try read_html("index.html", template_dir, io, test_allocator);
    defer test_allocator.free(page_html);
    try std.testing.expectEqualStrings(expected, page_html);
}

/// Borrows a post and caches its optional calendar-based key for homepage sorting.
const HomepagePost = struct {
    post: entries.Entry,
    date_key: ?u64,

    /// Orders dated posts newest first, undated posts last, and ties by slug.
    fn newest_first(_: void, a: HomepagePost, b: HomepagePost) bool {
        if (a.date_key) |a_date| {
            const b_date = b.date_key orelse return true;
            if (a_date != b_date) return a_date > b_date;
        } else if (b.date_key != null) {
            return false;
        }
        return mem.order(u8, a.post.slug, b.post.slug) == .lt;
    }
};

/// Returns a sortable calendar key, preferring a UTC timestamp over a date.
/// Combines YYYYMMDD with seconds within the day so pre-epoch dates also sort.
/// Date-only posts use midnight; undated posts return null. Invalid dates or
/// timestamps return `InvalidMetadataDate` or `InvalidMetadataTimestamp`.
fn homepage_date_key(post: entries.Entry, allocator: Allocator) !?u64 {
    if (post.timestamp) |timestamp| {
        if (timestamp > 253402300799) return error.InvalidMetadataTimestamp;
        const seconds: epoch.EpochSeconds = .{ .secs = timestamp };
        const year_day = seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const calendar: u64 = @as(u64, year_day.year) * 10000 +
            @as(u64, month_day.month.numeric()) * 100 + @as(u64, month_day.day_index) + 1;
        return calendar * 86400 + timestamp % 86400;
    }
    if (post.date.len == 0) return null;
    var validated: entries.Entry = .{};
    try validated.add_date(post.date, allocator);
    defer allocator.free(validated.date);
    const year = try std.fmt.parseInt(u64, post.date[0..4], 10);
    const month = try std.fmt.parseInt(u64, post.date[5..7], 10);
    const day = try std.fmt.parseInt(u64, post.date[8..10], 10);
    return (year * 10000 + month * 100 + day) * 86400;
}

/// Renders post cards newest first, with undated posts last and ties sorted by slug.
/// Leaves the input posts unchanged and returns empty HTML for an empty slice.
/// The caller owns the returned HTML and must free it with `allocator`.
fn render_homepage_posts(posts: []const entries.Entry, allocator: Allocator) ![]u8 {
    const sorted = try allocator.alloc(HomepagePost, posts.len);
    defer allocator.free(sorted);
    for (posts, sorted) |post, *item| {
        item.* = .{ .post = post, .date_key = try homepage_date_key(post, allocator) };
    }
    mem.sort(HomepagePost, sorted, {}, HomepagePost.newest_first);

    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    for (sorted) |item| {
        const html = try create_homepage_post(item.post, allocator);
        defer allocator.free(html);
        try output.writer.writeAll(html);
    }
    return output.toOwnedSlice();
}

test "homepage posts are newest first with undated posts last" {
    const allocator = std.testing.allocator;
    const posts = [_]entries.Entry{
        .{ .name = "Undated", .slug = "undated" },
        .{ .name = "Old", .slug = "old", .date = "1969-12-31" },
        .{ .name = "Midnight", .slug = "midnight", .date = "1970-01-02" },
        .{ .name = "Newest", .slug = "newest", .date = "1900-01-01", .timestamp = 86401 },
        .{ .name = "Epoch", .slug = "epoch", .timestamp = 0 },
    };
    const html = try render_homepage_posts(&posts, allocator);
    defer allocator.free(html);
    const slugs = [_][]const u8{ "newest.html", "midnight.html", "epoch.html", "old.html", "undated.html" };
    var offset: usize = 0;
    for (slugs) |slug| {
        const location = mem.find(u8, html[offset..], slug) orelse return error.TestExpectedEqual;
        offset += location + slug.len;
    }
    try std.testing.expectEqualStrings("undated", posts[0].slug);
}

test "homepage sorting handles empty lists, ties, and invalid metadata" {
    const allocator = std.testing.allocator;
    const empty = try render_homepage_posts(&.{}, allocator);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
    const html = try render_homepage_posts(&.{
        .{ .name = "B", .slug = "b", .date = "2026-10-01" },
        .{ .name = "A", .slug = "a", .date = "2026-10-01" },
    }, allocator);
    defer allocator.free(html);
    try expect(mem.find(u8, html, "a.html").? < mem.find(u8, html, "b.html").?);
    try std.testing.expectError(error.InvalidMetadataDate, render_homepage_posts(&.{
        .{ .name = "Invalid", .date = "2026-02-30" },
    }, allocator));
    try std.testing.expectError(error.InvalidMetadataTimestamp, render_homepage_posts(&.{
        .{ .name = "Invalid", .timestamp = 253402300800 },
    }, allocator));
}

/// Reads `index.html` from `templates_dir`, replaces the first `{{ post_list }}`
/// marker with sorted post cards, and writes `index.html` into `public_dir`.
/// Replaces any existing output file; a missing marker returns
/// `CannotFindInjectionPoint`. Both directories remain owned by the caller.
pub fn create_homepage(posts: []const entries.Entry, templates_dir: Dir, public_dir: Dir, io: Io, allocator: Allocator) !void {
    const home_page = try read_html("index.html", templates_dir, io, allocator);
    defer allocator.free(home_page);
    try log.print("creating ... index.html\n", .{});

    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var writer = &output.writer;

    const injection_location = mem.find(u8, home_page, POST_LIST_INSERT) orelse return error.CannotFindInjectionPoint;
    try writer.writeAll(home_page[0..injection_location]);

    const post_list = try render_homepage_posts(posts, allocator);
    defer allocator.free(post_list);
    try writer.writeAll(post_list);
    try writer.writeAll(home_page[injection_location + POST_LIST_INSERT.len ..]);

    var file = try public_dir.createFile(io, "index.html", .{ .read = true });
    defer file.close(io);

    try file.writePositionalAll(io, output.written(), 0);
}

test "create_homepage" {
    const io = std.testing.io;
    const test_allocator = std.testing.allocator;
    var templates = std.testing.tmpDir(.{});
    defer templates.cleanup();
    var output = std.testing.tmpDir(.{});
    defer output.cleanup();
    const template_dir = templates.dir;
    const public_dir = output.dir;
    try template_dir.writeFile(io, .{ .sub_path = "index.html", .data = "<ul>{{ post_list }}</ul>" });
    var post = entries.Entry{};
    defer post.deinit(test_allocator);
    try post.add_name("test_name", test_allocator);
    try post.add_description("Some description here", test_allocator);
    try post.add_timestamp("1791014010");
    try post.add_slug("test-name", test_allocator);
    var post2 = entries.Entry{};
    defer post2.deinit(test_allocator);
    try post2.add_name("test_post_2", test_allocator);
    try post2.add_description("another post", test_allocator);
    try post2.add_timestamp("1791014300");
    try post2.add_slug("test-2", test_allocator);
    const posts = [_]entries.Entry{ post, post2 };
    try create_homepage(&posts, template_dir, public_dir, io, test_allocator);
    const html = try public_dir.readFileAlloc(io, "index.html", test_allocator, .unlimited);
    defer test_allocator.free(html);
    try expect(mem.startsWith(u8, html, "<ul>"));
    try expect(mem.endsWith(u8, html, "</ul>"));
    try expect(mem.find(u8, html, POST_LIST_INSERT) == null);
    const first = mem.find(u8, html, "href=\"test-2.html\"") orelse return error.TestExpectedEqual;
    const second = mem.find(u8, html, "href=\"test-name.html\"") orelse return error.TestExpectedEqual;
    try expect(first < second);
}

/// Replaces all content, name, and description markers in the supplied template.
/// Escapes metadata but preserves rendered content; inserted values are not
/// scanned for more markers. Requires `{{ content }}` or returns
/// `CannotFindInjectionPoint`. The caller must free the HTML with `allocator`.
fn render_post_page(post_html: []const u8, post: entries.Entry, allocator: Allocator) ![]u8 {
    if (mem.find(u8, post_html, POST_CONTENT) == null) return error.CannotFindInjectionPoint;
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    const fields = [_]struct { marker: []const u8, value: []const u8, escape: bool }{
        .{ .marker = POST_CONTENT, .value = post.content, .escape = false },
        .{ .marker = POST_NAME, .value = post.name, .escape = true },
        .{ .marker = POST_DESCRIPTION, .value = post.description, .escape = true },
    };
    var offset: usize = 0;
    while (offset < post_html.len) {
        var next: usize = post_html.len;
        var field_index: ?usize = null;
        for (fields, 0..) |field, index| {
            if (mem.find(u8, post_html[offset..], field.marker)) |location| {
                if (offset + location < next) {
                    next = offset + location;
                    field_index = index;
                }
            }
        }
        try writer.writeAll(post_html[offset..next]);
        const field = fields[field_index orelse break];
        if (field.escape) {
            for (field.value) |character| {
                switch (character) {
                    '&' => try writer.writeAll("&amp;"),
                    '<' => try writer.writeAll("&lt;"),
                    '>' => try writer.writeAll("&gt;"),
                    '"' => try writer.writeAll("&quot;"),
                    '\'' => try writer.writeAll("&#39;"),
                    else => try writer.writeByte(character),
                }
            }
        } else {
            try writer.writeAll(field.value);
        }
        offset = next + field.marker.len;
    }
    return output.toOwnedSlice();
}

test "render_post_page replaces metadata and preserves rendered content" {
    const allocator = std.testing.allocator;
    const page = "<title>{{ name }} | Loose Threads</title>" ++
        "<meta name=\"description\" content=\"{{ description }}\">" ++
        "<main>{{ content }}</main>";
    const html = try render_post_page(page, .{
        .name = "Zig <HTML> & \"quotes\"",
        .description = "It's <safe> & \"escaped\".",
        .content = "<h1>Body</h1>\n",
    }, allocator);
    defer allocator.free(html);

    try expect(mem.find(u8, html, "<title>Zig &lt;HTML&gt; &amp; &quot;quotes&quot; | Loose Threads</title>") != null);
    try expect(mem.find(u8, html, "content=\"It&#39;s &lt;safe&gt; &amp; &quot;escaped&quot;.\"") != null);
    try expect(mem.find(u8, html, "<h1>Body</h1>\n") != null);
    for ([_][]const u8{ POST_NAME, POST_DESCRIPTION, POST_CONTENT }) |marker| {
        try expect(mem.find(u8, html, marker) == null);
    }
}

test "render_post_page handles repeated reordered fields without recursive replacement" {
    const allocator = std.testing.allocator;
    const html = try render_post_page("{{ content }}|{{ description }}|{{ name }}|{{ name }}", .{
        .name = "{{ description }}",
        .content = "<p>{{ name }}</p>",
    }, allocator);
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<p>{{ name }}</p>||{{ description }}|{{ description }}", html);
    try std.testing.expectError(error.CannotFindInjectionPoint, render_post_page("{{ name }}", .{ .name = "Post" }, allocator));
}

/// Renders `page.html` from `templates_dir` into `{slug}.html` in `public_dir`.
/// Creates the output exclusively: an existing file returns `PathAlreadyExists`.
/// Both directories remain owned by the caller; temporary allocations are freed.
fn create_post_page(post: entries.Entry, templates_dir: Dir, public_dir: Dir, io: Io, allocator: Allocator) !void {
    const post_html = try read_html("page.html", templates_dir, io, allocator);
    defer allocator.free(post_html);
    const output = try render_post_page(post_html, post, allocator);
    defer allocator.free(output);

    const filename = try std.fmt.allocPrint(allocator, "{s}.html", .{post.slug});
    defer allocator.free(filename);
    try log.print("creating ... {s}\n", .{filename});
    var file = try public_dir.createFile(io, filename, .{ .exclusive = true, .read = true });
    defer file.close(io);

    try file.writePositionalAll(io, output, 0);
}

test "create_post_page" {
    const io = std.testing.io;
    const test_allocator = std.testing.allocator;
    var templates = std.testing.tmpDir(.{});
    defer templates.cleanup();
    var output = std.testing.tmpDir(.{});
    defer output.cleanup();
    const template_dir = templates.dir;
    const public_dir = output.dir;
    try template_dir.writeFile(io, .{ .sub_path = "page.html", .data = "<h1>{{ name }}</h1><p>{{ description }}</p><main>{{ content }}</main>" });
    var post = entries.Entry{};
    defer post.deinit(test_allocator);
    try post.add_name("test_name", test_allocator);
    try post.add_description("Some description here", test_allocator);
    try post.add_timestamp("1791014010");
    try post.add_slug("test-name", test_allocator);
    try create_post_page(post, template_dir, public_dir, io, test_allocator);
    const html = try public_dir.readFileAlloc(io, "test-name.html", test_allocator, .unlimited);
    defer test_allocator.free(html);
    try std.testing.expectEqualStrings("<h1>test_name</h1><p>Some description here</p><main></main>", html);
}

/// Creates one page per post in input order using `page.html` from `templates_dir`.
/// Stops at the first error without removing pages already written to `public_dir`.
/// Existing output files are not overwritten. Posts and directories are borrowed.
pub fn create_posts(posts: []const entries.Entry, templates_dir: Dir, public_dir: Dir, io: Io, allocator: Allocator) !void {
    for (posts) |post| {
        try create_post_page(post, templates_dir, public_dir, io, allocator);
    }
}

test "create_posts" {
    const io = std.testing.io;
    const test_allocator = std.testing.allocator;
    var templates = std.testing.tmpDir(.{});
    defer templates.cleanup();
    var output = std.testing.tmpDir(.{});
    defer output.cleanup();
    const template_dir = templates.dir;
    const public_dir = output.dir;
    try template_dir.writeFile(io, .{ .sub_path = "page.html", .data = "<h1>{{ name }}</h1><p>{{ description }}</p><main>{{ content }}</main>" });
    var post = entries.Entry{};
    defer post.deinit(test_allocator);
    try post.add_name("test_name", test_allocator);
    try post.add_description("Some description here", test_allocator);
    try post.add_timestamp("1791014010");
    try post.add_content("Some content here", test_allocator);
    try post.add_slug("test-name", test_allocator);
    var post2 = entries.Entry{};
    defer post2.deinit(test_allocator);
    try post2.add_name("test_post_2", test_allocator);
    try post2.add_description("another post", test_allocator);
    try post2.add_timestamp("1791014300");
    try post2.add_content("Some content here", test_allocator);
    try post2.add_slug("test-2", test_allocator);
    const posts = [_]entries.Entry{ post, post2 };
    try create_posts(&posts, template_dir, public_dir, io, test_allocator);
    const first = try public_dir.readFileAlloc(io, "test-name.html", test_allocator, .unlimited);
    defer test_allocator.free(first);
    const second = try public_dir.readFileAlloc(io, "test-2.html", test_allocator, .unlimited);
    defer test_allocator.free(second);
    try std.testing.expectEqualStrings("<h1>test_name</h1><p>Some description here</p><main>Some content here</main>", first);
    try std.testing.expectEqualStrings("<h1>test_post_2</h1><p>another post</p><main>Some content here</main>", second);
}
