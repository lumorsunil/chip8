const std = @import("std");
const Allocator = std.mem.Allocator;
const Chip8Emulator = @import("root.zig").Chip8Emulator;
const Chip8AssemblyParser = @import("parser.zig").Chip8AssemblyParser;
const Instruction = @import("parser.zig").Instruction;
const Chip8AssemblyCompiler = @import("compiler.zig").Chip8AssemblyCompiler;

pub const Chip8Assembler = struct {
    pub fn init() @This() {
        return .{};
    }

    pub fn compile(_: *@This(), source: []const u8, allocator: Allocator) Error![]const u8 {
        var parser: Chip8AssemblyParser = .init(allocator, source);
        var labels: std.StringHashMap(u12) = .init(allocator);
        var instructions: std.ArrayList(Instruction) = .empty;

        while (try parser.next(&labels)) |instruction| {
            try instructions.append(allocator, instruction);
            std.log.debug("[{x}] {f}", .{ parser.instr_addr - 2, instruction });
        }

        var compiler: Chip8AssemblyCompiler = .init(instructions.items, &labels);
        var machine_code: std.Io.Writer.Allocating = .init(allocator);

        try compiler.compile(&machine_code.writer);

        return try machine_code.toOwnedSlice();
    }

    pub const Error = error{} || Chip8AssemblyParser.Error || std.Io.Writer.Error || Chip8AssemblyCompiler.Error;
};
