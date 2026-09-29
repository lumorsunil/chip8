const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;

pub const Chip8AssemblyParser = struct {
    allocator: Allocator,
    tokenizer: Tokenizer,
    instr_addr: u12 = 0x200,
    peek_buffer: std.Deque(Token) = .empty,
    last_token: ?Token = null,

    pub fn init(allocator: Allocator, source: []const u8) @This() {
        return .{ .allocator = allocator, .tokenizer = .init(source) };
    }

    pub fn next(self: *@This(), labels: *std.StringHashMap(u12)) Error!?Instruction {
        const tok = try self.peekToken() orelse return null;

        return switch (tok.tag) {
            .identifier => {
                try self.parseLabel(labels);
                return self.next(labels);
            },
            else => self.parseInstruction(),
        };
    }

    fn parseInstruction(self: *@This()) Error!?Instruction {
        defer self.instr_addr += 2;

        const tok = try self.peekToken() orelse return null;

        return switch (tok.tag) {
            .dcl => try self.parseDisplayClear(),
            .dis => try self.parseDisplayDraw(),
            .jmp => try self.parseJump(),
            .jif => try self.parseJumpIf(),
            .sbr => try self.parseSubroutine(),
            .ret => try self.parseReturn(),
            .set => try self.parseSet(),
            .bcd => try self.parseBCD(),
            else => self.expected("instruction"),
        };
    }

    fn nextToken(self: *@This()) Error!?Token {
        const tok = if (self.peek_buffer.len > 0)
            self.peek_buffer.popFront()
        else brk: {
            const tok = try self.tokenizer.next();
            if (tok) |t| std.log.debug("next token: {f}", .{t});
            break :brk tok;
        };

        self.last_token = tok;
        return tok;
    }

    fn peekToken(self: *@This()) Error!?Token {
        if (self.peek_buffer.len > 0) {
            return self.peek_buffer.front();
        }
        const tok = try self.nextToken() orelse return null;
        try self.peek_buffer.pushBack(self.allocator, tok);
        return tok;
    }

    fn parseLabel(self: *@This(), labels: *std.StringHashMap(u12)) Error!void {
        const identifier = try self.parseIdentifier();
        _ = try self.expect(.colon);
        try labels.put(identifier, self.instr_addr);
    }

    fn parseIdentifier(self: *@This()) Error![]const u8 {
        const tok = try self.expect(.identifier);
        return tok.lexeme();
    }

    fn parseValue12(self: *@This()) Error!ValueGeneric12 {
        const tok = try self.nextToken() orelse return self.expected("number or label");

        switch (tok.tag) {
            .number => {
                const addr = try std.fmt.parseInt(u12, tok.lexeme()[2..], 16);
                return .{ .literal = addr };
            },
            .colon => {
                const label = try self.parseIdentifier();
                return .{ .label = label };
            },
            .fnt => {
                const reg_tok = try self.expect(.v_register);
                const reg = try std.fmt.parseInt(u4, reg_tok.lexeme()[1..2], 16);
                return .{ .font = reg };
            },
            else => return self.expected("12-bit value"),
        }
    }

    fn parseValue8(self: *@This()) Error!ValueGeneric8 {
        const tok = try self.nextToken() orelse return self.expected("number or v register");

        return switch (tok.tag) {
            .number => {
                const byte = try std.fmt.parseInt(u8, tok.lexeme()[2..], 16);
                return .{ .literal = byte };
            },
            .v_register => {
                const v = try std.fmt.parseInt(u4, tok.lexeme()[1..2], 16);
                return .{ .v_register = v };
            },
            .i => .i_register,
            .rnd => {
                const byte_tok = try self.expect(.number);
                const byte = try std.fmt.parseInt(u8, byte_tok.lexeme()[2..4], 16);
                return .{ .random = byte };
            },
            .k, .bang => {
                const is_negated = tok.tag == .bang;
                if (tok.tag == .bang) _ = try self.expect(.k);

                const maybe_open_bracket = try self.peekToken() orelse {
                    if (tok.tag == .bang) {
                        return self.expected("[");
                    }

                    return .{ .key = .any };
                };

                if (maybe_open_bracket.tag == .open_bracket) {
                    _ = try self.expect(.open_bracket);
                    const reg_tok = try self.expect(.v_register);
                    const reg = try std.fmt.parseInt(u4, reg_tok.lexeme()[1..2], 16);
                    _ = try self.expect(.close_bracket);
                    return .{ .key = .{ .specific = .{ .reg = reg, .is_negated = is_negated } } };
                } else {
                    return .{ .key = .any };
                }
            },
            .dt => return .dt,
            .st => return .st,
            .mem => return .mem,
            else => self.expected("8-bit value"),
        };
    }

    fn parseDisplayClear(self: *@This()) Error!Instruction {
        _ = try self.expect(.dcl);
        return .dcl;
    }

    fn parseDisplayDraw(self: *@This()) Error!Instruction {
        _ = try self.expect(.dis);
        const x_tok = try self.expect(.v_register);
        const x = try std.fmt.parseInt(u4, x_tok.lexeme()[1..2], 16);
        const y_tok = try self.expect(.v_register);
        const y = try std.fmt.parseInt(u4, y_tok.lexeme()[1..2], 16);
        const height_tok = try self.expect(.number);
        const height = try std.fmt.parseInt(u4, height_tok.lexeme()[2..], 16);
        return .{ .dis = .{ .x = x, .y = y, .height = height } };
    }

    fn parseJump(self: *@This()) Error!Instruction {
        _ = try self.expect(.jmp);

        const tok = try self.peekToken() orelse return self.expected("address value");

        switch (tok.tag) {
            .open_bracket => {
                _ = try self.expect(.open_bracket);
                const addr = try self.parseValue12();
                _ = try self.expect(.plus);
                const v0 = try self.expect(.v_register);
                if (v0.lexeme()[1] != '0') return Error.InvalidJumpWithOffset;
                _ = try self.expect(.close_bracket);
                return .{ .jmp = .{ .addr = addr, .is_offset = true } };
            },
            else => {
                const addr = try self.parseValue12();
                return .{ .jmp = .{ .addr = addr } };
            },
        }
    }

    fn parseJumpIf(self: *@This()) Error!Instruction {
        _ = try self.expect(.jif);
        const lhs = try self.parseValue8();

        if (lhs == .key) {
            return .{ .jifk = .{ .key = lhs } };
        }

        const op = try self.parseJumpIfOp();
        const rhs = try self.parseValue8();

        return .{ .jif = .{ .lhs = lhs, .op = op, .rhs = rhs } };
    }

    fn parseJumpIfOp(self: *@This()) Error!Instruction.JumpIf.Op {
        const tok = try self.nextToken() orelse return self.expected("== or !=");

        return switch (tok.tag) {
            .equal_equal => .equal,
            .bang_equal => .not_equal,
            else => self.expected("== or !="),
        };
    }

    fn parseSetOp(self: *@This()) Error!Instruction.Set.Op {
        const tok = try self.nextToken() orelse return self.expected("= or +=");

        return switch (tok.tag) {
            .equal => .assign,
            .plus_equal => .assign_add,
            .pipe_equal => .assign_or,
            .ampersand_equal => .assign_and,
            .hat_equal => .assign_xor,
            .minus_equal => .assign_sub,
            .gt_gt_equal => .assign_shift_r,
            .lt_lt_equal => .assign_shift_l,
            .gt_gt => .shift_r,
            .lt_lt => .shift_l,
            else => self.expected("= or +="),
        };
    }

    fn parseSubroutine(self: *@This()) Error!Instruction {
        _ = try self.expect(.sbr);
        const addr = try self.parseValue12();
        return .{ .sbr = .{ .addr = addr } };
    }

    fn parseReturn(self: *@This()) Error!Instruction {
        _ = try self.expect(.ret);
        return .ret;
    }

    fn parseSet(self: *@This()) Error!Instruction {
        _ = try self.expect(.set);
        const lhs = try self.parseValue8();
        const op = try self.parseSetOp();

        if (lhs == .i_register) {
            switch (op) {
                .assign => {
                    const rhs = try self.parseValue12();
                    return .{ .set_i = .{ .rhs = rhs } };
                },
                else => {},
            }
        }

        const rhs = try self.parseValue8();

        if (lhs == .v_register and rhs == .v_register and op == .assign) {
            if (try self.peekToken()) |maybe_op| switch (maybe_op.tag) {
                .minus => {
                    _ = try self.expect(maybe_op.tag);
                    const sub_rhs = try self.parseValue8();

                    if (sub_rhs != .v_register) {
                        return Error.InvalidSubtraction;
                    }

                    if (sub_rhs.v_register != lhs.v_register) {
                        return Error.InvalidSubtraction;
                    }

                    return .{ .set = .{ .lhs = lhs, .op = .sub, .rhs = rhs } };
                },
                .lt_lt, .gt_gt => {
                    _ = try self.expect(maybe_op.tag);
                    const op_rhs = try self.parseValue8();

                    if (op_rhs != .literal) {
                        return Error.InvalidShift;
                    }

                    if (op_rhs.literal != 1) {
                        return Error.InvalidShift;
                    }

                    const actual_op: Instruction.Set.Op = switch (maybe_op.tag) {
                        .lt_lt => .shift_l,
                        .gt_gt => .shift_r,
                        else => unreachable,
                    };

                    return .{ .set = .{ .lhs = lhs, .op = actual_op, .rhs = rhs } };
                },
                else => {},
            };
        }

        return .{ .set = .{ .lhs = lhs, .op = op, .rhs = rhs } };
    }

    fn parseBCD(self: *@This()) Error!Instruction {
        _ = try self.expect(.bcd);
        const reg_tok = try self.expect(.v_register);
        const reg = try std.fmt.parseInt(u4, reg_tok.lexeme()[1..2], 16);
        return .{ .bcd = .{ .reg = reg } };
    }

    fn expect(self: *@This(), tag: Token.Tag) Error!Token {
        const tok = try self.nextToken() orelse return self.expected(@tagName(tag));
        if (tok.tag != tag) return self.expected(@tagName(tag));

        return tok;
    }

    fn expected(self: *@This(), expected_: []const u8) Error {
        if (self.last_token) |last_token| {
            std.log.err("Expected {s}, found {}", .{ expected_, last_token.tag });
        } else {
            std.log.err("Expected {s}, found eof", .{expected_});
        }
        return Error.UnexpectedToken;
    }

    pub const Error = error{
        UnexpectedToken,
        InvalidSubtraction,
        InvalidShift,
        InvalidJumpWithOffset,
    } || Allocator.Error || Tokenizer.Error || std.fmt.ParseIntError;
};

pub const Instruction = union(enum) {
    dcl: DisplayClear,
    dis: DisplayDraw,
    jmp: Jump,
    jif: JumpIf,
    jifk: JumpIfKey,
    sbr: Subroutine,
    ret: Return,
    set: Set,
    set_i: SetI,
    bcd: BCD,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |s| try writer.print("{f}", .{s}),
        }
    }

    pub const DisplayClear = struct {
        pub fn format(
            _: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("dcl", .{});
        }
    };

    pub const DisplayDraw = struct {
        x: u4,
        y: u4,
        height: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("dis {x} {x} {x}", .{ self.x, self.y, self.height });
        }
    };

    pub const Jump = struct {
        addr: ValueGeneric12,
        is_offset: bool = false,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            if (self.is_offset) {
                try writer.print("jmp addr=[{f} + V0/X?]", .{self.addr});
            } else {
                try writer.print("jmp addr={f}", .{self.addr});
            }
        }
    };

    pub const JumpIf = struct {
        lhs: ValueGeneric8,
        rhs: ValueGeneric8,
        op: Op,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jif {f} {f} {f}", .{ self.lhs, self.op, self.rhs });
        }

        pub const Op = enum {
            equal,
            not_equal,

            pub fn format(
                self: @This(),
                writer: *std.Io.Writer,
            ) std.Io.Writer.Error!void {
                try switch (self) {
                    .equal => writer.writeAll("=="),
                    .not_equal => writer.writeAll("!="),
                };
            }
        };
    };

    pub const JumpIfKey = struct {
        key: ValueGeneric8,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jif {f}", .{self.key});
        }
    };

    pub const Subroutine = struct {
        addr: ValueGeneric12,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("sbr addr={f}", .{self.addr});
        }
    };

    pub const Return = struct {
        pub fn format(
            _: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("ret", .{});
        }
    };

    pub const Set = struct {
        lhs: ValueGeneric8,
        rhs: ValueGeneric8,
        op: Op,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            if (self.op == .sub) {
                try writer.print("{f} = {f} {f} {f}", .{ self.lhs, self.rhs, self.op, self.lhs });
            } else {
                try writer.print("{f} {f} {f}", .{ self.lhs, self.op, self.rhs });
            }
        }

        pub const Op = enum {
            assign,
            assign_add,
            assign_or,
            assign_and,
            assign_xor,
            assign_sub,
            sub,
            assign_shift_l,
            assign_shift_r,
            shift_r,
            shift_l,

            pub fn format(
                self: @This(),
                writer: *std.Io.Writer,
            ) std.Io.Writer.Error!void {
                try switch (self) {
                    .assign => writer.print("=", .{}),
                    .assign_add => writer.print("+=", .{}),
                    .assign_or => writer.print("|=", .{}),
                    .assign_and => writer.print("&=", .{}),
                    .assign_xor => writer.print("^=", .{}),
                    .assign_sub => writer.print("-=", .{}),
                    .sub => writer.print("-", .{}),
                    .assign_shift_l => writer.print("<<=", .{}),
                    .assign_shift_r => writer.print(">>=", .{}),
                    .shift_l => writer.print("<<", .{}),
                    .shift_r => writer.print(">>", .{}),
                };
            }
        };
    };

    pub const SetI = struct {
        rhs: ValueGeneric12,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("I = {f}", .{self.rhs});
        }
    };

    pub const BCD = struct {
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("bcd V{x}", .{self.reg});
        }
    };
};

pub const ValueGeneric8 = union(enum) {
    literal: u8,
    v_register: u4,
    i_register,
    random: u8,
    key: union(enum) {
        any,
        specific: struct {
            reg: u4,
            is_negated: bool,
        },

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try switch (self) {
                .any => writer.print("k", .{}),
                .specific => |s| writer.print("{s}k[{x}]", .{ if (s.is_negated) "!" else "", s.reg }),
            };
        }
    },
    dt,
    st,
    mem,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try switch (self) {
            .literal => |s| writer.print("{x:02}", .{s}),
            .v_register => |s| writer.print("V{x}", .{s}),
            .i_register => writer.print("I", .{}),
            .random => |s| writer.print("rnd {x:02}", .{s}),
            .key => |s| writer.print("{f}", .{s}),
            .dt => writer.print("dt", .{}),
            .st => writer.print("st", .{}),
            .mem => writer.print("mem", .{}),
        };
    }
};

pub const ValueGeneric12 = union(enum) {
    literal: u12,
    label: []const u8,
    font: u4,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try switch (self) {
            .literal => |s| writer.print("{x:04}", .{s}),
            .label => |s| writer.print(":{s}", .{s}),
            .font => |s| writer.print("fnt {x}", .{s}),
        };
    }
};
