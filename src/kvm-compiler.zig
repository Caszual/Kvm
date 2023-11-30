const std = @import("std");
const bc = @import("kvm-bcode.zig");

pub const CompilerError = error{ UnknownConditionPrefix, UnknownCondition, RepeatCountTooBig, RepeatCountInvalid };

pub fn compileFile(path: []const u8, allocator: std.mem.Allocator, bytecode: *std.ArrayList(u8), symbol_map: *std.StringHashMap(bc.Func)) !void {
    // load file

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    try compile(file.reader(), allocator, bytecode, symbol_map);
}

const BytecodeContext = struct {
    bytecode: *std.ArrayList(u8),
    symbol_map: *std.StringHashMap(bc.Func),

    unresolved_symbols: std.StringHashMap(std.ArrayList(bc.Func)),

    buf: [256]u8 = undefined,

    allocator: std.mem.Allocator,
};

fn trimFromFirst(haystack: []const u8, needle: []const u8) []const u8 {
    const index = std.mem.lastIndexOf(u8, haystack, needle);

    if (index) |i| {
        if (i == 0) return haystack;

        return .{ .ptr = haystack.ptr, .len = i };
    } else {
        return haystack;
    }
}

fn trimFromLast(haystack: []const u8, needle: []const u8) []const u8 {
    const index = std.mem.indexOf(u8, haystack, needle);

    if (index) |i| {
        if (i == haystack.len - 1) return haystack;

        return .{ .ptr = haystack.ptr + i + 1, .len = haystack.len - i - 1 };
    } else {
        return haystack;
    }
}

fn read_line(reader: anytype, buf: []u8) ![]const u8 {
    var lr = try reader.readUntilDelimiterOrEof(buf, '\n');

    if (lr != null) {
        var l = std.mem.trimRight(u8, lr.?, ";"); // trim comments
        l = std.mem.trim(u8, l, " "); // trim whitespaces

        return l;
    } else {
        return error.UnexpectedEndOfFile;
    }
}

fn compileCondition(l: []const u8) CompilerError!struct { cond: bc.KvmCondition, inverse: bool } {
    const lww = std.mem.trim(u8, l, " ");

    // parse the condition prefix
    const inverse: bool = if (std.mem.startsWith(u8, lww, "IS ")) false else if (std.mem.startsWith(u8, lww, "ISNOT ")) true else return CompilerError.UnknownConditionPrefix;

    // parse the condition
    const cl = if (inverse)
        std.mem.trimLeft(u8, lww, "ISNOT")
    else
        std.mem.trimLeft(u8, lww, "IS");

    const clww = std.mem.trim(u8, cl, " ");

    const c: bc.KvmCondition = if (std.mem.eql(u8, clww, "WALL"))
        .is_wall
    else if (std.mem.eql(u8, clww, "FLAG"))
        .is_flag
    else if (std.mem.eql(u8, clww, "HOME"))
        .is_home
    else if (std.mem.eql(u8, clww, "NORTH"))
        .is_north
    else if (std.mem.eql(u8, clww, "WEST"))
        .is_west
    else if (std.mem.eql(u8, clww, "SOUTH"))
        .is_south
    else if (std.mem.eql(u8, clww, "EAST"))
        .is_east
    else
        return CompilerError.UnknownCondition;

    return .{ .cond = c, .inverse = inverse };
}

pub fn compile(reader: anytype, allocator: std.mem.Allocator, bytecode: *std.ArrayList(u8), symbol_map: *std.StringHashMap(bc.Func)) !void {
    var context = BytecodeContext{ .bytecode = bytecode, .symbol_map = symbol_map, .unresolved_symbols = std.StringHashMap(std.ArrayList(bc.Func)).init(allocator), .allocator = allocator };
    defer context.unresolved_symbols.deinit();

    std.log.info("Start of kvm bytecode compilation...", .{});
    std.log.debug("", .{});

    // insert special kvm symbols

    // null-func - MUST be at address 0x0; catches calling bcode at null funcs
    try bytecode.append(@bitCast(bc.KvmByte{ .opcode = .stop }));

    // noop-func - defined as at address 0x01; every empty symbol is pointing here
    try bytecode.append(@bitCast(bc.KvmByte{ .opcode = .retn }));

    std.log.debug("null-func:", .{});
    std.log.debug("  0x0: stop", .{});
    std.log.debug("noop-func:", .{});
    std.log.debug("  0x1: retn", .{});
    std.log.debug("", .{});

    // compiling stage

    while (true) {
        var lr = try reader.readUntilDelimiterOrEof(&context.buf, '\n');

        if (lr != null) {
            var l = std.mem.trimRight(u8, lr.?, ";"); // trim comments
            l = std.mem.trim(u8, l, " "); // trim whitespaces

            if (l.len == 0) continue; // empty/comment line

            // compile symbol

            // clone symbol name
            const lc = try context.allocator.alloc(u8, l.len);
            @memcpy(lc, l);

            std.log.debug("{s}:", .{lc});

            var entry = try context.symbol_map.getOrPut(lc);
            if (entry.found_existing) return error.SymbolAlreadyDefined;

            entry.value_ptr.* = @intCast(context.bytecode.items.len);

            // compile symbol scope
            try compileScope(reader, &context);

            if (context.bytecode.items.len == entry.value_ptr.*) {
                entry.value_ptr.* = 0x1; // noop-func, point symbol to the global noop-func

                std.log.debug("  (optimized out no-op func)", .{});
                std.log.debug("", .{});
                continue;
            }

            // append scope retn opcode (not appended by compileScope())
            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .retn }));
            std.log.debug("  0x{x}: retn", .{context.bytecode.items.len - 1});
            std.log.debug("", .{});
        } else {
            break;
        }
    }

    // resolving stage

    std.log.info("Resolving unresolved symbols from compile stage...", .{});

    var iter = context.unresolved_symbols.iterator();
    while (iter.next()) |entry| {
        const sym: ?bc.Func = context.symbol_map.get(entry.key_ptr.*);

        if (sym) |sym_func| {
            // write symbols func

            if (sym_func != 0x1) {
                std.log.debug("resolving sym: \"{s}\" as func: 0x{x}", .{ entry.key_ptr.*, sym_func });
            } else {
                std.log.debug("resolving sym: \"{s}\" as noop-func", .{entry.key_ptr.*});
            }

            for (entry.value_ptr.items) |unresolved_func| {
                @memcpy(context.bytecode.items[unresolved_func .. unresolved_func + 4], std.mem.asBytes(&sym_func));
            }
        } else {
            // write noop func
            const noop_func: u32 = 0x01;

            std.log.debug("resolving sym: \"{s}\" as noop-func", .{entry.key_ptr.*});

            for (entry.value_ptr.items) |unresolved_func| {
                @memcpy(context.bytecode.items[unresolved_func .. unresolved_func + 4], std.mem.asBytes(&noop_func));
            }
        }
    }

    std.log.info("Kvm bytecode compilation finished successfully!", .{});
}

// compiles one scope of karel-lang to bytecode, may have unresolved symbols and funcs when finished
fn compileScope(reader: anytype, context: *BytecodeContext) !void {
    while (true) {
        const l = try read_line(reader, &context.buf);

        if (std.mem.eql(u8, l, "STEP")) {
            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .step }));

            std.log.debug("  0x{x}: step", .{context.bytecode.items.len - 1});
        } else if (std.mem.eql(u8, l, "LEFT")) {
            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .left }));

            std.log.debug("  0x{x}: left", .{context.bytecode.items.len - 1});
        } else if (std.mem.eql(u8, l, "PICK")) {
            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .pick_up }));

            std.log.debug("  0x{x}: pick", .{context.bytecode.items.len - 1});
        } else if (std.mem.eql(u8, l, "PLACE")) {
            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .place }));

            std.log.debug("  0x{x}: place", .{context.bytecode.items.len - 1});
        } else if (std.mem.startsWith(u8, l, "REPEAT")) {
            // func to start of loop
            const repeat_begin_func: bc.Func = @intCast(context.bytecode.items.len);

            const repeat_count: u16 = std.fmt.parseInt(u16, std.mem.trimRight(u8, std.mem.trimLeft(u8, l, "REPEAT "), "-TIMES"), 0) catch |err| {
                if (err == std.fmt.ParseIntError.Overflow) {
                    return CompilerError.RepeatCountTooBig;
                } else if (err == std.fmt.ParseIntError.InvalidCharacter) {
                    return CompilerError.RepeatCountInvalid;
                } else {
                    return err;
                }
            };

            std.log.debug("  (repeat start)", .{});

            // compile loop body
            try compileScope(reader, context);

            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .repeat })); // repeat opcode
            try context.bytecode.appendSlice(std.mem.asBytes(&repeat_count)); // repeat trailing count
            try context.bytecode.appendSlice(std.mem.asBytes(&repeat_begin_func)); // repeat trailing func

            std.log.debug("  0x{x}: repeat; count {}; begin func 0x{x}", .{ context.bytecode.items.len - 7, repeat_count, repeat_begin_func });
            std.log.debug("  (repeat end)", .{});
        } else if (std.mem.startsWith(u8, l, "UNTIL")) {
            const cond = try compileCondition(std.mem.trimLeft(u8, l, "UNTIL"));

            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .branch, .condcode = cond.cond, .cond_inverse = !cond.inverse })); // first branch (not part of the loop, only checks the first time if the condition is already true and skips the loop)

            const until_end_func_ptr: bc.Func = @intCast(context.bytecode.items.len);
            try context.bytecode.appendNTimes(undefined, @sizeOf(bc.Func)); // allocate null func (resolved after loop body is compiled)

            // func to start of loop
            const until_begin_func: bc.Func = @intCast(context.bytecode.items.len);

            std.log.debug("  (until start)", .{});

            try compileScope(reader, context);

            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .branch, .condcode = cond.cond, .cond_inverse = cond.inverse })); // main branch (that actually loops the loop)
            try context.bytecode.appendSlice(std.mem.asBytes(&until_begin_func));

            std.log.debug("  0x{x}: until; cond: {} (inverse: {}); begin func: 0x{x}", .{ context.bytecode.items.len - 5, cond.cond, cond.inverse, until_begin_func });
            std.log.debug("  (until end)", .{});

            // func to first opcode outside of loop
            const until_end_func: bc.Func = @intCast(context.bytecode.items.len);

            // resolve first branch func
            @memcpy(context.bytecode.items[until_end_func_ptr .. until_end_func_ptr + @sizeOf(bc.Func)], std.mem.asBytes(&until_end_func));
        } else if (std.mem.startsWith(u8, l, "IF")) {
            // TODO: if branching

            const cond = try compileCondition(std.mem.trimLeft(u8, l, "IF"));

            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .branch, .condcode = cond.cond, .cond_inverse = !cond.inverse }));

            const else_begin_func_ptr: bc.Func = @intCast(context.bytecode.items.len);
            try context.bytecode.appendNTimes(undefined, @sizeOf(bc.Func)); // allocate null func (resolved after the if body is compiled)

            std.log.debug("  0x{x}: if; cond: {} (inverse: {})", .{ context.bytecode.items.len - 5, cond.cond, cond.inverse });

            std.log.debug("  (if start)", .{});

            try compileScope(reader, context); // compile if body

            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .branch }));

            const if_end_func_ptr: bc.Func = @intCast(context.bytecode.items.len);
            try context.bytecode.appendNTimes(undefined, @sizeOf(bc.Func));

            std.log.debug("  0x{x}: if out", .{context.bytecode.items.len - 5});

            const else_begin_func: bc.Func = @intCast(context.bytecode.items.len); // if else branch is empty func will point out the if body
            @memcpy(context.bytecode.items[else_begin_func_ptr .. else_begin_func_ptr + @sizeOf(bc.Func)], std.mem.asBytes(&else_begin_func)); // resolve if to else branch func

            std.log.debug("  (0x{x}: else start)", .{else_begin_func});

            try compileScope(reader, context); // compile else body

            const if_end_func: bc.Func = @intCast(context.bytecode.items.len); // if both if and else branches are empty this branch opcode will just jump to the next opcode after it self (effectively being a no-op)
            @memcpy(context.bytecode.items[if_end_func_ptr .. if_end_func_ptr + @sizeOf(bc.Func)], std.mem.asBytes(&if_end_func)); // resolve if branch out func

            std.log.debug("  (0x{x}: if end)", .{if_end_func});
        } else if (std.mem.startsWith(u8, l, "STOP")) {
            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .stop }));

            std.log.debug("  0x{x}: stop", .{context.bytecode.items.len - 1});
        } else if (std.mem.startsWith(u8, l, "END")) {
            return; // end current scope (retn opcode only at the end of the symbol scope; inserted by top level scope compile)
        } else { // symbol call
            try context.bytecode.append(@bitCast(bc.KvmByte{ .opcode = .branch_linked }));

            // try looking up if symbol is already defined
            const symbol: ?bc.Func = context.symbol_map.get(l);

            if (symbol) |sym| {
                // symbol found!

                try context.bytecode.appendSlice(std.mem.asBytes(&sym)); // append trailing func

                std.log.debug("  0x{x}: branch-linked; sym: \"{s}\" func: 0x{x}", .{ context.bytecode.items.len - 5, l, sym });
            } else {
                // symbol not found

                const unresolved_func_func: bc.Func = @intCast(context.bytecode.items.len);
                try context.bytecode.appendSlice(&[4]u8{ 0, 0, 0, 0 }); // allocate null func until symbol is resolved

                // clone symbol name
                const lc = try context.allocator.alloc(u8, l.len);
                @memcpy(lc, l);

                // mark func as unresolved
                var entry = try context.unresolved_symbols.getOrPut(lc);

                if (!entry.found_existing) entry.value_ptr.* = std.ArrayList(bc.Func).init(context.allocator);
                try entry.value_ptr.append(unresolved_func_func);

                std.log.debug("  0x{x}: branch-linked; sym: \"{s}\" func: unresolved", .{ context.bytecode.items.len - 5, lc });
            }
        }
    }

    unreachable;
}

test "Karel-lang To Kvm bytecode Compiler" {
    var bytec = std.ArrayList(u8).init(std.testing.allocator);
    var sym_map = std.StringHashMap(bc.Func).init(std.testing.allocator);

    defer bytec.deinit();

    defer {
        sym_map.deinit();
    }

    try compileFile("test.kl", std.testing.allocator, &bytec, &sym_map);
}
