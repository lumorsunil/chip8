const std = @import("std");
const Io = std.Io;

const chip8 = @import("chip8");

const Options = struct {
    file: ?[]const u8 = null,
    debug: bool = false,
    emulator: chip8.EmulatorOptions = .{},
};

fn printUsage() void {}

const Stdio = struct {
    stdin_buffer: [1024]u8 = undefined,
    stdin_file_reader: std.Io.File.Reader = undefined,
    stdout_file_writer: std.Io.File.Writer = undefined,
    stderr_file_writer: std.Io.File.Writer = undefined,

    pub fn init() @This() {
        return .{};
    }

    pub fn setup(self: *@This(), io: std.Io) void {
        self.stdin_file_reader = std.Io.File.stdin().reader(io, &self.stdin_buffer);
        self.stdout_file_writer = std.Io.File.stdout().writer(io, &.{});
        self.stderr_file_writer = std.Io.File.stderr().writer(io, &.{});
    }

    pub fn stdin(self: *@This()) *std.Io.Reader {
        return &self.stdin_file_reader.interface;
    }

    pub fn stdout(self: *@This()) *std.Io.Writer {
        return &self.stdout_file_writer.interface;
    }

    pub fn stderr(self: *@This()) *std.Io.Writer {
        return &self.stderr_file_writer.interface;
    }
};

pub fn main(init: std.process.Init) !void {
    var stdio = Stdio.init();
    stdio.setup(init.io);
    const stdin = stdio.stdin();
    const stdout = stdio.stdout();

    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();

    var options = Options{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) {
            options.debug = true;
        } else if (std.mem.eql(u8, arg, "--shift")) {
            options.emulator.shift_behavior = .set_vx_to_vy;
        } else if (std.mem.eql(u8, arg, "--jump-with-offset")) {
            options.emulator.jump_with_offset_behavior = .vx_plus_addr;
        } else {
            options.file = arg;
        }
    }

    const file_path = options.file orelse {
        std.log.debug("Usage: <options> <program>", .{});
        std.log.debug("Options:", .{});
        std.log.debug("\t--debug\tRun program with debugger.", .{});
        std.log.debug("\t--shift\tSets behavior of shift operation to set vx to vy.", .{});
        std.log.debug("\t--jump-with-offset\tSets behavior of jump with offset operation to add vx instead of v0.", .{});
        std.process.exit(1);
    };

    var file: []const u8 = std.Io.Dir.cwd().readFileAlloc(init.io, file_path, init.arena.allocator(), .unlimited) catch |err| {
        std.log.err("Could not open file \"{s}\": {}", .{ file_path, err });
        std.process.exit(1);
    };

    if (std.mem.eql(u8, std.fs.path.extension(file_path), ".ch8asm")) {
        var assembler = chip8.Chip8Assembler.init();
        file = assembler.compile(file, init.arena.allocator()) catch |err| {
            std.log.err("Assembler Error: {}", .{err});
            std.process.exit(1);
        };
    }

    var emulator = chip8.Chip8Emulator.init(init.io, options.emulator);
    emulator.loadProgram(file);

    if (options.debug) {
        var debugger = chip8.Debugger.init(&emulator, stdin, stdout);
        debugger.run() catch |err| {
            std.log.err("Debugger Error: {}", .{err});
            std.process.exit(1);
        };
    } else {
        emulator.run() catch |err| {
            std.log.err("Chip8EmulatorError: {}", .{err});
            std.process.exit(1);
        };
    }
}
