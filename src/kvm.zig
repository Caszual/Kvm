const std = @import("std");
const bytec = @import("kvm-bytecode.zig");

const Karel = struct {
    // home position on the map, (0, 0) is bottom-left
    home_x: u32,
    home_y: u32,

    // karels position on the map, (0, 0) is bottom-left
    pos_x: u32,
    pos_y: u32,

    // direction what kaler is facing, range 0 to 3 representing North, East, South and West
    dir: u2,

    // checks and simulates a step and returns it
    pub fn get_step(self: *const Karel, map_size: u32) ?struct { x: u32, y: u32 } {
        switch (self.dir) {
            0 => {
                if (self.pos_y + 1 == map_size) return null;
                return .{ .x = self.pos_x, .y = self.pos_y + 1 };
            },

            1 => {
                if (self.pos_x == 0) return null;
                return .{ .x = self.pos_x - 1, .y = self.pos_y };
            },

            2 => {
                if (self.pos_y == 0) return null;
                return .{ .x = self.pos_x, .y = self.pos_y - 1 };
            },

            3 => {
                if (self.pos_x + 1 == map_size) return null;
                return .{ .x = self.pos_x + 1, .y = self.pos_y };
            },
        }
    }
};

const City = struct {
    pub const max_flags = 8; // max flags on a single square
    pub const map_size = 20; // city size, kvm only supports square maps, must be a multiple of 2

    // 4 bits per square, 0 to 8 is a non-wall square with that number of flags, 9 is a wall
    storage: [map_size * map_size / 2]u8,

    pub fn init(loaded_data: []const u8, loaded_size: u32) City {
        var c = City{ .storage = undefined };

        const byte_size = @min(map_size / 2, loaded_size / 2);
        var i: u32 = 0;
        while (i < byte_size) : (i += 1) {
            @memcpy(c.storage[i .. i + byte_size], loaded_data[i .. i + byte_size]);
        }

        return c;
    }

    // storage accessors
    // Warning: accessing out of bound is Undefined Behaviour

    pub fn get_square(self: *const City, x: u32, y: u32) u8 {
        const data: u8 = self.storage[(x + y * map_size) / 2];

        // if x is odd
        if (x & 0x01 != 0) {
            return data >> 4;
        }

        return data & 0x0f;
    }

    pub fn set_square(self: *City, x: u32, y: u32, data: u8) void {
        const stored_data: *u8 = &self.storage[(x + y * map_size) / 2];

        // mask out bits we're going to write using bitwise and and write using bitwise or
        if (x & 0x01 != 0) {
            stored_data.* &= 0x0f;
            stored_data.* |= (data << 4);
        } else {
            stored_data.* &= 0xf0;
            stored_data.* |= (data & 0x0f);
        }
    }
};

const LookupSymbolError = error{SymbolNotFound};
const RunFuncError = error{ StepOutOfBounds, PickupZeroFlags, PlaceMaxFlags, StopEncoutered };

pub const Kvm = struct {
    allocator: std.mem.Allocator,

    karel: Karel = undefined,
    city: City = undefined,

    bytecode: std.ArrayList(u8),
    symbol_map: std.StringHashMap(bytec.Func),

    func_stack: std.ArrayList(bytec.Func),
    repeat_stack: std.ArrayList(u16),

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Kvm {
        var vm = Kvm{
            .allocator = allocator,
            .bytecode = std.ArrayList(u8).init(allocator),
            .symbol_map = std.StringHashMap(bytec.Func).init(allocator),
            .func_stack = std.ArrayList(bytec.Func).init(allocator),
            .repeat_stack = std.ArrayList(u16).init(allocator),
        };

        try vm.load(path);

        return vm;
    }

    pub fn deinit(self: *Kvm) void {
        self.bytecode.deinit();
        self.symbol_map.deinit();
    }

    pub fn load(self: *Kvm, path: []const u8) !void {
        _ = path;

        self.bytecode.clearRetainingCapacity();
        self.symbol_map.clearRetainingCapacity();

        try self.bytecode.appendSlice(&[_]u8{
            @intFromEnum(bytec.KvmOpCode.branch) | @intFromEnum(bytec.KvmOpCodeCond.is_wall) << 4,
            0x00,
            0x00,
            0x00,
            0x0b,
            @intFromEnum(bytec.KvmOpCode.step),
            @intFromEnum(bytec.KvmOpCode.branch) | @intFromEnum(bytec.KvmOpCodeCond.is_wall) << 4 | 1 << 7, // set inverse bit
            0x00,
            0x00,
            0x00,
            0x05,
            @intFromEnum(bytec.KvmOpCode.left),
            @intFromEnum(bytec.KvmOpCode.repeat),
            128,
            0,
            0x00,
            0x00,
            0x00,
            0x00,
            @intFromEnum(bytec.KvmOpCode.retn),
        });

        try self.symbol_map.put("test", 0x00000000);

        self.karel = Karel{
            .home_x = 0,
            .home_y = 0,
            .pos_x = 0,
            .pos_y = 0,
            .dir = 3,
        };

        self.city = City{ .storage = undefined };
        @memset(&self.city.storage, 0);
    }

    // symbols

    pub fn run_symbol(self: *Kvm, symbol: bytec.Symbol) !void {
        const func = self.lookup_symbol(symbol);
        if (func == null) return error.SymbolNotFound;

        try self.run_func(func.?);
    }

    pub fn dump_loaded_symbols(self: *const Kvm) void {
        var iter = self.symbol_map.iterator();

        std.log.info("Kvm Loaded Symbols:", .{});

        while (iter.next()) |entry| {
            std.log.info("  symbol: \"{s}\" func: 0x{x}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn lookup_symbol(self: *const Kvm, symbol: bytec.Symbol) ?bytec.Func {
        return self.symbol_map.get(symbol);
    }

    // funcs

    fn run_func(self: *Kvm, func_entry: u32) !void {
        var func: bytec.Func = func_entry;

        var repeat_state: ?u16 = null;
        var repeat_func: ?bytec.Func = null;

        self.func_stack.clearRetainingCapacity();
        self.repeat_stack.clearRetainingCapacity();

        while (true) {
            const opcode_data: u8 = self.bytecode.items[func];
            const opcode: bytec.KvmOpCode = @enumFromInt(opcode_data & 0x0f);
            const opcode_cond: u8 = opcode_data >> 4;

            switch (opcode) {
                bytec.KvmOpCode.step => {
                    const step = self.karel.get_step(City.map_size);

                    if (step) |s| {
                        self.karel.pos_x = s.x;
                        self.karel.pos_y = s.y;

                        std.log.debug("step: {} {} {}", .{ s.x, s.y, self.karel.dir });
                    } else {
                        return RunFuncError.StepOutOfBounds;
                    }

                    func += 1;
                },

                bytec.KvmOpCode.left => {
                    self.karel.dir +%= 1;
                    func += 1;

                    std.log.debug("left: {}", .{self.karel.dir});
                },

                bytec.KvmOpCode.pick_up => {
                    const tags = self.city.get_square(self.karel.pos_x, self.karel.pos_y);

                    if (tags != 0) {
                        self.city.set_square(self.karel.pos_x, self.karel.pos_y, tags - 1);

                        std.log.debug("pick_up: {}", .{tags - 1});
                    } else {
                        return RunFuncError.PickupZeroFlags;
                    }

                    func += 1;
                },

                bytec.KvmOpCode.place => {
                    const tags = self.city.get_square(self.karel.pos_x, self.karel.pos_y);

                    if (tags != City.max_flags) {
                        self.city.set_square(self.karel.pos_x, self.karel.pos_y, tags + 1);

                        std.log.debug("place: {}", .{tags + 1});
                    } else {
                        return RunFuncError.PlaceMaxFlags;
                    }

                    func += 1;
                },

                bytec.KvmOpCode.repeat => {
                    const rfunc = bytec.get_repeat_func(self.bytecode.items[func .. func + 7]);

                    if (repeat_func != rfunc) {
                        if (repeat_func) |f| {
                            // save in-progress loop onto the stack

                            try self.func_stack.append(f);
                            try self.repeat_stack.append(repeat_state.?);
                        }

                        // setup a new loop
                        repeat_func = rfunc;
                        repeat_state = bytec.get_repeat_index(self.bytecode.items[func .. func + 7]);
                    }

                    // repeat instruction is at the *bottom* of the loop (pointing to the top)
                    repeat_state.? -= 1;

                    std.log.debug("repeat: {} 0x{x}", .{ repeat_state.?, repeat_func.? });

                    if (repeat_state == 0) {
                        // finished loop

                        if (self.repeat_stack.items.len != 0) {
                            // resume loop from stack

                            repeat_func = self.func_stack.pop();
                            repeat_state = self.repeat_stack.pop();
                        } else {
                            // all in-progress loops done

                            repeat_func = null;
                            repeat_state = null;
                        }

                        func += 7;
                    } else {
                        // continue looping
                        func = repeat_func.?;
                    }
                },

                bytec.KvmOpCode.branch => {
                    const cond = self.test_cond(opcode_cond);

                    if (cond == false) {
                        func += 5;

                        std.log.debug("branch: unmet", .{});
                        continue;
                    }

                    const br_func = bytec.get_branch_func(self.bytecode.items[func .. func + 5]);
                    func = br_func;

                    std.log.debug("branch: 0x{x}", .{br_func});
                },

                bytec.KvmOpCode.branch_linked => {
                    const cond = self.test_cond(opcode_cond);

                    if (cond == false) {
                        func += 5;

                        std.log.debug("branch_linked: unmet", .{});
                        continue;
                    }

                    const br_func = bytec.get_branch_func(self.bytecode.items[func .. func + 5]);

                    try self.func_stack.append(func);
                    func = br_func;

                    std.log.debug("branch_linked: 0x{x}", .{br_func});
                },

                bytec.KvmOpCode.retn => {
                    const ret_func: ?bytec.Func = self.func_stack.popOrNull();

                    if (ret_func) |f| {
                        func = f; // return from linked call
                        std.log.debug("retn: 0x{x}", .{f});
                    } else {
                        std.log.debug("retn: final", .{});
                        return; // end of root function
                    }
                },

                bytec.KvmOpCode.stop => {
                    std.log.debug("stop: final", .{});
                    return RunFuncError.StopEncoutered;
                },
            }
        }
    }

    // test if a condition is true
    fn test_cond(self: *const Kvm, cond: u8) bool {
        if (cond & 0x07 == @intFromEnum(bytec.KvmOpCodeCond.always)) return true;
        const is_inverse: bool = cond >> 3 == 1;

        // std.debug.print("cond: 0x{x} {}\n", .{ cond, is_inverse });

        var result: bool = undefined;
        switch (@as(bytec.KvmOpCodeCond, @enumFromInt(cond & 0x07))) {
            bytec.KvmOpCodeCond.is_wall => {
                const step = self.karel.get_step(City.map_size);

                result = if (step == null) true else if (self.city.get_square(step.?.x, step.?.y) == 9) true else false;
            },

            bytec.KvmOpCodeCond.is_flag => {
                result = self.city.get_square(self.karel.pos_x, self.karel.pos_y) != 0;
            },

            bytec.KvmOpCodeCond.is_home => {
                result = self.karel.pos_x == self.karel.home_x and self.karel.pos_y == self.karel.home_y;
            },

            bytec.KvmOpCodeCond.is_north => {
                result = self.karel.dir == 0;
            },

            bytec.KvmOpCodeCond.is_east => {
                result = self.karel.dir == 1;
            },

            bytec.KvmOpCodeCond.is_south => {
                result = self.karel.dir == 2;
            },

            bytec.KvmOpCodeCond.is_west => {
                result = self.karel.dir == 3;
            },

            else => unreachable,
        }

        return if (is_inverse) !result else result;
    }
};

test "City loading and accessing" {
    const c_data = [20]u8{ 0xa1, 0x1f, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const c = City.init(&c_data, 20);

    try std.testing.expect(c.get_square(0, 0) == 0x01);
    try std.testing.expect(c.get_square(1, 0) == 0x0a);

    try std.testing.expect(c.get_square(2, 0) == 0x0f);
}

test "City writing" {
    const c_data = [20]u8{ 0xa1, 0x1f, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var c = City.init(&c_data, 20);

    c.set_square(0, 0, 0x0f);

    try std.testing.expect(c.get_square(0, 0) == 0x0f);
    try std.testing.expect(c.get_square(1, 0) == 0x0a);

    c.set_square(1, 0, 0x0fb);

    try std.testing.expect(c.get_square(0, 0) == 0x0f);
    try std.testing.expect(c.get_square(1, 0) == 0x0b);
}

test "Karel Direction Overflow" {
    const val: u2 = 3; // the u2 is important here

    try std.testing.expect(val +% 1 == 0);
}
