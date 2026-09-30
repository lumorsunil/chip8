const std = @import("std");
const Chip8Emulator = @import("root.zig").Chip8Emulator;
const IRInstruction = @import("root.zig").Instruction;
const Instruction = @import("parser.zig").Instruction;
const ValueGeneric8 = @import("parser.zig").ValueGeneric8;
const ValueGeneric12 = @import("parser.zig").ValueGeneric12;

pub const Chip8AssemblyCompiler = struct {
    instructions: []const Instruction,
    labels: *std.StringHashMap(u12),

    pub fn init(instructions: []const Instruction, labels: *std.StringHashMap(u12)) @This() {
        return .{ .instructions = instructions, .labels = labels };
    }

    pub fn compile(self: @This(), writer: *std.Io.Writer) Error!void {
        for (self.instructions, 0..) |instruction, i| {
            const ir_instr = try self.compileInstruction(instruction);
            var ir_instr_as_u16 = ir_instr.toInt();
            ir_instr_as_u16 = Chip8Emulator.swapNibbles2(ir_instr_as_u16);
            ir_instr_as_u16 = Chip8Emulator.nibbleSwap(ir_instr_as_u16);
            try writer.writeInt(u16, ir_instr_as_u16, .native);
            std.log.debug("c[{x:04}] {x:02} {x:02}", .{ i, ir_instr_as_u16 & 0x00FF, (ir_instr_as_u16 & 0xFF00) >> 8 });
        }
    }

    fn compileInstruction(
        self: @This(),
        instruction: Instruction,
    ) Error!IRInstruction {
        return switch (instruction) {
            .dcl => .{ .display_clear = .{} },
            .dis => |dis| .{ .display_draw = .{
                .x = dis.x,
                .y = dis.y,
                .height = dis.height,
            } },
            .jmp => |jmp| switch (jmp.is_offset) {
                false => .{ .jump = .{
                    .addr = try self.evaluateValue12(jmp.addr),
                } },
                true => .{ .jump_with_offset = .{
                    .addr = try self.evaluateValue12(jmp.addr),
                } },
            },
            .jif => |jif| switch (jif.lhs) {
                .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAddr,
                .literal => self.compileJumpIf(jif.rhs, jif.lhs, jif.op),
                .v_register => self.compileJumpIf(jif.lhs, jif.rhs, jif.op),
            },
            .jifk => |jif| switch (jif.key) {
                .literal, .v_register, .i_register, .random, .dt, .st, .mem => Error.InvalidKey,
                .key => |key| switch (key) {
                    .any => Error.InvalidKey,
                    .specific => |s| switch (s.is_negated) {
                        true => .{ .jump_if_key_up = .{ .reg = s.reg } },
                        false => .{ .jump_if_key_down = .{ .reg = s.reg } },
                    },
                },
            },
            .sbr => |sbr| .{ .call = .{
                .addr = try self.evaluateValue12(sbr.addr) -% 2,
            } },
            .ret => .{ .ret = .{} },
            .set => |set| switch (set.op) {
                .assign => switch (set.lhs) {
                    .literal, .i_register, .random, .key => Error.InvalidLValue,
                    .v_register => |v_register| switch (set.rhs) {
                        .i_register, .st => Error.InvalidAssignment,
                        .literal => |s| .{ .set_v_to_data = .{ .reg = v_register, .data = s } },
                        .v_register => |rhs| .{ .set_v_to_v = .{ .lhs = v_register, .rhs = rhs } },
                        .random => |rhs| .{ .random = .{ .reg = v_register, .data = rhs } },
                        .dt => .{ .set_v_to_dt = .{ .reg = v_register } },
                        .key => |key| switch (key) {
                            .specific => Error.InvalidKey,
                            .any => .{ .set_v_to_key = .{ .reg = v_register } },
                        },
                        .mem => .{ .set_v_to_mem = .{ .reg = v_register } },
                    },
                    .dt => switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |v_register| .{ .set_dt_to_v = .{ .reg = v_register } },
                    },
                    .st => switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |v_register| .{ .set_st_to_v = .{ .reg = v_register } },
                    },
                    .mem => switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |v_register| .{ .set_mem_to_v = .{ .reg = v_register } },
                    },
                },
                .assign_add => switch (set.lhs) {
                    .literal, .random, .key, .dt, .st, .mem => Error.InvalidLValue,
                    .v_register => |v_register| switch (set.rhs) {
                        .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .literal => |s| .{ .add_data_to_v = .{ .reg = v_register, .data = s } },
                        .v_register => |rhs| .{ .add_v_to_v = .{ .lhs = v_register, .rhs = rhs } },
                    },
                    .i_register => switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |rhs| .{ .add_v_to_i = .{ .reg = rhs } },
                    },
                },
                .assign_or => switch (set.lhs) {
                    .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    .v_register => |lhs| switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |rhs| .{ .or_vv = .{ .lhs = lhs, .rhs = rhs } },
                    },
                },
                .assign_and => switch (set.lhs) {
                    .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    .v_register => |lhs| switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |rhs| .{ .and_vv = .{ .lhs = lhs, .rhs = rhs } },
                    },
                },
                .assign_xor => switch (set.lhs) {
                    .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    .v_register => |lhs| switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |rhs| .{ .xor_vv = .{ .lhs = lhs, .rhs = rhs } },
                    },
                },
                .assign_sub => switch (set.lhs) {
                    .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    .v_register => |lhs| switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |rhs| .{ .sub_vx_vy = .{ .lhs = lhs, .rhs = rhs } },
                    },
                },
                .sub => switch (set.lhs) {
                    .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    .v_register => |lhs| switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |rhs| .{ .sub_vy_vx = .{ .lhs = lhs, .rhs = rhs } },
                    },
                },
                .assign_shift_l => switch (set.lhs) {
                    .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    .v_register => |lhs| switch (set.rhs) {
                        .literal => .{ .shift_left = .{ .lhs = lhs, .rhs = lhs } },
                        .i_register, .v_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    },
                },
                .assign_shift_r => switch (set.lhs) {
                    .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    .v_register => |lhs| switch (set.rhs) {
                        .literal => .{ .shift_right = .{ .lhs = lhs, .rhs = lhs } },
                        .i_register, .v_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    },
                },
                .shift_l => switch (set.lhs) {
                    .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    .v_register => |lhs| switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |rhs| .{ .shift_left = .{ .lhs = lhs, .rhs = rhs } },
                    },
                },
                .shift_r => switch (set.lhs) {
                    .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                    .v_register => |lhs| switch (set.rhs) {
                        .literal, .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAssignment,
                        .v_register => |rhs| .{ .shift_right = .{ .lhs = lhs, .rhs = rhs } },
                    },
                },
            },
            .set_i => |set_i| switch (set_i.rhs) {
                .font => |s| .{ .set_i_to_font = .{ .reg = s } },
                else => .{ .set_i = .{ .data = try self.evaluateValue12(set_i.rhs) } },
            },
            .bcd => |bcd| .{ .bcd = .{ .reg = bcd.reg } },
        };
    }

    fn compileJumpIf(
        self: @This(),
        lhs: ValueGeneric8,
        rhs: ValueGeneric8,
        op: Instruction.JumpIf.Op,
    ) Error!IRInstruction {
        return switch (rhs) {
            .i_register, .random, .key, .dt, .st, .mem => Error.InvalidAddr,
            .literal => |s| self.compileJumpIfVEqData(lhs.v_register, s, op),
            .v_register => |s| self.compileJumpIfVEqV(lhs.v_register, s, op),
        };
    }

    fn compileJumpIfVEqData(_: @This(), lhs: u4, rhs: u8, op: Instruction.JumpIf.Op) IRInstruction {
        return switch (op) {
            .equal => .{ .jump_if_v_eq_data = .{ .reg = lhs, .data = rhs } },
            .not_equal => .{ .jump_if_v_neq_data = .{ .reg = lhs, .data = rhs } },
        };
    }

    fn compileJumpIfVEqV(_: @This(), lhs: u4, rhs: u4, op: Instruction.JumpIf.Op) IRInstruction {
        return switch (op) {
            .equal => .{ .jump_if_v_eq_v = .{ .lhs = lhs, .rhs = rhs } },
            .not_equal => .{ .jump_if_v_neq_v = .{ .lhs = lhs, .rhs = rhs } },
        };
    }

    fn evaluateValue12(self: @This(), value: ValueGeneric12) Error!u12 {
        return switch (value) {
            .literal => |s| s,
            .label => |s| self.labels.get(s) orelse {
                std.log.err("Label \"{s}\" not defined", .{s});
                return Error.LabelNotDefined;
            },
            .font => unreachable,
        };
    }

    pub const Error = error{
        LabelNotDefined,
        InvalidLValue,
        InvalidAddr,
        InvalidAssignment,
        InvalidKey,
    } || std.Io.Writer.Error;
};
