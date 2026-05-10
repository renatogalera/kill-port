const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ProcessId = u32;

pub const Protocol = enum {
    tcp,
    udp,

    pub fn name(self: Protocol) []const u8 {
        return switch (self) {
            .tcp => "tcp",
            .udp => "udp",
        };
    }
};

pub const KillResult = struct {
    pids: []ProcessId,

    pub fn deinit(self: *KillResult, allocator: Allocator) void {
        allocator.free(self.pids);
        self.* = undefined;
    }
};

pub fn terminatePosixProcess(pid: ProcessId) !void {
    if (pid > std.math.maxInt(std.posix.pid_t)) return error.ProcessNotFound;
    const posix_pid: std.posix.pid_t = @intCast(pid);
    try std.posix.kill(posix_pid, std.posix.SIG.KILL);
}

pub fn killCollectedPids(
    allocator: Allocator,
    pids: *const std.AutoHashMap(ProcessId, void),
    terminate: fn (ProcessId) anyerror!void,
) !KillResult {
    if (pids.count() == 0) return error.NoProcessOnPort;

    var killed: std.ArrayList(ProcessId) = .empty;
    errdefer killed.deinit(allocator);

    var first_error: ?anyerror = null;
    var iterator = pids.keyIterator();
    while (iterator.next()) |pid| {
        terminate(pid.*) catch |err| {
            if (first_error == null) first_error = err;
            continue;
        };

        try killed.append(allocator, pid.*);
    }

    if (killed.items.len == 0) {
        return first_error orelse error.NoProcessOnPort;
    }

    return .{ .pids = try killed.toOwnedSlice(allocator) };
}
