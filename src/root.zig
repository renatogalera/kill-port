const std = @import("std");
const builtin = @import("builtin");
const shared = @import("platform/shared.zig");

const Allocator = std.mem.Allocator;
pub const Protocol = shared.Protocol;
pub const KillResult = shared.KillResult;

pub const Error = error{
    InvalidMethod,
    InvalidPort,
    NoProcessOnPort,
    UnsupportedPlatform,
};

pub fn parseProtocol(value: []const u8) Error!Protocol {
    if (std.ascii.eqlIgnoreCase(value, "tcp")) return .tcp;
    if (std.ascii.eqlIgnoreCase(value, "udp")) return .udp;
    return error.InvalidMethod;
}

pub fn parsePort(value: []const u8) Error!u16 {
    if (value.len == 0) return error.InvalidPort;

    const parsed = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidPort;
    if (parsed == 0 or parsed > std.math.maxInt(u16)) return error.InvalidPort;

    return @intCast(parsed);
}

pub fn killPort(allocator: Allocator, port: u16, protocol: Protocol) !KillResult {
    return switch (builtin.os.tag) {
        .linux => @import("platform/linux.zig").killPort(allocator, port, protocol),
        .macos => @import("platform/macos.zig").killPort(allocator, port, protocol),
        .windows => @import("platform/windows.zig").killPort(allocator, port, protocol),
        else => error.UnsupportedPlatform,
    };
}

test parseProtocol {
    try std.testing.expectEqual(Protocol.tcp, try parseProtocol("tcp"));
    try std.testing.expectEqual(Protocol.udp, try parseProtocol("UDP"));
    try std.testing.expectError(error.InvalidMethod, parseProtocol("icmp"));
}

test parsePort {
    try std.testing.expectEqual(@as(u16, 8080), try parsePort("8080"));
    try std.testing.expectError(error.InvalidPort, parsePort(""));
    try std.testing.expectError(error.InvalidPort, parsePort("0"));
    try std.testing.expectError(error.InvalidPort, parsePort("65536"));
}
