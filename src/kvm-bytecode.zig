const std = @import("std");

// KvmOpCode enum describes the Kvm bytecode format in-memory
// when the simulation is running, can be translated back to Karel-lang
pub const KvmOpCode = enum(u4) {
    step,
    left,
    pick_up,
    place,
    repeat, // trailing u16 and Func
    branch, // trailing KvmOpCodeCond and Func
    branch_linked, // trailing KvmOpCodeCond and Func
    retn,
    stop,
};

// karel-lang | kvm-bytecode
//            |
// until      | branch at start and end of loop
// if         | branch to else body and branch at end of non-else body
// [user_func]| branch_linked and retn

// an KvmOpCode byte format:
// 1|001|0010
//
// 1. invert bit (inverts condition, is -> is not)
// 2. KvmOpCodeCond (specifies condition, only for branch and branch_linked)
// 3. KvmOpCode (spicifies instruction)

// KvmOpCodeCond defines the condition for conditional ops like until and if
// KvmOpCode and KvmOpCodeCond are always packed into a single u8
pub const KvmOpCodeCond = enum(u8) {
    always = 0, // no condition
    is_wall,
    is_flag,
    is_home,
    is_north,
    is_east,
    is_south,
    is_west,
};

// practically an address in bytecode, used for jumping
pub const Func = u32;

// string, used for looking up symbol names and converting them to Funcs
pub const Symbol = []const u8;

pub fn get_repeat_index(func_bytecode: []const u8) u16 {
    return func_bytecode[2] | @as(u16, func_bytecode[1]) << 8;
}

pub fn get_repeat_func(func_bytecode: []const u8) Func {
    return func_bytecode[6] | @as(u32, func_bytecode[5]) << 8 | @as(u32, func_bytecode[4]) << 16 | @as(u32, func_bytecode[3]) << 24;
}

pub fn get_branch_func(func_bytecode: []const u8) Func {
    return func_bytecode[4] | @as(u32, func_bytecode[3]) << 8 | @as(u32, func_bytecode[2]) << 16 | @as(u32, func_bytecode[1]) << 24;
}

// transpiling

// compiles karel-lang to in-memory karel-lang
pub fn compile(bytecode: *std.ArrayList(u8), symbol_map: *std.StringHashMap(Func), kcode: []const u8) !void {
    _ = kcode;
    _ = symbol_map;
    _ = bytecode;
}

// compiles in-memory bytecode to karel-lang
pub fn decompile(bytecode: []const u8, symbol_map: std.StringHashMap(Func)) !std.ArrayList(u8) {
    _ = symbol_map;
    _ = bytecode;
}
