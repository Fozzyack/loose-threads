const std = @import("std");
const highlight = @import("../highlight.zig");
const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const BlockQuoteType = enum(u8) {
    NONE,
    NOTE,
    IMPORTANT,
    DANGER,
    HELP,
    FAIL,
    FAILURE,
    TODO,
    INFO,
    QUOTE,

    pub fn from_marker(text: []const u8) ?BlockQuoteType {
        inline for (.{ .NOTE, .IMPORTANT, .DANGER, .HELP, .FAIL, .FAILURE, .TODO, .INFO, .QUOTE }) |tag| {
            const quote_type: BlockQuoteType = tag;
            if (eql(u8, text, "[!" ++ @tagName(quote_type) ++ "]")) return quote_type;
        }
        return null;
    }

    pub fn css_name(self: BlockQuoteType) []const u8 {
        return switch (self) {
            .NONE => "none",
            .NOTE => "note",
            .IMPORTANT => "important",
            .DANGER => "danger",
            .HELP => "help",
            .FAIL => "fail",
            .FAILURE => "failure",
            .TODO => "todo",
            .INFO => "info",
            .QUOTE => "quote",
        };
    }
};

pub const Section = enum(u8) {
    METADATA,
    CODE_BLOCK,
    QUOTE_BLOCK,
    NORMAL_MODE,
};

/// Buffered input and allocator-owned data for one Markdown file.
pub const FileParserState = struct {
    file: File,
    read_buffer: [8192]u8 = undefined,
    used: usize = 0,
    offset: usize = 0,

    header_count: u8 = 0,
    headers: [][]u8 = &.{},
    has_toc: bool = false,

    section: Section = .METADATA,

    code_language: [16]u8 = undefined,
    code_language_len: usize = 0,
    code_block_text: []u8 = &.{},

    block_quote_type: BlockQuoteType = BlockQuoteType.NONE,
    block_quote_text: []u8 = &.{},

    pub fn read_section(self: *FileParserState, io: Io) !?void {
        const bytes_read: usize = try self.file.readPositionalAll(io, self.read_buffer[self.used..], self.offset);
        if (bytes_read == 0) {
            if (self.section == .METADATA) return error.FailedToParseMetadata;
            if (self.section == .CODE_BLOCK) return error.EndOfCodeBlockNotFound;
            return null;
        }
        self.offset += bytes_read;
        self.used += bytes_read;
    }

    pub fn add_code_text(self: *FileParserState, idx: usize, allocator: Allocator) !void {
        const prev_len: usize = self.code_block_text.len;
        self.code_block_text = try allocator.realloc(self.code_block_text, prev_len + idx);
        @memcpy(self.code_block_text[prev_len..], self.read_buffer[0..idx]);
    }

    pub fn deinit_code_text(self: *FileParserState, allocator: Allocator) void {
        allocator.free(self.code_block_text);
        self.code_block_text = &.{};
    }

    pub fn add_quote_text(self: *FileParserState, text: []const u8, allocator: Allocator) !void {
        const prev_len: usize = self.block_quote_text.len;

        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try output.writer.writeAll("<p>");
        try highlight.render(text, "", &output.writer);
        try output.writer.writeAll("</p>\n");

        self.block_quote_text = try allocator.realloc(self.block_quote_text, prev_len + output.written().len);
        @memcpy(self.block_quote_text[prev_len..], output.written());
    }

    pub fn deinit_block_text(self: *FileParserState, allocator: Allocator) void {
        allocator.free(self.block_quote_text);
        self.block_quote_text = &.{};
    }

    pub fn change_language(self: *FileParserState, language: []const u8) !void {
        if (language.len > self.code_language.len) {
            return error.InvalidCodeLanguageTooLong;
        }
        self.code_language = undefined;
        @memcpy(self.code_language[0..language.len], language[0..]);
        self.code_language_len = language.len;
    }

    pub fn add_header(self: *FileParserState, header: []const u8, allocator: Allocator) !void {
        const prev_len = self.headers.len;
        const owned_header = try allocator.dupe(u8, header);
        errdefer allocator.free(owned_header);
        self.headers = try allocator.realloc(self.headers, prev_len + 1);
        self.headers[prev_len] = owned_header;
        self.header_count += 1;
    }

    pub fn strip_newlines(self: *FileParserState) void {
        if (self.read_buffer.len == 0) return;
        var newline_count: usize = 0;
        for (self.read_buffer[0..self.used]) |character| {
            if (character == '\n') newline_count += 1 else break;
        }
        @memmove(self.read_buffer[0 .. self.used - newline_count], self.read_buffer[newline_count..self.used]);
        self.used -= newline_count;
    }

    pub fn strip_section(self: *FileParserState, idx: usize) void {
        @memmove(self.read_buffer[0 .. self.used - (idx + 1)], self.read_buffer[(idx + 1)..self.used]);
        self.used -= (idx + 1);
    }

    pub fn deinit(self: *FileParserState, allocator: Allocator) void {
        if (self.code_block_text.len != 0) allocator.free(self.code_block_text);
        if (self.block_quote_text.len != 0) allocator.free(self.block_quote_text);
        if (self.headers.len > 0) {
            for (self.headers) |header| {
                allocator.free(header);
            }
            allocator.free(self.headers);
        }
    }
};

/// Shifts past leading newline bytes before the first non-newline byte in the
/// used portion of `buffer` and reduces `used` by the number removed.
/// Leaves all-newline input unchanged; `used` must not exceed `buffer.len`.
pub fn strip_newline(buffer: []u8, used: *usize) void {
    if (buffer.len == 0) return;
    var newline_count: usize = 0;
    for (buffer[0..used.*], 0..used.*) |character, index| {
        if (character != '\n') {
            newline_count = index;
            break;
        }
    }
    @memmove(buffer[0 .. used.* - newline_count], buffer[newline_count..used.*]);
    used.* -= newline_count;
}

fn test_add_headers(allocator: Allocator) !void {
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);
    try state.add_header("First heading", allocator);
    try state.add_header("Second heading", allocator);
    try std.testing.expectEqual(@as(u8, 2), state.header_count);
    try std.testing.expectEqualStrings("First heading", state.headers[0]);
    try std.testing.expectEqualStrings("Second heading", state.headers[1]);
}

test "FileParserState add_header is safe at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_add_headers, .{});
}

test "FileParserState add_code_text appends only the requested buffer prefix" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    @memcpy(state.read_buffer[0..12], "first\nunused");
    try state.add_code_text(6, allocator);
    try std.testing.expectEqualStrings("first\n", state.code_block_text);

    @memcpy(state.read_buffer[0..13], "second\nunused");
    try state.add_code_text(7, allocator);
    try std.testing.expectEqualStrings("first\nsecond\n", state.code_block_text);
    try std.testing.expectEqualStrings("second\nunused", state.read_buffer[0..13]);
}

test "FileParserState add_code_text accepts zero bytes" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    try state.add_code_text(0, allocator);
    try std.testing.expectEqual(@as(usize, 0), state.code_block_text.len);

    @memcpy(state.read_buffer[0..4], "code");
    try state.add_code_text(4, allocator);
    try state.add_code_text(0, allocator);
    try std.testing.expectEqualStrings("code", state.code_block_text);
}

test "FileParserState add_code_text copies a full read buffer" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    @memset(&state.read_buffer, 'x');
    try state.add_code_text(state.read_buffer.len, allocator);
    try std.testing.expectEqualSlices(u8, &state.read_buffer, state.code_block_text);
}

test "FileParserState add_code_text preserves existing text on allocation failure" {
    var storage: [4]u8 = undefined;
    var fixed_buffer: std.heap.FixedBufferAllocator = .init(&storage);
    const allocator = fixed_buffer.allocator();
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    @memcpy(state.read_buffer[0..4], "code");
    try state.add_code_text(4, allocator);
    try std.testing.expectError(error.OutOfMemory, state.add_code_text(1, allocator));
    try std.testing.expectEqualStrings("code", state.code_block_text);
}

test "FileParserState deinit_code_text clears text and allows reuse" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    @memcpy(state.read_buffer[0..5], "first");
    try state.add_code_text(5, allocator);
    state.deinit_code_text(allocator);
    try std.testing.expectEqual(@as(usize, 0), state.code_block_text.len);

    @memcpy(state.read_buffer[0..6], "second");
    try state.add_code_text(6, allocator);
    try std.testing.expectEqualStrings("second", state.code_block_text);
}

test "FileParserState deinit_code_text accepts empty and already cleared text" {
    const allocator = std.testing.allocator;
    var state: FileParserState = .{ .file = undefined };
    defer state.deinit(allocator);

    state.deinit_code_text(allocator);
    @memcpy(state.read_buffer[0..4], "code");
    try state.add_code_text(4, allocator);
    state.deinit_code_text(allocator);
    state.deinit_code_text(allocator);
    try std.testing.expectEqual(@as(usize, 0), state.code_block_text.len);
}

test "FileParserState deinit frees code text and accepts empty text" {
    const allocator = std.testing.allocator;
    var empty: FileParserState = .{ .file = undefined };
    empty.deinit(allocator);

    var populated: FileParserState = .{ .file = undefined };
    defer populated.deinit(allocator);
    populated.code_block_text = try allocator.dupe(u8, "allocated code\n");
    // std.testing.allocator reports a leak if deinit does not free this text.
}

test "strip newline" {
    var test_buffer: [9]u8 = "\n\n\n\ntest\n".*;
    var used: usize = test_buffer.len;
    strip_newline(&test_buffer, &used);
    try std.testing.expect(eql(u8, "test\n", test_buffer[0..used]));
}

test "strip newline no newline" {
    var test_buffer: [5]u8 = "test\n".*;
    var used: usize = test_buffer.len;
    strip_newline(&test_buffer, &used);
    try std.testing.expect(eql(u8, "test\n", test_buffer[0..used]));
}
