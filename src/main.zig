const std = @import("std");
const kvm = @import("kvm.zig");
const kvm_comp = @import("kvm-compiler.zig");

const builtin = @import("builtin");

// compile with -Doptimize=Debug for execution status
// compile with -Doptimize=ReleaseFast for speed

// global VM instance
var vm_instance: ?kvm.Kvm = null;

pub const std_options = struct {
    pub const log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast => .info,
        .ReleaseSmall => .err,
    };
};

// loading and managment

// initializes the library
export fn init() callconv(.C) kvm.KvmResult {
    std.log.info("Initializing Kvm...", .{});

    if (vm_instance != null) return .not_initialized;

    vm_instance = kvm.Kvm.init(std.heap.page_allocator) catch |err| {
        std.log.err("Kvm Failed to Initialize, error: {}", .{err});

        return .unknown_error;
    };

    return .success;
}

// deinits and frees libraries memory
export fn deinit() callconv(.C) void {
    vm_instance.?.deinit();
}

// (re)loads new karel-lang source into memory
//
// will block if interpreter running
export fn load(src_arg: [*c]const u8) callconv(.C) kvm.KvmResult {
    const src: []const u8 = std.mem.span(src_arg);

    if (vm_instance != null) {
        vm_instance.?.load(src) catch |err| {
            std.log.err("error while compiling karel-lang: {}", .{err});

            return switch (err) {
                kvm_comp.CompilerError.UnknownCondition, kvm_comp.CompilerError.UnknownConditionPrefix, kvm_comp.CompilerError.RepeatCountInvalid, kvm_comp.CompilerError.RepeatCountTooBig => .compilation_error,

                else => .unknown_error,
            };
        };

        return .success;
    } else return .not_initialized;
}

// (re)loads new karel-lang file into memory
//
// will block if interpreter running
export fn load_file(path_arg: [*c]const u8) callconv(.C) kvm.KvmResult {
    const path: []const u8 = std.mem.span(path_arg);

    if (vm_instance != null) {
        vm_instance.?.load_file(path) catch |err| {
            std.log.err("error while compiling karel-lang: {}", .{err});

            return switch (err) {
                error.FileNotFound => .file_not_found,

                kvm_comp.CompilerError.UnknownCondition, kvm_comp.CompilerError.UnknownConditionPrefix, kvm_comp.CompilerError.RepeatCountInvalid, kvm_comp.CompilerError.RepeatCountTooBig => .compilation_error,

                else => .unknown_error,
            };
        };

        return .success;
    } else return .not_initialized;
}

// TODO: world load
// (re)loads Karel's and Cities state into memory
// buf contains an array of values that are between 0 to 8 (empty or flag) or equal to 255 (wall)
// array is row-major and sized map_size * map_size
//
// k_buf contains karel_x, karel_y, dir (between 0 to 3), home_x, home_y in this order
//
// will block if interpreter running
export fn load_world(buf_arg: [*c]const u8, k_buf_arg: [*c]const u32) callconv(.C) kvm.KvmResult {
    if (vm_instance != null) {
        const buf: []const u8 = buf_arg[0 .. kvm.Kvm.map_size * kvm.Kvm.map_size];
        const k_buf: []const u32 = k_buf_arg[0..5];

        vm_instance.?.load_world(buf, k_buf);

        return .success;
    } else return .not_initialized;
}

// reads the current state of the city and karel in memory
// this might create some race conditions if the interpreter is running (creating some inconsistencies in the read data) but i don't care!
//
// format identical to load_world
export fn read_world(buf_arg: [*c]u8, k_buf_arg: [*c]u32) callconv(.C) kvm.KvmResult {
    if (vm_instance) |vm| {
        var buf: []u8 = buf_arg[0 .. kvm.Kvm.map_size * kvm.Kvm.map_size];
        var k_buf: []u32 = k_buf_arg[0..5];

        vm.read_world(buf) catch |err| {
            return switch (err) {
                error.KvmStateNotValid => .state_not_valid,

                // else => .unknown_error,
            };
        };

        k_buf[0] = vm.karel.pos_x;
        k_buf[1] = vm.karel.pos_y;

        k_buf[2] = vm.karel.dir;

        k_buf[3] = vm.karel.home_x;
        k_buf[4] = vm.karel.home_y;

        return .success;
    } else return .not_initialized;
}

// hard stops the interpreter
export fn short_circuit() callconv(.C) kvm.KvmResult {
    if (vm_instance != null) {
        vm_instance.?.short_circuit();

        while (vm_instance.?.inter_status.load(std.builtin.AtomicOrder.Acquire) == .in_progress) {}

        return .success;
    } else return .not_initialized;
}

// returns the interpreter status (.in_progress if still processing)
export fn status() callconv(.C) kvm.KvmResult {
    if (vm_instance) |vm| {
        return vm.inter_status.load(std.builtin.AtomicOrder.Acquire);
    } else return .not_initialized;
}

// prints every symbol from the bcode currentrly in memory
export fn dump_loaded() callconv(.C) kvm.KvmResult {
    if (vm_instance) |vm| {
        vm.dump_loaded_symbols();

        return .success;
    } else return .not_initialized;
}

// execution

// looks up and executes a symbol from the bcode in currently memory
//
// symbol arg *must* be a utf-8 encoded null terminated string
// will block if interpreter running
export fn run_symbol(sym: [*c]const u8) callconv(.C) kvm.KvmResult {
    const sym_slice: []const u8 = std.mem.span(sym);

    if (vm_instance != null) {
        // var startTime = std.time.nanoTimestamp();

        vm_instance.?.run_symbol(sym_slice) catch |err| {
            std.log.err("An error occurred while interpreting karel bcode! error: {}", .{err});

            return .unknown_error;
        };

        // std.log.info("Karel's execution of {} funcs has finished in {}!", .{ func_count, std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime))) });

        return vm_instance.?.inter_status.load(std.builtin.AtomicOrder.Acquire);
    } else return .not_initialized;
}

pub fn main() !void {
    var startTime = std.time.nanoTimestamp();

    _ = init();

    _ = load_file("test.kl");

    var storage: [kvm.Kvm.map_size * kvm.Kvm.map_size / 2]u8 = undefined;
    @memset(&storage, 0);

    const karel: [5]u32 = [_]u32{ 0, 0, 0, 0, 0 };

    _ = load_world(&storage, &karel);

    std.log.info("Kvm Successfully Initialized in {}!", .{std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime)))});

    _ = run_symbol("ROOT-ALIGN");

    startTime = std.time.nanoTimestamp();

    while (vm_instance.?.inter_status.load(std.builtin.AtomicOrder.Acquire) == .in_progress) {}

    std.log.info("Karel's execution has finished in {}!", .{std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime)))});
}
