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

    var vm = kvm.Kvm.init(std.heap.page_allocator, "test.kl") catch |err| {
        std.log.err("Kvm Failed to Initialize, error: {}", .{err});
        return;
    };
    defer vm.deinit();

    vm.dump_loaded_symbols();

    std.log.info("Kvm Successfully Initialized in {}!", .{std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime)))});

    startTime = std.time.nanoTimestamp();

    const func_count = vm.run_symbol("TEST") catch |err| {
        std.log.err("An error occurred while executing Karel's code! error: {}", .{err});
        return;
    };

    std.log.info("Karel's execution of {} funcs has finished in {}!", .{ func_count, std.fmt.fmtDuration(@as(u64, @intCast(std.time.nanoTimestamp() - startTime))) });
}
