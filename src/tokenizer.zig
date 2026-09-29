const std = @import("std");

pub const Tokenizer = struct {
    source: []const u8,
    index: usize = 0,
    marker: usize = 0,
    marker_line: usize = 1,
    line: usize = 1,

    pub fn init(source: []const u8) @This() {
        return .{ .source = source };
    }

    pub fn next(self: *@This()) Error!?Token {
        try self.skipWhitespace();

        self.mark();
        const c = self.peekChar() orelse return null;

        if (try self.nextIdentifier()) |identifier| {
            if (try self.toKeyword(identifier)) |keyword| {
                return keyword;
            } else if (try self.toVRegister(identifier)) |v_register| {
                return v_register;
            } else {
                return identifier;
            }
        }

        return switch (c) {
            '#' => {
                while (self.peekChar()) |p| {
                    if (p == '\n') return self.next();
                    try self.consume(1);
                }
                return null;
            },
            '=' => try self.tryStringMatch("==", .equal_equal) orelse
                try self.fromMarker(1, .equal),
            '!' => try self.tryStringMatch("!=", .bang_equal) orelse
                try self.fromMarker(1, .bang),
            '+' => try self.tryStringMatch("+=", .plus_equal) orelse
                try self.fromMarker(1, .plus),
            '-' => try self.tryStringMatch("-=", .minus_equal) orelse
                try self.fromMarker(1, .minus),
            '|' => try self.tryStringMatch("|=", .pipe_equal) orelse
                self.unknownToken(c),
            '&' => try self.tryStringMatch("&=", .ampersand_equal) orelse
                self.unknownToken(c),
            '^' => try self.tryStringMatch("^=", .hat_equal) orelse
                self.unknownToken(c),
            '>' => try self.tryStringMatch(">>=", .gt_gt_equal) orelse
                try self.tryStringMatch(">>", .gt_gt) orelse
                self.unknownToken(c),
            '<' => try self.tryStringMatch("<<=", .lt_lt_equal) orelse
                try self.tryStringMatch("<<", .lt_lt) orelse
                self.unknownToken(c),
            ':' => try self.fromMarker(1, .colon),
            '[' => try self.fromMarker(1, .open_bracket),
            ']' => try self.fromMarker(1, .close_bracket),
            '0' => {
                try self.consume(1);
                try self.expectChar('x');
                while (self.peekChar()) |p| {
                    if (std.ascii.isHex(p)) {
                        try self.consume(1);
                        continue;
                    }

                    break;
                }

                return try self.fromMarker(0, .number);
            },
            else => self.unknownToken(c),
        };
    }

    fn unknownToken(_: @This(), c: u8) Error {
        std.log.err("Unknown token {c}", .{c});
        return Error.UnknownToken;
    }

    fn mark(self: *@This()) void {
        self.marker = self.index;
        self.marker_line = self.line;
    }

    fn skipWhitespace(self: *@This()) Error!void {
        while (self.peekChar()) |p| {
            if (std.ascii.isWhitespace(p)) {
                try self.consume(1);
                continue;
            }

            break;
        }
    }

    fn nextChar(self: *@This()) Error!?u8 {
        if (self.index >= self.source.len) return null;
        const c = self.source[self.index];
        try self.consume(1);
        return c;
    }

    fn peekChar(self: @This()) ?u8 {
        if (self.index >= self.source.len) return null;
        return self.source[self.index];
    }

    fn consume(self: *@This(), n: usize) Error!void {
        const start_index = self.index;
        if (self.index + n > self.source.len) return Error.ConsumedTooManyTokens;
        self.index += n;
        const newlines = std.mem.countScalar(u8, self.source[start_index..self.index], '\n');
        self.line += newlines;
    }

    fn nextIdentifier(self: *@This()) Error!?Token {
        const first = self.peekChar() orelse return null;
        if (!std.ascii.isAlphabetic(first) and first != '_') return null;
        try self.consume(1);

        while (self.peekChar()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                try self.consume(1);
                continue;
            }

            break;
        }

        return try self.fromMarker(0, .identifier);
    }

    fn toKeyword(self: *@This(), tok: Token) Error!?Token {
        inline for (Token.keywords) |keyword| {
            if (std.mem.eql(u8, @tagName(keyword), tok.lexeme())) {
                return try self.fromMarker(0, keyword);
            }
        }

        return null;
    }

    fn toVRegister(self: *@This(), tok: Token) Error!?Token {
        if (tok.lexeme().len != 2) return null;
        if (std.ascii.toLower(tok.lexeme()[0]) != 'v') return null;
        if (!std.ascii.isHex(tok.lexeme()[1])) return null;

        return try self.fromMarker(0, .v_register);
    }

    fn stringMatch(self: @This(), s: []const u8) bool {
        const source = self.source[self.marker .. self.marker + s.len];
        if (source.len != s.len) return false;
        return std.mem.eql(u8, s, source);
    }

    fn tryStringMatch(self: *@This(), s: []const u8, tag: Token.Tag) Error!?Token {
        if (self.stringMatch(s)) {
            return try self.fromMarker(s.len, tag);
        }
        return null;
    }

    fn fromMarker(self: *@This(), n: usize, tag: Token.Tag) Error!Token {
        try self.consume(n);
        return .init(self.source, tag, self.marker, self.index - self.marker, self.marker_line);
    }

    fn expectChar(self: *@This(), c: u8) Error!void {
        const n = try self.nextChar() orelse {
            std.log.err("Expected {c}, found eof", .{c});
            return Error.UnexpectedChar;
        };

        if (n != c) {
            std.log.err("Expected {c}, found {c}", .{ c, n });
            return Error.UnexpectedChar;
        }
    }

    pub const Error = error{ UnknownToken, UnexpectedChar, ConsumedTooManyTokens };
};

pub const Token = struct {
    source: []const u8,
    tag: Tag,
    index: usize,
    len: usize,
    line: usize,

    pub fn init(source: []const u8, tag: Tag, index: usize, len: usize, line: usize) @This() {
        return .{ .source = source, .tag = tag, .index = index, .len = len, .line = line };
    }

    pub fn lexeme(self: @This()) []const u8 {
        return self.source[self.index .. self.index + self.len];
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try switch (self.tag) {
            .identifier, .number => writer.print("{t}({s})", .{ self.tag, self.lexeme() }),
            .v_register => writer.print("V({s})", .{self.lexeme()}),
            else => writer.print("{t}", .{self.tag}),
        };
    }

    pub const Tag = enum {
        colon,
        equal,
        equal_equal,
        bang_equal,
        bang,
        plus_equal,
        plus,
        minus_equal,
        minus,
        pipe_equal,
        ampersand_equal,
        hat_equal,
        gt_gt,
        lt_lt,
        gt_gt_equal,
        lt_lt_equal,
        open_bracket,
        close_bracket,
        identifier,
        number,
        v_register,
        pc,
        i,
        dcl,
        dis,
        jmp,
        jif,
        sbr,
        ret,
        set,
        rnd,
        k,
        fnt,
        dt,
        st,
        bcd,
        mem,
    };

    pub const keywords: []const Tag = &.{
        .pc,
        .i,
        .dcl,
        .dis,
        .jmp,
        .jif,
        .sbr,
        .ret,
        .set,
        .rnd,
        .k,
        .fnt,
        .dt,
        .st,
        .bcd,
        .mem,
    };
};
