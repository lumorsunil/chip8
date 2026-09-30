const std = @import("std");
const Io = std.Io;
const rl = @import("raylib");

pub const Chip8Assembler = @import("assembler.zig").Chip8Assembler;
pub const Debugger = @import("debugger.zig").Debugger;

pub const EmulatorOptions = struct {
    shift_behavior: ShiftBehavior = .dont_set_vx_to_vy,
    jump_with_offset_behavior: JumpWithOffsetBehavior = .v0_plus_addr,

    pub const ShiftBehavior = enum { set_vx_to_vy, dont_set_vx_to_vy };
    pub const JumpWithOffsetBehavior = enum { v0_plus_addr, vx_plus_addr };
};

// Font addr: 050–09F
// Each font character should be 4 pixels wide by 5 pixels tall.

const default_font: []const u8 = &.{
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
};

// Keyboard
// 1    2       3       4
// Q    W       E       R
// A    S       D       F
// Z    X       C       V

// Chip8 Keypad
// 1    2       3       C
// 4    5       6       D
// 7    8       9       E
// A    0       B       F

const audio_sample_rate = 44100.0;
const audio_sample_size = 32;
const audio_buffer_size = 4096;
const audio_freq = 440.0; // 440 - 500
const audio_amp = 0.1;
const audio_phase_increment = audio_freq / audio_sample_rate;
const audio_square_width = 0.5;

// #define SAMPLE_RATE 44100
// #define BUFFER_SIZE 512
// #define FREQUENCY   440.0f  // Standard A4 pitch
// #define AMPLITUDE   0.2f    // Keep it low so it doesn't hurt your ears
//
// int main(void) {
//     // 1. Initialize Window and Audio Device
//     InitWindow(400, 200, "CHIP-8 Raylib Audio Example");
//     InitAudioDevice();
//     SetTargetFPS(60); // 60 FPS matches the CHIP-8 timer decrement rate
//
//     // 2. Set up Audio Stream (44.1kHz, 16-bit Mono)
//     SetAudioStreamBufferSizeDefault(BUFFER_SIZE);
//     AudioStream stream = LoadAudioStream(SAMPLE_RATE, 16, 1);
//     PlayAudioStream(stream);
//
//     // Mock CHIP-8 Sound Timer (ST)
//     uint8_t sound_timer = 0;
//
//     // Wave generation variables
//     float phase = 0.0f;
//     float phase_increment = FREQUENCY / SAMPLE_RATE;
//     int16_t write_buffer[BUFFER_SIZE];
//
//     while (!WindowShouldClose()) {
//         // --- 3. Mock CHIP-8 Input Logic ---
//         if (IsKeyPressed(KEY_SPACE)) {
//             sound_timer = 20; // Play a beep for ~0.33 seconds (20 / 60 frames)
//         }
//
//         // --- 4. Decrement CHIP-8 Timer ---
//         if (sound_timer > 0) {
//             sound_timer--;
//         }
//
//         // --- 5. Generate and Stream Audio ---
//         if (IsAudioStreamProcessed(stream)) {
//             for (int i = 0; i < BUFFER_SIZE; i++) {
//                 if (sound_timer > 0) {
//                     // Generate Square Wave: If phase < 0.5, output positive amplitude, else negative
//                     write_buffer[i] = (phase < 0.5f) ? (int16_t)(AMPLITUDE * 32767) : (int16_t)(-AMPLITUDE * 32767);
//
//                     // Advance phase and wrap around 1.0
//                     phase += phase_increment;
//                     if (phase >= 1.0f) phase -= 1.0f;
//                 } else {
//                     // Silence when sound timer hits 0
//                     write_buffer[i] = 0;
//                     phase = 0.0f; // Reset phase to prevent pops when sound restarts
//                 }
//             }
//
//             // Push the generated samples to raylib's audio buffer
//             UpdateAudioStream(stream, write_buffer, BUFFER_SIZE);
//         }
//
//         // --- 6. Render ---
//         BeginDrawing();
//         ClearBackground(RAYWHITE);
//         DrawText("Press SPACE to trigger CHIP-8 Beep", 40, 70, 18, DARKGRAY);
//         DrawText(TextFormat("Sound Timer: %d", sound_timer), 40, 110, 20, sound_timer > 0 ? RED : MAROON);
//         EndDrawing();
//     }
//
//     // 7. Cleanup
//     UnloadAudioStream(stream);
//     CloseAudioDevice();
//     CloseWindow();
//
//     return 0;

pub const Chip8Emulator = struct {
    options: EmulatorOptions,
    /// 0x000–0x1FF (First 512 bytes): Reserved exclusively for the CHIP-8 interpreter software itself.
    /// 0x200–0xE9F: The main program memory where user games and application code were loaded.
    /// 0xEA0–0xEFF (96 bytes): Reserved for the interpreter's call stack, internal system variables, and scratchpads.
    /// 0xF00–0xFFF (Highest 256 bytes): Reserved for the graphics display refresh (the framebuffer).
    memory: [1024 * 4]u8 align(@alignOf(u16)) = @splat(0x00),
    /// A program counter, often called just “PC”, which points at the current instruction in memory
    pc: u16 = 0,
    /// One 16-bit index register called “I” which is used to point at locations in memory
    i: u16 = 0,
    // A stack for 16-bit addresses, which is used to call subroutines/functions and return from them
    /// An 8-bit delay timer which is decremented at a rate of 60 Hz (60 times per second) until it reaches 0
    dt: u8 = 0,
    /// An 8-bit sound timer which functions like the delay timer, but which also gives off a beeping sound as long as it’s not 0
    st: u8 = 0,
    /// 16 8-bit (one byte) general-purpose variable registers numbered 0 through F hexadecimal, ie. 0 through 15 in decimal, called V0 through VF
    /// VF is also used as a flag register; many instructions will set it to either 1 or 0 based on some rule, for example using it as a carry flag
    V: [0x10]u8 = @splat(0),
    instruction_counter: usize = 0,
    keypad: [0x10]bool = @splat(false),
    random_io: std.Random.IoSource,
    audio_stream: rl.AudioStream = undefined,
    audio_phase: f32 = 0,

    pub fn init(io: std.Io, options: EmulatorOptions) @This() {
        return .{ .options = options, .random_io = .{ .io = io } };
    }

    pub fn loadProgram(self: *@This(), program_: []const u8) void {
        @memcpy(self.memory[program_start .. program_start + program_.len], program_);
    }

    pub const scale = 10;
    pub const display_color = rl.Color.green;
    /// Display: 64 x 32 pixels (or 128 x 64 for SUPER-CHIP) monochrome, ie. black or white
    pub const display_size = @Vector(2, i32){ 64, 32 };
    const display_size_u16: @Vector(2, u7) = @intCast(display_size);
    pub const scaled_display_size = display_size * @as(@Vector(2, i32), @splat(scale));
    /// First two bytes are reserved for the stack pointer
    pub const font_start = 0x000;
    pub const program_start = 0x200;
    pub const stack_start = 0xEA0 + 2;
    pub const display_start = 0xF00;
    pub const instructions_per_frame = 12;
    const camera = rl.Camera2D{
        .rotation = 0,
        .offset = .zero(),
        .target = .zero(),
        .zoom = scale,
    };

    fn initializeMemory(self: *@This()) void {
        @memcpy(self.memory[font_start..default_font.len], default_font);
        self.pc = program_start -% 2;
        self.stackPointer().* = stack_start;
    }

    fn initializeAudio(self: *@This()) Error!void {
        rl.setAudioStreamBufferSizeDefault(audio_buffer_size);
        self.audio_stream = try rl.loadAudioStream(audio_sample_rate, audio_sample_size, 1);
        rl.playAudioStream(self.audio_stream);
    }

    pub fn setup(self: *@This()) Error!void {
        self.initializeMemory();
        rl.initWindow(scaled_display_size[0], scaled_display_size[1], "Chip8 Emulator");
        rl.initAudioDevice();
        rl.setTargetFPS(60);
        try self.initializeAudio();
    }

    pub fn deinit(_: *@This()) void {
        rl.closeAudioDevice();
        rl.closeWindow();
    }

    pub const StepEvent = enum {
        cont,
        done,
    };

    pub fn step(self: *@This()) Error!StepEvent {
        if (rl.windowShouldClose()) return .done;
        self.pc +%= 2;
        const instr = try self.currentInstruction();
        try self.executeInstruction(instr);
        self.instruction_counter += 1;
        if (self.instruction_counter % instructions_per_frame == 0) {
            self.dt -|= 1;
            self.st -|= 1;
            self.instruction_counter = 0;
        }
        return .cont;
    }

    pub fn draw(self: *@This()) void {
        rl.beginDrawing();

        rl.clearBackground(.black);

        camera.begin();
        for (self.display(), 0..) |pixels, i| {
            const j = i * 8;
            const y: i32 = @intCast(@divFloor(j, display_size[0]));

            for (0..8) |k| {
                const x: i32 = @intCast((j + k) % display_size[0]);
                if (pixels & (@as(u8, 1) << @intCast(k)) != 0) rl.drawRectangle(x, y, 1, 1, display_color);
            }
        }
        camera.end();

        rl.endDrawing();
    }

    pub fn updateAudio(self: *@This()) void {
        var write_buffer: [audio_buffer_size]f32 = undefined;

        if (rl.isAudioStreamProcessed(self.audio_stream)) {
            for (0..audio_buffer_size) |i| {
                if (self.st > 0) {
                    const dir: f32 = if (self.audio_phase < audio_square_width) 1 else -1;
                    const amp = dir * audio_amp;
                    write_buffer[i] = amp;
                    self.audio_phase += audio_phase_increment;
                    if (self.audio_phase >= 1) {
                        self.audio_phase -= 1;
                    }
                } else {
                    write_buffer[i] = 0;
                    self.audio_phase = 0;
                }
            }

            rl.updateAudioStream(self.audio_stream, &write_buffer, audio_buffer_size);
        }

        //         if (IsAudioStreamProcessed(stream)) {
        //             for (int i = 0; i < BUFFER_SIZE; i++) {
        //                 if (sound_timer > 0) {
        //                     // Generate Square Wave: If phase < 0.5, output positive amplitude, else negative
        //                     write_buffer[i] = (phase < 0.5f) ? (int16_t)(AMPLITUDE * 32767) : (int16_t)(-AMPLITUDE * 32767);
        //
        //                     // Advance phase and wrap around 1.0
        //                     phase += phase_increment;
        //                     if (phase >= 1.0f) phase -= 1.0f;
        //                 } else {
        //                     // Silence when sound timer hits 0
        //                     write_buffer[i] = 0;
        //                     phase = 0.0f; // Reset phase to prevent pops when sound restarts
        //                 }
        //             }
        //
        //             // Push the generated samples to raylib's audio buffer
        //             UpdateAudioStream(stream, write_buffer, BUFFER_SIZE);
        //         }
    }

    pub fn run(self: *@This()) Error!void {
        try self.setup();
        defer self.deinit();

        while (!rl.windowShouldClose()) {
            self.updateInput();
            self.updateAudio();
            for (0..instructions_per_frame) |_| switch (try self.step()) {
                .cont => continue,
                .done => break,
            };
            self.draw();
        }
    }

    const Key = enum(u4) {
        one = 0x1,
        two = 0x2,
        three = 0x3,
        four = 0xc,
        q = 0x4,
        w = 0x5,
        e = 0x6,
        r = 0xd,
        a = 0x7,
        s = 0x8,
        d = 0x9,
        f = 0xe,
        z = 0xa,
        x = 0x0,
        c = 0xb,
        v = 0xf,
    };

    pub fn updateInput(self: *@This()) void {
        inline for (comptime std.meta.tags(Key)) |tag| {
            const rl_key = comptime std.meta.stringToEnum(rl.KeyboardKey, @tagName(tag)) orelse {
                @compileError("invalid raylib key mapping: " ++ @tagName(tag));
            };

            self.keypad[@intFromEnum(tag)] = rl.isKeyDown(rl_key);
        }
    }

    pub fn getKeyPress(_: *@This()) ?u4 {
        inline for (comptime std.meta.tags(Key)) |tag| {
            const rl_key = comptime std.meta.stringToEnum(rl.KeyboardKey, @tagName(tag)) orelse {
                @compileError("invalid raylib key mapping: " ++ @tagName(tag));
            };

            if (rl.isKeyPressed(rl_key)) {
                return @intFromEnum(tag);
            }
        }

        return null;
    }

    /// 0x000–0x1FF (First 512 bytes): Reserved exclusively for the CHIP-8 interpreter software itself.
    fn reserved(self: *@This()) []u8 {
        return self.memory[0x000..0x200];
    }

    /// 0x200–0xE9F: The main program memory where user games and application code were loaded.
    fn program(self: *@This()) []u8 {
        return self.memory[0x200..0xEA0];
    }

    /// 0xEA0–0xEFF (96 bytes): Reserved for the interpreter's call stack, internal system variables, and scratchpads.
    fn stackFull(self: *@This()) []u16 {
        return @ptrCast(@alignCast(self.memory[0xEA0..0xF00]));
    }

    pub fn stack(self: *@This()) []u16 {
        return @ptrCast(@alignCast(self.memory[0xEA2..self.stackPointer().*]));
    }

    fn stackPointer(self: *@This()) *u16 {
        return std.mem.bytesAsValue(u16, self.stackFull()[0..2]);
    }

    /// 0xF00–0xFFF (Highest 256 bytes): Reserved for the graphics display refresh (the framebuffer).
    fn display(self: *@This()) []u8 {
        return self.memory[0xF00..0x1000];
    }

    //    Stack
    //CHIP-8 has a stack (a common “last in, first out” data structure where you can either “push” data to it or “pop” the last piece of data you pushed). You can represent it however you’d like; a stack if your programming language has it, or an array. CHIP-8 uses it to call and return from subroutines (“functions”) and nothing else, so you will be saving addresses there; 16-bit (or really only 12-bit) numbers.
    //
    //Early interpreters reserved some memory for the stack, and some programs would use that knowledge to operate the stack directly and save stuff there, but you don’t need to do that. You can just use a variable outside the emulated memory.
    //
    //These original interpreters had limited space on the stack; usually at least 16 two-byte entries. You can limit the stack likewise, or just keep it unlimited. CHIP-8 programs usually don’t nest subroutine calls too much since the stack was so small originally, so it doesn’t really matter (unless you encounter a program with a bug that has an infinite call loop and causes a “stack overflow”).

    fn stackPush(self: *@This(), data: u16) Error!void {
        const sp = self.stackPointer();
        if (sp.* >= self.memory.len) return Error.StackOverflow;
        if (sp.* < stack_start) return Error.StackOverflow;
        const dest: *u16 = @ptrCast(@alignCast(self.memory[sp.* .. sp.* + 2]));
        dest.* = data;
        sp.* +%= 2;
    }

    fn stackPop(self: *@This()) Error!u16 {
        const sp = self.stackPointer();
        sp.* -%= 2;
        if (sp.* < stack_start) return Error.StackOverflow;
        return std.mem.bytesToValue(u16, self.memory[sp.* .. sp.* + 2]);
    }

    fn getSprite(self: *@This(), addr: u16, width: u8, height: u8) []u8 {
        const size = width * height;
        return self.memory[addr .. addr + size];
    }

    fn drawSprite(self: *@This(), addr: u16, r_offset_x: u4, r_offset_y: u4, height: u4) void {
        self.V[0xF] = 0;
        for (0..height) |y| {
            const sprite = addr + y;
            const dx: u12 = self.V[r_offset_x] % display_size_u16[0];
            const dy: u12 = @as(u12, @intCast(y)) + (self.V[r_offset_y] % display_size_u16[1]);
            const d_byte_idx = @divFloor(dx + dy * display_size_u16[0], 8);
            const display_ = display_start + d_byte_idx;
            if (display_ >= self.memory.len) return;
            const bit_offset: u3 = @truncate(dx % 8);
            var pixels = @bitReverse(self.memory[sprite]);
            if (self.memory[display_] & (pixels << bit_offset) > 0) self.V[0xF] = 1;
            self.memory[display_] ^= pixels << bit_offset;
            if (bit_offset != 0) {
                const right_shift: u3 = @truncate(@as(u8, 8) - bit_offset);
                const next_byte = @as(usize, display_) + 1;
                if (next_byte >= self.memory.len) return;
                pixels = @bitReverse(self.memory[sprite]);
                if (self.memory[next_byte] & (pixels >> right_shift) > 0) self.V[0xF] = 1;
                self.memory[next_byte] ^= pixels >> right_shift;
            }
        }
    }

    pub fn nibbleSwap(x: u16) u16 {
        return ((x & 0xF0F0) >> 4) | ((x & 0x0F0F) << 4);
    }

    pub fn swapNibbles2(x: u16) u16 {
        return ((x & 0xF000) >> 8) | ((x & 0x00F0) << 8) | (x & 0x0F0F);
    }

    pub fn getNibble(n: u2, x: u16) u4 {
        return @truncate(x >> @as(u4, n) * 4);
    }

    const NibbleFormatter = struct {
        target: u16,

        pub fn init(target: u16) @This() {
            return .{ .target = target };
        }

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            for (0..4) |n| {
                const nibble = getNibble(@truncate(n), self.target);
                try writer.print("{x}", .{nibble});
            }
        }
    };

    fn currentInstruction(self: *@This()) Error!Instruction {
        return self.decodeInstruction(@truncate(self.pc));
    }

    const constant_instrs: []const std.meta.FieldEnum(Instruction) = &.{ .display_clear, .ret };
    const opcode_instrs: []const std.meta.FieldEnum(Instruction) = &.{ .set_v_to_v, .add_v_to_v, .or_vv, .and_vv, .xor_vv, .sub_vx_vy, .sub_vy_vx, .shift_left, .shift_right, .jump_if_key_down, .jump_if_key_up, .add_v_to_i, .set_i_to_font, .set_v_to_dt, .set_dt_to_v, .set_st_to_v, .set_v_to_key, .bcd, .set_v_to_mem, .set_mem_to_v };

    pub fn decodeInstruction(self: *@This(), addr: u12) Error!Instruction {
        @setEvalBranchQuota(10000);

        const instr: RawInstruction = @bitCast(swapNibbles2(nibbleSwap(std.mem.readInt(u16, @ptrCast(self.memory[addr .. addr + 2]), .little))));

        inline for (std.meta.fields(Instruction)) |field| {
            const InstrType = field.type;
            const instr_nibble: u4 = std.meta.fieldInfo(InstrType, .instr).defaultValue().?;

            if (instr_nibble == instr.instr) {
                inline for (constant_instrs) |constant_instr| {
                    if (comptime std.mem.eql(u8, field.name, @tagName(constant_instr))) {
                        const instr_as_u16: u16 = @bitCast(instr);
                        const instr_matchee: u16 = @bitCast(field.type{});

                        if (instr_as_u16 == instr_matchee) {
                            return @unionInit(Instruction, field.name, @bitCast(instr));
                        } else {
                            break;
                        }
                    }
                } else inline for (opcode_instrs) |eight_instr| {
                    if (comptime std.mem.eql(u8, field.name, @tagName(eight_instr))) {
                        const instr_as_target: field.type = @bitCast(instr);
                        const opcode = std.meta.fieldInfo(InstrType, .opcode).defaultValue().?;

                        if (instr_as_target.opcode == opcode) {
                            return @unionInit(Instruction, field.name, @bitCast(instr));
                        } else {
                            break;
                        }
                    }
                } else {
                    return @unionInit(Instruction, field.name, @bitCast(instr));
                }
            }
        }

        std.log.err("Unsupported instruction: {x}", .{instr.instr});
        const instr_as_bytes = std.mem.asBytes(&instr);
        std.log.err("at ({x}): {x} {x}", .{ addr, self.memory[addr], self.memory[addr + 1] });
        std.log.err("at ({x}): {x} {x}", .{ addr, instr_as_bytes[0], instr_as_bytes[1] });
        return Error.UnsupportedInstruction;
    }

    fn executeInstruction(self: *@This(), instruction: Instruction) Error!void {
        // std.log.debug("instruction: {f}", .{instruction});
        // const instr_as_bytes = std.mem.asBytes(&instruction);
        // std.log.err("at ({x}): {x} {x}", .{ self.pc, self.memory[self.pc], self.memory[self.pc + 1] });
        // std.log.err("at ({x}): {x} {x}", .{ self.pc, instr_as_bytes[0], instr_as_bytes[1] });
        switch (instruction) {
            .display_clear => @memset(self.display(), 0),
            .jump => |jump| self.pc = jump.addr -% 2,
            .jump_with_offset => |jump| switch (self.options.jump_with_offset_behavior) {
                .v0_plus_addr => self.pc = jump.addr -% 2 + self.V[0],
                .vx_plus_addr => self.pc = jump.addr -% 2 + self.V[jump.vx()],
            },
            .jump_if_v_eq_data => |jif| if (self.V[jif.reg] == jif.data) {
                self.pc +%= 2;
            },
            .jump_if_v_neq_data => |jif| if (self.V[jif.reg] != jif.data) {
                self.pc +%= 2;
            },
            .jump_if_v_eq_v => |jif| if (self.V[jif.lhs] == self.V[jif.rhs]) {
                self.pc +%= 2;
            },
            .jump_if_v_neq_v => |jif| if (self.V[jif.lhs] != self.V[jif.rhs]) {
                self.pc +%= 2;
            },
            .jump_if_key_down => |jif| if (self.keypad[@as(u4, @truncate(self.V[jif.reg]))]) {
                self.pc +%= 2;
            },
            .jump_if_key_up => |jif| if (!self.keypad[@as(u4, @truncate(self.V[jif.reg]))]) {
                self.pc +%= 2;
            },
            .call => |call| {
                try self.stackPush(self.pc);
                self.pc = call.addr;
            },
            .ret => self.pc = try self.stackPop(),
            .set_v_to_data => |set| self.V[set.reg] = set.data,
            .set_v_to_v => |set| self.V[set.lhs] = self.V[set.rhs],
            .set_v_to_dt => |set| self.V[set.reg] = self.dt,
            .set_dt_to_v => |set| self.dt = self.V[set.reg],
            .set_st_to_v => |set| self.st = self.V[set.reg],
            .set_v_to_key => |set| if (self.getKeyPress()) |key| {
                self.V[set.reg] = key;
            } else {
                self.pc -%= 2;
            },
            .set_v_to_mem => |set| {
                const end: usize = @intCast(set.reg);
                for (0..end + 1) |i| self.V[i] = self.memory[self.i + i];
            },
            .set_mem_to_v => |set| {
                const end: usize = @intCast(set.reg);
                for (0..end + 1) |i| self.memory[self.i + i] = self.V[i];
            },
            .add_data_to_v => |add| self.V[add.reg] +%= add.data,
            .add_v_to_i => |add| {
                self.i, const flag = @addWithOverflow(self.i, self.V[add.reg]);
                self.V[0xF] = flag;
            },
            .add_v_to_v => |add| {
                self.V[add.lhs], const flag = @addWithOverflow(self.V[add.lhs], self.V[add.rhs]);
                self.V[0xF] = flag;
            },
            .or_vv => |or_vv| self.V[or_vv.lhs] |= self.V[or_vv.rhs],
            .and_vv => |and_vv| self.V[and_vv.lhs] &= self.V[and_vv.rhs],
            .xor_vv => |xor_vv| self.V[xor_vv.lhs] ^= self.V[xor_vv.rhs],
            .sub_vx_vy => |sub_vx_vy| {
                self.V[sub_vx_vy.lhs], const flag = @subWithOverflow(self.V[sub_vx_vy.lhs], self.V[sub_vx_vy.rhs]);
                self.V[0xF] = ~flag;
            },
            .sub_vy_vx => |sub_vy_vx| {
                self.V[sub_vy_vx.lhs], const flag = @subWithOverflow(self.V[sub_vy_vx.rhs], self.V[sub_vy_vx.lhs]);
                self.V[0xF] = ~flag;
            },
            .shift_left => |shift_l| {
                const v = switch (self.options.shift_behavior) {
                    .dont_set_vx_to_vy => self.V[shift_l.lhs],
                    .set_vx_to_vy => self.V[shift_l.rhs],
                };
                self.V[shift_l.lhs], const flag = @shlWithOverflow(v, 1);
                self.V[0xF] = flag;
            },
            .shift_right => |shift_r| {
                const v = switch (self.options.shift_behavior) {
                    .dont_set_vx_to_vy => self.V[shift_r.lhs],
                    .set_vx_to_vy => self.V[shift_r.rhs],
                };
                self.V[0xF] = 1 & shift_r.lhs;
                self.V[shift_r.lhs] = v >> 1;
            },
            .set_i => |set_i| self.i = set_i.data,
            .set_i_to_font => |set_i_to_font| self.i = font_start + self.V[set_i_to_font.reg] * 5,
            .random => |random| self.V[random.reg] = self.random_io.interface().int(u8) & random.data,
            .display_draw => |draw_| self.drawSprite(self.i, draw_.x, draw_.y, draw_.height),
            .bcd => |bcd| {
                var v = self.V[bcd.reg];
                const n = 2;
                const a = self.i;
                for (0..n + 1) |i| {
                    self.memory[a + (n - i)] = v % 10;
                    v = @divFloor(v, 10);
                }
            },
        }
    }

    pub const Error = error{ StackOverflow, UnsupportedInstruction } || rl.RaylibError;
};

// 00E0 (clear screen)
// 1NNN (jump)
// 6XNN (set register VX)
// 7XNN (add value to register VX)
// ANNN (set index register I)
// DXYN (display/draw)
//
//
// pre-flip:
// INNN (
//   hi_12: u4,
//   instr: u4,
//   lo_12: u4,
//   mid_12: u4,
// )
// post-flip:
// INNN (
//   instr: u4,
//   hi_12: u4,
//   mid_12: u4,
//   lo_12: u4,
// )
// post-swap:
// INNN (
//   instr: u4,
//   lo_12: u4,
//   mid_12: u4,
//   hi_12: u4,
// )
//
// pre-flip:
// IXNN (
//   arg: u4,
//   instr: u4,
//   lo_8: u4,
//   hi_8: u4,
// )
// post-flip:
// IXNN (
//   instr: u4,
//   arg: u4,
//   hi_8: u4,
//   lo_8: u4,
// )
// post-swap:
// IXNN (
//   instr: u4,
//   lo_8: u4,
//   hi_8: u4,
//   arg: u4,
// )
//
// pre-flip:
// IXYN (
//   arg0: u4,
//   instr: u4,
//   data: u4,
//   arg1: u4,
// )
// post-flip:
// IXYN (
//   instr: u4,
//   arg0: u4,
//   arg1: u4,
//   data: u4,
// )
// post-swap:
// IXYN (
//   instr: u4,
//   data: u4,
//   arg1: u4,
//   arg0: u4,
// )

const RawInstruction = packed struct(u16) {
    instr: u4,
    tail: u12,
};

pub const Instruction = union(enum) {
    display_clear: DisplayClear,
    display_draw: DisplayDraw,
    jump: Jump,
    jump_with_offset: JumpWithOffset,
    jump_if_v_eq_data: JumpIfVEqData,
    jump_if_v_neq_data: JumpIfVNotEqData,
    jump_if_v_eq_v: JumpIfVEqV,
    jump_if_v_neq_v: JumpIfVNotEqV,
    jump_if_key_down: JumpIfKeyDown,
    jump_if_key_up: JumpIfKeyUp,
    call: Call,
    ret: Return,
    set_v_to_data: SetVToData,
    set_v_to_v: SetVToV,
    set_v_to_dt: SetVToDT,
    set_dt_to_v: SetDTToV,
    set_st_to_v: SetSTToV,
    set_v_to_key: SetVToKey,
    set_v_to_mem: SetVToMemory,
    set_mem_to_v: SetMemoryToV,
    add_data_to_v: AddDataToV,
    add_v_to_i: AddVToI,
    add_v_to_v: AddVToV,
    set_i: SetI,
    set_i_to_font: SetIToFont,
    or_vv: Or,
    and_vv: And,
    xor_vv: Xor,
    sub_vx_vy: SubVXVY,
    sub_vy_vx: SubVYVX,
    shift_left: ShiftLeft,
    shift_right: ShiftRight,
    random: Random,
    bcd: BinaryCodedDecimal,

    // FX07 sets VX to the current value of the delay timer
    // FX15 sets the delay timer to the value in VX
    // FX18 sets the sound timer to the value in VX

    pub fn toInt(self: @This()) u16 {
        return switch (self) {
            inline else => |s| @bitCast(s),
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |s| try writer.print("{t}: {f}", .{ self, s }),
        }
    }

    pub const DisplayClear = packed struct(u16) {
        instr: u4 = 0x0,
        _: u12 = 0x0E0,

        pub fn format(
            _: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("display_clear", .{});
        }
    };

    pub const Jump = packed struct(u16) {
        instr: u4 = 0x1,
        addr: u12,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jump addr:{x:04}", .{self.addr});
        }
    };

    pub const JumpWithOffset = packed struct(u16) {
        instr: u4 = 0xB,
        addr: u12,

        pub fn vx(self: @This()) u4 {
            return @as(JumpOffsetWithV, @bitCast(self)).reg;
        }

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            const with_v: JumpOffsetWithV = @bitCast(self);
            try writer.print("jump addr:[{x:04} + V(0/{x}?)]", .{ self.addr, with_v.reg });
        }

        pub const JumpOffsetWithV = packed struct(u16) {
            instr: u4 = 0x1,
            _: u8,
            reg: u4,
        };
    };

    pub const JumpIfVEqData = packed struct(u16) {
        instr: u4 = 0x3,
        data: u8,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jif V{x} == {x:02}", .{ self.reg, self.data });
        }
    };

    pub const JumpIfVNotEqData = packed struct(u16) {
        instr: u4 = 0x4,
        data: u8,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jif V{x} != {x:02}", .{ self.reg, self.data });
        }
    };

    pub const JumpIfVEqV = packed struct(u16) {
        instr: u4 = 0x5,
        _: u4 = 0x0,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jif V{x} == V{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const JumpIfVNotEqV = packed struct(u16) {
        instr: u4 = 0x9,
        _: u4 = 0x0,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jif V{x} != V{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const JumpIfKeyDown = packed struct(u16) {
        instr: u4 = 0xE,
        opcode: u8 = 0x9E,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jif K[V{x}]", .{self.reg});
        }
    };

    pub const JumpIfKeyUp = packed struct(u16) {
        instr: u4 = 0xE,
        opcode: u8 = 0xA1,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jif !K[V{x}]", .{self.reg});
        }
    };

    pub const Call = packed struct(u16) {
        instr: u4 = 0x2,
        addr: u12,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("call addr:{x}", .{self.addr});
        }
    };

    pub const Return = packed struct(u16) {
        instr: u4 = 0x0,
        _: u12 = 0x0EE,

        pub fn format(
            _: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("ret", .{});
        }
    };

    pub const SetVToData = packed struct(u16) {
        instr: u4 = 0x6,
        data: u8,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set_v_to_data reg:{x} data:{x:02}", .{ self.reg, self.data });
        }
    };

    pub const SetVToV = packed struct(u16) {
        instr: u4 = 0x8,
        opcode: u4 = 0x0,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set_v_to_v lhs:{x} rhs:{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const SetVToDT = packed struct(u16) {
        instr: u4 = 0xF,
        opcode: u8 = 0x07,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set_v_to_dt reg:{x}", .{self.reg});
        }
    };

    pub const SetDTToV = packed struct(u16) {
        instr: u4 = 0xF,
        opcode: u8 = 0x15,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set_dt_to_v reg:{x}", .{self.reg});
        }
    };

    pub const SetSTToV = packed struct(u16) {
        instr: u4 = 0xF,
        opcode: u8 = 0x18,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set_st_to_v reg:{x}", .{self.reg});
        }
    };

    pub const SetVToKey = packed struct(u16) {
        instr: u4 = 0xF,
        opcode: u8 = 0x0A,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set_v_to_key reg:{x}", .{self.reg});
        }
    };

    pub const SetVToMemory = packed struct(u16) {
        instr: u4 = 0xF,
        opcode: u8 = 0x65,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set_v_to_mem reg:{x}", .{self.reg});
        }
    };

    pub const SetMemoryToV = packed struct(u16) {
        instr: u4 = 0xF,
        opcode: u8 = 0x55,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set_mem_to_v reg:{x}", .{self.reg});
        }
    };

    pub const AddDataToV = packed struct(u16) {
        instr: u4 = 0x7,
        data: u8,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("add_data_to_v V:{x} data:{x:02}", .{ self.reg, self.data });
        }
    };

    pub const AddVToI = packed struct(u16) {
        instr: u4 = 0xF,
        opcode: u8 = 0x1E,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("add_v_to_i V:{x}", .{self.reg});
        }
    };

    pub const AddVToV = packed struct(u16) {
        instr: u4 = 0x8,
        opcode: u4 = 0x4,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("add_v_to_v lhs:{x} rhs:{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const Or = packed struct(u16) {
        instr: u4 = 0x8,
        opcode: u4 = 0x1,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("or lhs:{x} rhs:{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const And = packed struct(u16) {
        instr: u4 = 0x8,
        opcode: u4 = 0x2,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("and lhs:{x} rhs:{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const Xor = packed struct(u16) {
        instr: u4 = 0x8,
        opcode: u4 = 0x3,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("xor lhs:{x} rhs:{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const SubVXVY = packed struct(u16) {
        instr: u4 = 0x8,
        opcode: u4 = 0x5,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("sub_vx_vy lhs:{x} rhs:{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const SubVYVX = packed struct(u16) {
        instr: u4 = 0x8,
        opcode: u4 = 0x7,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("sub_vy_vx lhs:{x} rhs:{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const ShiftLeft = packed struct(u16) {
        instr: u4 = 0x8,
        opcode: u4 = 0xE,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("shift_left lhs:{x} rhs:{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const ShiftRight = packed struct(u16) {
        instr: u4 = 0x8,
        opcode: u4 = 0x6,
        rhs: u4,
        lhs: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("shift_right lhs:{x} rhs:{x}", .{ self.lhs, self.rhs });
        }
    };

    pub const SetI = packed struct(u16) {
        instr: u4 = 0xA,
        data: u12,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set_i data:{x}", .{self.data});
        }
    };

    pub const SetIToFont = packed struct(u16) {
        instr: u4 = 0xF,
        opcode: u8 = 0x29,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set_i fnt:V{x}", .{self.reg});
        }
    };

    pub const Random = packed struct(u16) {
        instr: u4 = 0xC,
        data: u8,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("rnd V:{x} data:{x:02}", .{ self.reg, self.data });
        }
    };

    pub const DisplayDraw = packed struct(u16) {
        instr: u4 = 0xD,
        height: u4,
        y: u4,
        x: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("draw x:{x} y:{x} height:{x}", .{ self.x, self.y, self.height });
        }
    };

    pub const BinaryCodedDecimal = packed struct(u16) {
        instr: u4 = 0xF,
        opcode: u8 = 0x33,
        reg: u4,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("bcd reg:{x}", .{self.reg});
        }
    };
};
