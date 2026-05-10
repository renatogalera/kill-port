const std = @import("std");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const KillResult = shared.KillResult;
const ProcessId = shared.ProcessId;
const Protocol = shared.Protocol;
const windows = std.os.windows;

const AF_INET = windows.ws2_32.AF.INET;
const AF_INET6 = windows.ws2_32.AF.INET6;
const ERROR_INSUFFICIENT_BUFFER = 122;
const MIB_TCP_STATE_LISTEN = 2;
const PROCESS_TERMINATE = 0x0001;
const TCP_TABLE_OWNER_PID_ALL = 5;
const UDP_TABLE_OWNER_PID = 1;

const MibTcpRowOwnerPid = extern struct {
    state: windows.DWORD,
    local_addr: windows.DWORD,
    local_port: windows.DWORD,
    remote_addr: windows.DWORD,
    remote_port: windows.DWORD,
    owning_pid: windows.DWORD,
};

const MibTcp6RowOwnerPid = extern struct {
    local_addr: [16]u8,
    local_scope_id: windows.DWORD,
    local_port: windows.DWORD,
    remote_addr: [16]u8,
    remote_scope_id: windows.DWORD,
    remote_port: windows.DWORD,
    state: windows.DWORD,
    owning_pid: windows.DWORD,
};

const MibUdpRowOwnerPid = extern struct {
    local_addr: windows.DWORD,
    local_port: windows.DWORD,
    owning_pid: windows.DWORD,
};

const MibUdp6RowOwnerPid = extern struct {
    local_addr: [16]u8,
    local_scope_id: windows.DWORD,
    local_port: windows.DWORD,
    owning_pid: windows.DWORD,
};

extern "iphlpapi" fn GetExtendedTcpTable(
    tcp_table: ?*anyopaque,
    size_pointer: *windows.ULONG,
    order: windows.BOOL,
    address_family: windows.ULONG,
    table_class: c_int,
    reserved: windows.ULONG,
) callconv(.winapi) windows.ULONG;

extern "iphlpapi" fn GetExtendedUdpTable(
    udp_table: ?*anyopaque,
    size_pointer: *windows.ULONG,
    order: windows.BOOL,
    address_family: windows.ULONG,
    table_class: c_int,
    reserved: windows.ULONG,
) callconv(.winapi) windows.ULONG;

extern "kernel32" fn OpenProcess(
    desired_access: windows.DWORD,
    inherit_handle: windows.BOOL,
    process_id: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

pub fn killPort(allocator: Allocator, port: u16, protocol: Protocol) !KillResult {
    var pids = std.AutoHashMap(ProcessId, void).init(allocator);
    defer pids.deinit();

    switch (protocol) {
        .tcp => {
            try collectTcpPids(allocator, AF_INET, port, &pids);
            try collectTcp6Pids(allocator, AF_INET6, port, &pids);
        },
        .udp => {
            try collectUdpPids(allocator, AF_INET, port, &pids);
            try collectUdp6Pids(allocator, AF_INET6, port, &pids);
        },
    }

    return shared.killCollectedPids(allocator, &pids, terminateProcess);
}

fn collectTcpPids(
    allocator: Allocator,
    address_family: windows.ULONG,
    port: u16,
    pids: *std.AutoHashMap(ProcessId, void),
) !void {
    const buffer = try getTcpTable(allocator, address_family);
    defer allocator.free(buffer);

    const count = tableCount(buffer);
    const rows = tableRows(MibTcpRowOwnerPid, buffer, count);
    for (rows) |row| {
        if (row.state == MIB_TCP_STATE_LISTEN and windowsPort(row.local_port) == port) {
            try pids.put(row.owning_pid, {});
        }
    }
}

fn collectTcp6Pids(
    allocator: Allocator,
    address_family: windows.ULONG,
    port: u16,
    pids: *std.AutoHashMap(ProcessId, void),
) !void {
    const buffer = try getTcpTable(allocator, address_family);
    defer allocator.free(buffer);

    const count = tableCount(buffer);
    const rows = tableRows(MibTcp6RowOwnerPid, buffer, count);
    for (rows) |row| {
        if (row.state == MIB_TCP_STATE_LISTEN and windowsPort(row.local_port) == port) {
            try pids.put(row.owning_pid, {});
        }
    }
}

fn collectUdpPids(
    allocator: Allocator,
    address_family: windows.ULONG,
    port: u16,
    pids: *std.AutoHashMap(ProcessId, void),
) !void {
    const buffer = try getUdpTable(allocator, address_family);
    defer allocator.free(buffer);

    const count = tableCount(buffer);
    const rows = tableRows(MibUdpRowOwnerPid, buffer, count);
    for (rows) |row| {
        if (windowsPort(row.local_port) == port) {
            try pids.put(row.owning_pid, {});
        }
    }
}

fn collectUdp6Pids(
    allocator: Allocator,
    address_family: windows.ULONG,
    port: u16,
    pids: *std.AutoHashMap(ProcessId, void),
) !void {
    const buffer = try getUdpTable(allocator, address_family);
    defer allocator.free(buffer);

    const count = tableCount(buffer);
    const rows = tableRows(MibUdp6RowOwnerPid, buffer, count);
    for (rows) |row| {
        if (windowsPort(row.local_port) == port) {
            try pids.put(row.owning_pid, {});
        }
    }
}

fn getTcpTable(allocator: Allocator, address_family: windows.ULONG) ![]align(4) u8 {
    var size: windows.ULONG = 0;
    const first_result = GetExtendedTcpTable(null, &size, windows.FALSE, address_family, TCP_TABLE_OWNER_PID_ALL, 0);
    if (first_result != ERROR_INSUFFICIENT_BUFFER) {
        try windowsApiError(first_result);
        return error.NoProcessOnPort;
    }

    const buffer = try allocator.alignedAlloc(u8, .@"4", size);
    errdefer allocator.free(buffer);

    const second_result = GetExtendedTcpTable(buffer.ptr, &size, windows.FALSE, address_family, TCP_TABLE_OWNER_PID_ALL, 0);
    if (second_result != 0) {
        try windowsApiError(second_result);
        return error.NoProcessOnPort;
    }

    return buffer;
}

fn getUdpTable(allocator: Allocator, address_family: windows.ULONG) ![]align(4) u8 {
    var size: windows.ULONG = 0;
    const first_result = GetExtendedUdpTable(null, &size, windows.FALSE, address_family, UDP_TABLE_OWNER_PID, 0);
    if (first_result != ERROR_INSUFFICIENT_BUFFER) {
        try windowsApiError(first_result);
        return error.NoProcessOnPort;
    }

    const buffer = try allocator.alignedAlloc(u8, .@"4", size);
    errdefer allocator.free(buffer);

    const second_result = GetExtendedUdpTable(buffer.ptr, &size, windows.FALSE, address_family, UDP_TABLE_OWNER_PID, 0);
    if (second_result != 0) {
        try windowsApiError(second_result);
        return error.NoProcessOnPort;
    }

    return buffer;
}

fn tableCount(buffer: []align(4) const u8) usize {
    const count: *align(4) const windows.DWORD = @ptrCast(buffer.ptr);
    return count.*;
}

fn tableRows(comptime Row: type, buffer: []align(4) const u8, count: usize) []align(4) const Row {
    const rows_ptr: [*]align(4) const Row = @ptrCast(buffer[@sizeOf(windows.DWORD)..].ptr);
    return rows_ptr[0..count];
}

fn windowsPort(network_order_port: windows.DWORD) u16 {
    const lower_bits: u16 = @intCast(network_order_port & 0xffff);
    return std.mem.bigToNative(u16, lower_bits);
}

fn terminateProcess(pid: ProcessId) !void {
    const handle = OpenProcess(PROCESS_TERMINATE, windows.FALSE, pid) orelse {
        return switch (windows.GetLastError()) {
            .ACCESS_DENIED => error.PermissionDenied,
            .INVALID_PARAMETER => error.ProcessNotFound,
            else => error.Unexpected,
        };
    };
    defer windows.CloseHandle(handle);

    try windows.TerminateProcess(handle, 1);
}

fn windowsApiError(result: windows.ULONG) !void {
    return switch (result) {
        0 => {},
        @as(windows.ULONG, @intFromEnum(windows.Win32Error.ACCESS_DENIED)) => error.PermissionDenied,
        else => error.Unexpected,
    };
}

test windowsPort {
    try std.testing.expectEqual(@as(u16, 8080), windowsPort(0x901F));
    try std.testing.expectEqual(@as(u16, 5353), windowsPort(0xE914));
}
