const std = @import("std");
const Chip8Emulator = @import("root.zig").Chip8Emulator;
const StepEvent = Chip8Emulator.StepEvent;
const rl = @import("raylib");

pub const Debugger = struct {
    emulator: *Chip8Emulator,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    is_continuing: bool = false,
    breakpoints: std.AutoHashMap(u12, void) = undefined,

    pub fn init(emulator: *Chip8Emulator, stdin: *std.Io.Reader, stdout: *std.Io.Writer) @This() {
        return .{ .emulator = emulator, .stdin = stdin, .stdout = stdout };
    }

    pub fn run(self: *@This()) Error!void {
        var stack_allocator_buffer: [1024]u8 = undefined;
        var stack_allocator = std.heap.FixedBufferAllocator.init(&stack_allocator_buffer);
        const allocator = stack_allocator.allocator();
        self.breakpoints = .init(allocator);

        try self.emulator.setup();

        debugger: while (true) {
            self.emulator.updateInput();
            self.emulator.draw();

            if (self.is_continuing) {
                if (rl.isKeyPressed(.f5)) {
                    self.is_continuing = false;
                    continue;
                }

                for (0..Chip8Emulator.instructions_per_frame) |_| {
                    if (self.hasBreakpointAt(self.emulator.currentInstructionAddr())) {
                        self.is_continuing = false;
                        continue :debugger;
                    }

                    switch (try self.emulator.step()) {
                        .cont => continue,
                        .done => break :debugger,
                    }
                }

                continue;
            }

            try self.printContext();

            const line = try self.stdin.takeDelimiterExclusive('\n');
            self.stdin.toss(1);
            const command = self.parseCommand(line) catch |err| switch (err) {
                Error.UnknownCommand, Error.InvalidCommand => continue,
                else => return err,
            };
            switch (try self.executeCommand(command)) {
                .cont => continue,
                .done => break,
            }
        }
    }

    fn parseCommand(self: *@This(), line: []const u8) Error!Command {
        var split = std.mem.tokenizeAny(u8, line, " \r\t\n");
        const command = split.next() orelse return Error.InvalidCommand;

        if (std.mem.eql(u8, command, "step")) {
            return .step;
        } else if (std.mem.eql(u8, command, "quit")) {
            return .quit;
        } else if (std.mem.eql(u8, command, "continue")) {
            return .cont;
        } else if (std.mem.eql(u8, command, "stack")) {
            return .stack;
        } else if (std.mem.eql(u8, command, "registers")) {
            return .registers;
        } else if (std.mem.eql(u8, command, "bp")) {
            const arg = split.next() orelse return Error.InvalidCommand;
            const addr = std.fmt.parseInt(u12, arg, 16) catch |err| {
                std.log.err("error parsing argument: {}", .{err});
                return Error.InvalidCommand;
            };
            if (try self.emulator.decodeInstruction(addr)) |instr| {
                const prefix = if (self.hasBreakpointAt(addr)) "   " else " B ";
                try self.stdout.print("Toggled breakpoint:\n{s}[{x:03}] {f}\n", .{ prefix, addr, instr });
            }
            return .{ .breakpoint = .{ .addr = addr } };
        }

        try self.stdout.print("Unknown command \"{s}\"\n", .{command});
        return Error.UnknownCommand;
    }

    fn executeCommand(self: *@This(), command: Command) Error!StepEvent {
        return switch (command) {
            .step => try self.emulator.step(),
            .quit => .done,
            .cont => {
                self.is_continuing = true;
                return .cont;
            },
            .stack => {
                try self.stdout.print("Stack:\n", .{});
                for (self.emulator.stack(), 0..) |stack_var, i| {
                    const addr: u12 = @truncate(Chip8Emulator.stack_start + i);
                    try self.stdout.print("${x:04} = {x:04}\n", .{ addr, stack_var });
                }
                return .cont;
            },
            .registers => {
                try self.stdout.print("Register:\n", .{});
                try self.stdout.print("PC = {x:04}\tI  = {x:04}\n", .{ self.emulator.pc, self.emulator.i });
                try self.stdout.print("DT = {x:04}\tST = {x:04}\n", .{ self.emulator.dt, self.emulator.st });
                for (self.emulator.V, 0..) |V, i| {
                    try self.stdout.print("V{x} = {x:02}\t", .{ i, V });
                    if (i % 4 == 3) {
                        try self.stdout.writeByte('\n');
                    }
                }
                try self.stdout.writeByte('\n');
                return .cont;
            },
            .breakpoint => |bp| {
                try self.toggleBreakpoint(bp.addr);
                return .cont;
            },
        };
    }

    const instruction_padding = 3;

    fn printContext(self: *@This()) Error!void {
        const start_instr = @max(self.emulator.pc -| (instruction_padding * 2), Chip8Emulator.program_start);
        const end_instr = @min(self.emulator.pc +| (instruction_padding * 2), self.emulator.memory.len);

        for (start_instr..end_instr) |i| {
            if ((i - start_instr) % 2 == 1) continue;
            var prefix: [3]u8 = .{' '} ** 3;
            if (i == self.emulator.pc +% 2) prefix[1] = '>';
            if (self.hasBreakpointAt(@truncate(i))) prefix[2] = 'B';
            const instr = self.emulator.decodeInstruction(@truncate(i)) catch |err| switch (err) {
                Chip8Emulator.Error.UnsupportedInstruction => {
                    const lo = self.emulator.memory[i];
                    const hi = self.emulator.memory[i + 1];
                    try self.stdout.print("{s}[{x}] {x} {x} <unsupported instruction>\n", .{ prefix, i, lo, hi });
                    continue;
                },
                else => return err,
            } orelse {
                const lo = self.emulator.memory[i];
                const hi = self.emulator.memory[i + 1];
                try self.stdout.print("{s}[{x}] {x} {x} <unsupported instruction>\n", .{ prefix, i, lo, hi });
                continue;
            };
            try self.stdout.print("{s}[{x}] {f}\n", .{ prefix, i, instr });
        }
    }

    fn hasBreakpointAt(self: @This(), addr: u12) bool {
        return self.breakpoints.contains(addr);
    }

    fn toggleBreakpoint(self: *@This(), addr: u12) Error!void {
        if (self.hasBreakpointAt(addr)) {
            self.removeBreakpoint(addr);
        } else {
            try self.setBreakpoint(addr);
        }
    }

    fn setBreakpoint(self: *@This(), addr: u12) Error!void {
        return self.breakpoints.put(addr, {});
    }

    fn removeBreakpoint(self: *@This(), addr: u12) void {
        _ = self.breakpoints.remove(addr);
    }

    pub const Error = error{
        InvalidCommand,
        UnknownCommand,
    } || std.Io.Reader.DelimiterError || std.Io.Writer.Error || Chip8Emulator.Error || std.mem.Allocator.Error;
};

pub const Command = union(enum) {
    step: Step,
    cont: Continue,
    stack: Stack,
    registers: Registers,
    breakpoint: Breakpoint,
    quit: Quit,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |s| try writer.print("{f}", .{s}),
        }
    }

    pub const Step = struct {
        pub fn format(
            _: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("step", .{});
        }
    };

    pub const Quit = struct {
        pub fn format(
            _: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("quit", .{});
        }
    };

    pub const Continue = struct {
        pub fn format(
            _: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("continue", .{});
        }
    };

    pub const Stack = struct {
        pub fn format(
            _: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("stack", .{});
        }
    };

    pub const Registers = struct {
        pub fn format(
            _: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("registers", .{});
        }
    };

    pub const Breakpoint = struct {
        addr: u12,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("bp {x:03}", .{self.addr});
        }
    };
};
