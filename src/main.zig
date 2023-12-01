const std = @import("std");
const kvm = @import("kvm.zig");

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

export fn init() callconv(.C) bool {
    std.log.info("Initializing Kvm...", .{});

    if (vm_instance != null) return false;

    vm_instance = kvm.Kvm.init(std.heap.page_allocator) catch |err| {
        std.log.err("Kvm Failed to Initialize, error: {}", .{err});
        return false;
    };

    return true;
}

export fn deinit() callconv(.C) void {
    vm_instance.?.deinit();
}

export fn load() callconv(.C) bool {
    if (vm_instance == null) {
        vm_instance.?.load("temp.kl") catch |err| {
            std.log.err("error while compiling karel-lang: {}", .{err});
        };

        return true;
    } else return false;
}

// TODO: world load
export fn load_world() callconv(.C) bool {
    if (vm_instance) |vm| {
        _ = vm;
        // vm.setKarel();
        // vm.setCity();

        return true;
    } else return false;
}

export fn dump_loaded() callconv(.C) bool {
    if (vm_instance) |vm| {
        vm.dump_loaded_symbols();

        return true;
    } else return false;
}

export fn run_symbol(sym: [*c]const u8) bool {
    const sym_slice: [:0]const u8 = std.mem.span(sym);

    if (vm_instance == null) {
        var startTime = std.time.nanoTimestamp();

        const func_count = vm_instance.?.run_symbol(sym_slice) catch |err| {
            std.log.err("An error occurred while executing Karel's code! error: {}", .{err});
            return false;
        };

        std.log.info("Karel's execution of {} funcs has finished in {}!", .{ func_count, std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime))) });

        return true;
    } else return false;
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
