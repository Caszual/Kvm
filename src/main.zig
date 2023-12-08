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

pub const KvmResult = enum(c_int) {
    success = 0,
    unknown_error, // used for system errors like out of memory, when unknown_error is returned as result the actual error will be printed to the teminal
    not_initialized, // unless in init(), then equals to .already_initialized
    file_not_found,
    compilation_error, // error will be printed to the terminal also
    state_not_valid,
    symbol_not_found,
    step_out_of_bounds,
    pickup_zero_flags,
    place_max_flags,
    stop_encountered,
};

// loading and managment

// initializes the library
export fn init() callconv(.C) KvmResult {
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
export fn load(file_path_arg: [*c]const u8) callconv(.C) KvmResult {
    const file_path: []const u8 = std.mem.span(file_path_arg);
    if (vm_instance != null) {
        vm_instance.?.load(file_path) catch |err| {
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
export fn load_world() callconv(.C) KvmResult {
    
    if (vm_instance) |vm| {
        vm_instance.?.load_world();
        _ = vm;
        // vm.setKarel();
        // vm.setCity();

        return .success;
    } else return .not_initialized;
}

// prints every symbol from the bcode currentrly in memory
export fn dump_loaded() callconv(.C) KvmResult {
    if (vm_instance) |vm| {
        vm.dump_loaded_symbols();

        return .success;
    } else return .not_initialized;
}

// execution

// looks up and executes a symbol from the bcode in currently memory
//
// symbol arg *must* be a utf-8 encoded null terminated string
export fn run_symbol(sym: [*c]const u8) callconv(.C) KvmResult {
    const sym_slice: []const u8 = std.mem.span(sym);

    if (vm_instance != null) {
        var startTime = std.time.nanoTimestamp();

        const func_count = vm_instance.?.run_symbol(sym_slice) catch |err| {
            std.log.err("An error occurred while executing Karel's code! error: {}", .{err});

            return switch (err) {
                error.KvmStateNotValid => .state_not_valid,

                error.SymbolNotFound => .symbol_not_found,

                error.StepOutOfBounds => .step_out_of_bounds,

                error.PickupZeroFlags => .pickup_zero_flags,

                error.PlaceMaxFlags => .place_max_flags,

                error.StopEncountered => .stop_encountered,

                else => .unknown_error,
            };
        };

        std.log.info("Karel's execution of {} funcs has finished in {}!", .{ func_count, std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime))) });

        return .success;
    } else return .not_initialized;
}

pub fn main() !void {
    var startTime = std.time.nanoTimestamp();

    var vm = kvm.Kvm.init(std.heap.page_allocator) catch |err| {
        std.log.err("Kvm Failed to Initialize, error: {}", .{err});
        return;
    };
    defer vm.deinit();

    try vm.load("test.kl");
    vm.load_world();

    std.log.info("Kvm Successfully Initialized in {}!", .{std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime)))});

    startTime = std.time.nanoTimestamp();

    const func_count = vm.run_symbol("TEST") catch |err| {
        std.log.err("An error occurred while executing Karel's code! error: {}", .{err});
        return;
    };

    std.log.info("Karel's execution of {} funcs has finished in {}!", .{ func_count, std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime))) });
}
