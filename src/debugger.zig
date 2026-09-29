const std = @import("std");
const Chip8Emulator = @import("root.zig").Chip8Emulator;
const StepEvent = Chip8Emulator.StepEvent;

pub const Debugger = struct {
    emulator: *Chip8Emulator,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    is_continuing: bool = false,

    pub fn init(emulator: *Chip8Emulator, stdin: *std.Io.Reader, stdout: *std.Io.Writer) @This() {
        return .{ .emulator = emulator, .stdin = stdin, .stdout = stdout };
    }

    pub fn run(self: *@This()) Error!void {
        try self.emulator.setup();

        debugger: while (true) {
            self.emulator.updateInput();
            self.emulator.draw();

            if (self.is_continuing) {
                for (0..Chip8Emulator.instructions_per_frame) |_| {
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
        };
    }

    const instruction_padding = 3;

    fn printContext(self: *@This()) Error!void {
        const start_instr = @max(self.emulator.pc -| instruction_padding * 2, Chip8Emulator.program_start);
        const end_instr = @min(self.emulator.pc +| instruction_padding * 2, Chip8Emulator.stack_start - 2);

        for (start_instr..end_instr) |i| {
            if (i % 2 == 1) continue;
            const prefix = if (i == self.emulator.pc) " > " else "   ";
            const instr = self.emulator.decodeInstruction(@truncate(i)) catch |err| switch (err) {
                Chip8Emulator.Error.UnsupportedInstruction => {
                    const lo = self.emulator.memory[i];
                    const hi = self.emulator.memory[i + 1];
                    try self.stdout.print("{s}[{x}] {x} {x} <unsupported instruction>\n", .{ prefix, i, lo, hi });
                    continue;
                },
                else => return err,
            };
            try self.stdout.print("{s}[{x}] {f}\n", .{ prefix, i, instr });
        }
    }

    pub const Error = error{
        InvalidCommand,
        UnknownCommand,
    } || std.Io.Reader.DelimiterError || std.Io.Writer.Error || Chip8Emulator.Error;
};

pub const Command = union(enum) {
    step: Step,
    cont: Continue,
    stack: Stack,
    registers: Registers,
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
};
