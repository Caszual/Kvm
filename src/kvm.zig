const std = @import("std");
const bc = @import("kvm-bcode.zig");
const comp = @import("kvm-compiler.zig");

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
    const CityByte = packed struct { s1: u4, s2: u4 };

    storage: [map_size * map_size / 2]CityByte,

    pub fn init(loaded_data: []const u8, loaded_size: u32) City {
        var c = City{ .storage = undefined };

        const byte_size = @min(map_size / 2, loaded_size / 2);
        var i: u32 = 0;
        while (i < byte_size) : (i += 1) {
            @memcpy(c.storage[i .. i + byte_size], @as([]const CityByte, @ptrCast(loaded_data))[i .. i + byte_size]); // note: zig is angry without the prtCast because of different ABI sizes
        }

        return c;
    }

    // storage accessors
    // Warning: accessing out of bound is Undefined Behaviour

    pub fn get_square(self: *const City, x: u32, y: u32) u4 {
        const data = self.storage[(x + y * map_size) / 2];

        // if x is odd
        if (x & 0x01 == 0) {
            return data.s1;
        }

        return data.s2;
    }

    pub fn set_square(self: *City, x: u32, y: u32, data: u4) void {
        const stored_data: *CityByte = &self.storage[(x + y * map_size) / 2];

        if (x & 0x01 == 0) {
            stored_data.s1 = data;
        } else {
            stored_data.s2 = data;
        }
    }
};

const LookupSymbolError = error{SymbolNotFound};
const RunFuncError = error{ StepOutOfBounds, PickupZeroFlags, PlaceMaxFlags, StopEncoutered };

pub const Kvm = struct {
    allocator: std.mem.Allocator,

    karel: Karel = undefined,
    city: City = undefined,

    // see kvm-bcode.zig for explanation
    bcode: std.ArrayList(u8),
    symbol_map: std.StringHashMap(bc.Func),

    // represents the function call (and repeat) stack (for retn)
    func_stack: std.ArrayList(bc.Func),
    repeat_stack: std.ArrayList(u16),

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Kvm {
        var vm = Kvm{
            .allocator = allocator,
            .bcode = std.ArrayList(u8).init(allocator),
            .symbol_map = std.StringHashMap(bc.Func).init(allocator),
            .func_stack = std.ArrayList(bc.Func).init(allocator),
            .repeat_stack = std.ArrayList(u16).init(allocator),
        };

        try vm.load(path);

        return vm;
    }

    pub fn deinit(self: *Kvm) void {
        self.bcode.deinit();

        //{
        //    var iter = self.symbol_map.keyIterator();
        //
        //    while (iter.next()) |key| {
        //        self.allocator.destroy(key);
        //    }
        //
        //    self.symbol_map.deinit();
        //}

        self.func_stack.deinit();
        self.repeat_stack.deinit();
    }

    pub fn load(self: *Kvm, path: []const u8) !void {
        self.bcode.clearRetainingCapacity();
        self.symbol_map.clearRetainingCapacity();

        // example bcode, karel will loop around the map about ~32k times (128 << 4 times)
        // equvalent to:
        // test <- symbol name
        //   repeat 32768-times
        //     until is wall
        //       step
        //     end
        //     left
        //   end
        // end

        // try self.bcode.appendSlice(&[_]u8{
        //     @bitCast(bc.KvmByte{ .opcode = .branch, .condcode = .is_wall, .cond_inverse = false }),
        //     0x00,
        //     0x00,
        //     0x00,
        //     0x0b,
        //     @bitCast(bc.KvmByte{ .opcode = .step }),
        //     @bitCast(bc.KvmByte{ .opcode = .branch, .condcode = .is_wall, .cond_inverse = true }), // inverse bit set
        //     0x00,
        //     0x00,
        //     0x00,
        //     0x05,
        //     @bitCast(bc.KvmByte{ .opcode = .left }),
        //     @bitCast(bc.KvmByte{ .opcode = .repeat }),
        //     128,
        //     0,
        //     0x00,
        //     0x00,
        //     0x00,
        //     0x00,
        //     @bitCast(bc.KvmByte{ .opcode = .retn }),
        // });

        // make the bcode a function with a name
        // try self.symbol_map.put("test", 0x00000000);

        try comp.compileFile(path, self.allocator, &self.bcode, &self.symbol_map);

        self.karel = Karel{
            .home_x = 0,
            .home_y = 0,
            .pos_x = 10,
            .pos_y = 10,
            .dir = 3,
        };

        // clear map
        self.city = City{ .storage = undefined };
        @memset(&self.city.storage, .{ .s1 = 0, .s2 = 0 });
    }

    // symbols

    pub fn run_symbol(self: *Kvm, symbol: bc.Symbol) !u32 {
        const func = self.lookup_symbol(symbol);
        if (func == null) return error.SymbolNotFound;

        return try self.run_func(func.?);
    }

    pub fn dump_loaded_symbols(self: *const Kvm) void {
        var iter = self.symbol_map.iterator();

        std.log.info("Kvm Loaded Symbols:", .{});

        while (iter.next()) |entry| {
            std.log.info("  symbol: \"{s}\" func: 0x{x}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn lookup_symbol(self: *const Kvm, symbol: bc.Symbol) ?bc.Func {
        return self.symbol_map.get(symbol);
    }

    // funcs

    fn run_func(self: *Kvm, func_entry: bc.Func) !u32 {
        var func: bc.Func = func_entry;

        var repeat_state: ?u16 = null;
        var repeat_func: ?bc.Func = null;

        var func_count: u32 = 0;

        self.func_stack.clearRetainingCapacity();
        self.repeat_stack.clearRetainingCapacity();

        while (true) {
            const opcode: bc.KvmByte = @bitCast(self.bcode.items[func]);

            func_count += 1;

            switch (opcode.opcode) {
                bc.KvmOpCode.step => {
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

                bc.KvmOpCode.left => {
                    self.karel.dir +%= 1;
                    func += 1;

                    std.log.debug("left: {}", .{self.karel.dir});
                },

                bc.KvmOpCode.pick_up => {
                    const tags = self.city.get_square(self.karel.pos_x, self.karel.pos_y);

                    if (tags != 0) {
                        self.city.set_square(self.karel.pos_x, self.karel.pos_y, tags - 1);

                        std.log.debug("pick_up: {}", .{tags - 1});
                    } else {
                        return RunFuncError.PickupZeroFlags;
                    }

                    func += 1;
                },

                bc.KvmOpCode.place => {
                    const tags = self.city.get_square(self.karel.pos_x, self.karel.pos_y);

                    if (tags != City.max_flags) {
                        self.city.set_square(self.karel.pos_x, self.karel.pos_y, tags + 1);

                        std.log.debug("place: {}", .{tags + 1});
                    } else {
                        return RunFuncError.PlaceMaxFlags;
                    }

                    func += 1;
                },

                bc.KvmOpCode.repeat => {
                    const rfunc = bc.get_repeat_func(self.bcode.items[func .. func + 7]);

                    if (repeat_func != rfunc) {
                        if (repeat_func) |f| {
                            // save in-progress loop onto the stack

                            try self.func_stack.append(f);
                            try self.repeat_stack.append(repeat_state.?);
                        }

                        // setup a new loop
                        repeat_func = rfunc;
                        repeat_state = bc.get_repeat_index(self.bcode.items[func .. func + 7]);
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

                bc.KvmOpCode.branch => {
                    const cond = self.test_cond(opcode);

                    if (cond == false) {
                        func += 5;

                        std.log.debug("branch: unmet", .{});
                        continue;
                    }

                    const br_func = bc.get_branch_func(self.bcode.items[func .. func + 5]);
                    func = br_func;

                    std.log.debug("branch: 0x{x}", .{br_func});
                },

                bc.KvmOpCode.branch_linked => {
                    const cond = self.test_cond(opcode);

                    if (cond == false) {
                        func += 5;

                        std.log.debug("branch_linked: unmet", .{});
                        continue;
                    }

                    const br_func = bc.get_branch_func(self.bcode.items[func .. func + 5]);

                    try self.func_stack.append(func + 5);
                    func = br_func;

                    std.log.debug("branch_linked: 0x{x}", .{br_func});
                },

                bc.KvmOpCode.retn => {
                    const ret_func: ?bc.Func = self.func_stack.popOrNull();

                    if (ret_func) |f| {
                        func = f; // return from linked call
                        std.log.debug("retn: 0x{x}", .{f});
                    } else {
                        std.log.debug("retn: final", .{});
                        return func_count; // end of root function
                    }
                },

                bc.KvmOpCode.stop => {
                    std.log.debug("stop: final", .{});
                    return RunFuncError.StopEncoutered;
                },
            }
        }

        unreachable;
    }

    // test if a condition is true
    fn test_cond(self: *const Kvm, opcode: bc.KvmByte) bool {
        if (opcode.condcode == .always) return true;

        // std.debug.print("cond: 0x{x} {}\n", .{ opcode.condcode, opcode.cond_inverse });

        var result: bool = undefined;
        switch (opcode.condcode) {
            bc.KvmCondition.is_wall => {
                const step = self.karel.get_step(City.map_size);

                result = if (step == null) true else if (self.city.get_square(step.?.x, step.?.y) == 9) true else false;
            },

            bc.KvmCondition.is_flag => {
                result = self.city.get_square(self.karel.pos_x, self.karel.pos_y) != 0;
            },

            bc.KvmCondition.is_home => {
                result = self.karel.pos_x == self.karel.home_x and self.karel.pos_y == self.karel.home_y;
            },

            bc.KvmCondition.is_north => {
                result = self.karel.dir == 0;
            },

            bc.KvmCondition.is_east => {
                result = self.karel.dir == 1;
            },

            bc.KvmCondition.is_south => {
                result = self.karel.dir == 2;
            },

            bc.KvmCondition.is_west => {
                result = self.karel.dir == 3;
            },

            else => unreachable,
        }

        return if (opcode.cond_inverse) !result else result;
    }
};

test "City loading and accessing" {
    const c_data = [20]u8{ 0xa1, 0x1f, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const c = City.init(&c_data, 20);

    try std.testing.expect(@sizeOf(City.CityByte) == 1);
    try std.testing.expect(@bitSizeOf(City.CityByte) == 8);

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

    c.set_square(1, 0, 0x0b);

    try std.testing.expect(c.get_square(0, 0) == 0x0f);
    try std.testing.expect(c.get_square(1, 0) == 0x0b);
}

test "Karel Direction Overflow" {
    const val: u2 = 3; // the u2 is important here

    try std.testing.expect(val +% 1 == 0);
}
