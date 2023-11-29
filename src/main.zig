const std = @import("std");
const kvm = @import("kvm.zig");

const builtin = @import("builtin");

// compile with -Doptimize=Debug for execution status
// compile with -Doptimize=ReleaseFast for speed

pub const std_options = struct {
    pub const log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast => .info,
        .ReleaseSmall => .err,
    };
};

pub fn main() !void {
    std.log.info("Initializing Kvm...", .{});

    var startTime = std.time.nanoTimestamp();

    var vm = kvm.Kvm.init(std.heap.page_allocator, "KPUutf8.kl") catch |err| {
        std.log.err("Kvm Failed to Initialize, error: {}", .{err});
        return;
    };
    defer vm.deinit();

    vm.dump_loaded_symbols();

    std.log.info("Kvm Successfully Initialized in {d:.3} us!", .{@as(f32, @floatFromInt(std.time.nanoTimestamp() - startTime)) * 0.001});

    startTime = std.time.nanoTimestamp();

    const func_count = vm.run_symbol("TEST") catch |err| {
        std.log.err("An error occurred while executing Karel's code! error: {}", .{err});
        return;
    };

    if ((std.time.nanoTimestamp() - startTime) < 1_000_000) {
        std.log.info("Karel's execution of {} funcs has finished in {d:.3} us!", .{ func_count, @as(f32, @floatFromInt(std.time.nanoTimestamp() - startTime)) * 0.001 });
    } else {
        std.log.info("Karel's execution of {} funcs has finished in {d:.3} ms!", .{ func_count, @as(f32, @floatFromInt(std.time.nanoTimestamp() - startTime)) * 0.000001 });
    }
}
