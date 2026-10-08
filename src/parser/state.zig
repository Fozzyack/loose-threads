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
