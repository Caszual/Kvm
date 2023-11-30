const std = @import("std");

// KvmOpCode enum describes the Kvm bytecode format in-memory
// when the simulation is running, can be translated back to Karel-lang
pub const KvmOpCode = enum(u4) {
    step,
    left,
    pick_up,
    place,
    repeat, // trailing u16 and Func
    branch, // trailing KvmCondition and Func
    branch_linked, // trailing KvmCondition and Func
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
// 2. KvmCondition (specifies condition, only for branch and branch_linked)
// 3. KvmOpCode (spicifies instruction)

// KvmCondition defines the condition for conditional ops like until and if
// KvmOpCode and KvmCondition are always packed into a single u8
pub const KvmCondition = enum(u3) {
    none = 0, // no condition
    is_wall,
    is_flag,
    is_home,
    is_north,
    is_east,
    is_south,
    is_west,
};

pub const KvmByte = packed struct {
    opcode: KvmOpCode,
    condcode: KvmCondition = .none,
    cond_inverse: bool = false,
};

// practically an address in bytecode, used for jumping
pub const Func = u32;

// string, used for looking up symbol names and converting them to Funcs
pub const Symbol = []const u8;

pub fn get_repeat_index(func_bytecode: []const u8) u16 {
    return func_bytecode[1] | @as(u16, func_bytecode[2]) << 8;
}

pub fn get_repeat_func(func_bytecode: []const u8) Func {
    return func_bytecode[3] | @as(u32, func_bytecode[4]) << 8 | @as(u32, func_bytecode[5]) << 16 | @as(u32, func_bytecode[6]) << 24;
}

pub fn get_branch_func(func_bytecode: []const u8) Func {
    return func_bytecode[1] | @as(u32, func_bytecode[2]) << 8 | @as(u32, func_bytecode[3]) << 16 | @as(u32, func_bytecode[4]) << 24;
}

test "Bytecode Format" {
    try std.testing.expect(@sizeOf(KvmByte) == 1);
    try std.testing.expect(@bitSizeOf(KvmByte) == 8);
}
