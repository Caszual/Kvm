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

// (re)loads new karel-lang file into memory
export fn load(file_path_arg: [*c]const u8) callconv(.C) kvm.KvmResult {
    const file_path: []const u8 = std.mem.span(file_path_arg);

    if (vm_instance != null) {
        vm_instance.?.load(file_path) catch |err| {
            std.log.err("error while compiling karel-lang: {}", .{err});

            return switch (err) {
                error.FileNotFound => .file_not_found,

                error.InProgress => .in_progress,

                kvm_comp.CompilerError.UnknownCondition, kvm_comp.CompilerError.UnknownConditionPrefix, kvm_comp.CompilerError.RepeatCountInvalid, kvm_comp.CompilerError.RepeatCountTooBig => .compilation_error,

                else => .unknown_error,
            };
        };

        return .success;
    } else return .not_initialized;
}

// TODO: world load
// (re)loads Karel's and Cities state into memory
export fn load_world() callconv(.C) kvm.KvmResult {
    if (vm_instance != null) {
        vm_instance.?.load_world() catch |err| {
            return switch (err) {
                error.InProgress => .in_progress,
            };
        };

        // vm.setKarel();
        // vm.setCity();

        return .success;
    } else return .not_initialized;
}

// reads the current state of the world in memory
// this might create some race conditions if the interpreter is running (creating some inconsistencies in the read data) but i don't care!
export fn read_world(cbuf: [*c]u8) callconv(.C) kvm.KvmResult {
    if (vm_instance) |vm| {
        var buf: []u8 = cbuf[0 .. kvm.Kvm.map_size * kvm.Kvm.map_size];

        vm.read_world(buf) catch |err| {
            return switch (err) {
                error.KvmStateNotValid => .state_not_valid,

                // else => .unknown_error,
            };
        };

        return .success;
    } else return .not_initialized;
}

// reads the current state of Karel in memory
// this might create some race conditions (creating some inconsistencies in the read data) but i don't care!
export fn read_karel(cbuf: [*c]u32) callconv(.C) kvm.KvmResult {
    if (vm_instance) |vm| {
        var buf: []u32 = cbuf[0..3];

        buf[0] = vm.karel.pos_x;
        buf[1] = vm.karel.pos_y;

        buf[2] = vm.karel.dir;

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

    _ = load("test.kl");
    _ = load_world();

    std.log.info("Kvm Successfully Initialized in {}!", .{std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime)))});

    _ = run_symbol("ROOT-ALIGN");

    startTime = std.time.nanoTimestamp();

    while (vm_instance.?.inter_status.load(std.builtin.AtomicOrder.Acquire) == .in_progress) {}

    std.log.info("Karel's execution has finished in {}!", .{std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime)))});
}
