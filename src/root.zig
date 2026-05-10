const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const ProcessId = u32;

const macos = if (builtin.os.tag == .macos)
    @cImport({
        @cInclude("libproc.h");
        @cInclude("sys/proc_info.h");
        @cInclude("netinet/in.h");
    })
else
    struct {};

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

pub const Error = error{
    InvalidMethod,
    InvalidPort,
    NoProcessOnPort,
    UnsupportedPlatform,
};

pub const KillResult = struct {
    pids: []ProcessId,

    pub fn deinit(self: *KillResult, allocator: Allocator) void {
        allocator.free(self.pids);
        self.* = undefined;
    }
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
        .linux => killPortLinux(allocator, port, protocol),
        .macos => killPortMacos(allocator, port, protocol),
        .windows => killPortWindows(allocator, port, protocol),
        else => error.UnsupportedPlatform,
    };
}

fn killPortLinux(allocator: Allocator, port: u16, protocol: Protocol) !KillResult {
    var inodes = std.AutoHashMap(u64, void).init(allocator);
    defer inodes.deinit();

    switch (protocol) {
        .tcp => {
            try collectLinuxSocketInodes(allocator, "/proc/net/tcp", port, protocol, &inodes);
            try collectLinuxSocketInodes(allocator, "/proc/net/tcp6", port, protocol, &inodes);
        },
        .udp => {
            try collectLinuxSocketInodes(allocator, "/proc/net/udp", port, protocol, &inodes);
            try collectLinuxSocketInodes(allocator, "/proc/net/udp6", port, protocol, &inodes);
        },
    }

    if (inodes.count() == 0) return error.NoProcessOnPort;

    var pids = std.AutoHashMap(ProcessId, void).init(allocator);
    defer pids.deinit();

    try collectLinuxPidsForInodes(allocator, &inodes, &pids);
    if (pids.count() == 0) return error.NoProcessOnPort;

    var killed: std.ArrayList(ProcessId) = .empty;
    errdefer killed.deinit(allocator);

    var first_error: ?anyerror = null;
    var iterator = pids.keyIterator();
    while (iterator.next()) |pid| {
        terminatePosixProcess(pid.*) catch |err| {
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

fn terminatePosixProcess(pid: ProcessId) !void {
    if (pid > std.math.maxInt(std.posix.pid_t)) return error.ProcessNotFound;
    const posix_pid: std.posix.pid_t = @intCast(pid);
    try std.posix.kill(posix_pid, std.posix.SIG.KILL);
}

fn collectLinuxSocketInodes(
    allocator: Allocator,
    proc_net_path: []const u8,
    port: u16,
    protocol: Protocol,
    inodes: *std.AutoHashMap(u64, void),
) !void {
    const file = std.fs.openFileAbsolute(proc_net_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next();

    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue;

        const local_address = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const state = fields.next() orelse continue;

        if (protocol == .tcp and !std.mem.eql(u8, state, "0A")) continue;

        const local_port = parseProcNetPort(local_address) catch continue;
        if (local_port != port) continue;

        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;

        const inode_text = fields.next() orelse continue;
        const inode = std.fmt.parseUnsigned(u64, inode_text, 10) catch continue;
        try inodes.put(inode, {});
    }
}

fn collectLinuxPidsForInodes(
    allocator: Allocator,
    inodes: *const std.AutoHashMap(u64, void),
    pids: *std.AutoHashMap(ProcessId, void),
) !void {
    var proc = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer proc.close();

    var iterator = proc.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory and entry.kind != .unknown) continue;

        const parsed_pid = std.fmt.parseUnsigned(u32, entry.name, 10) catch continue;
        if (parsed_pid > std.math.maxInt(std.posix.pid_t)) continue;
        const pid: ProcessId = @intCast(parsed_pid);

        const fd_path = try std.fmt.allocPrint(allocator, "/proc/{s}/fd", .{entry.name});
        defer allocator.free(fd_path);

        var fd_dir = std.fs.openDirAbsolute(fd_path, .{ .iterate = true }) catch continue;
        defer fd_dir.close();

        if (try processHasSocketInode(fd_dir, inodes)) {
            try pids.put(pid, {});
        }
    }
}

fn processHasSocketInode(fd_dir: std.fs.Dir, inodes: *const std.AutoHashMap(u64, void)) !bool {
    var iterator = fd_dir.iterate();
    while (try iterator.next()) |entry| {
        var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const link = fd_dir.readLink(entry.name, &link_buffer) catch continue;
        const inode = parseSocketLink(link) orelse continue;

        if (inodes.contains(inode)) return true;
    }

    return false;
}

fn parseProcNetPort(local_address: []const u8) !u16 {
    const colon_index = std.mem.lastIndexOfScalar(u8, local_address, ':') orelse return error.InvalidPort;
    const port_hex = local_address[colon_index + 1 ..];
    if (port_hex.len == 0) return error.InvalidPort;

    return std.fmt.parseUnsigned(u16, port_hex, 16) catch return error.InvalidPort;
}

fn parseSocketLink(link: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, link, "socket:[")) return null;
    if (!std.mem.endsWith(u8, link, "]")) return null;

    return std.fmt.parseUnsigned(u64, link["socket:[".len .. link.len - 1], 10) catch null;
}

fn killPortMacos(allocator: Allocator, port: u16, protocol: Protocol) !KillResult {
    var pids = std.AutoHashMap(ProcessId, void).init(allocator);
    defer pids.deinit();

    try collectMacosPidsForPort(allocator, port, protocol, &pids);
    if (pids.count() == 0) return error.NoProcessOnPort;

    var killed: std.ArrayList(ProcessId) = .empty;
    errdefer killed.deinit(allocator);

    var first_error: ?anyerror = null;
    var iterator = pids.keyIterator();
    while (iterator.next()) |pid| {
        terminatePosixProcess(pid.*) catch |err| {
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

fn collectMacosPidsForPort(
    allocator: Allocator,
    port: u16,
    protocol: Protocol,
    matches: *std.AutoHashMap(ProcessId, void),
) !void {
    const pid_capacity_bytes = macos.proc_listpids(macos.PROC_ALL_PIDS, 0, null, 0);
    if (pid_capacity_bytes <= 0) return error.NoProcessOnPort;

    const pid_capacity = (@as(usize, @intCast(pid_capacity_bytes)) / @sizeOf(c_int)) + 128;
    const raw_pids = try allocator.alloc(c_int, pid_capacity);
    defer allocator.free(raw_pids);

    const pid_bytes = macos.proc_listpids(
        macos.PROC_ALL_PIDS,
        0,
        raw_pids.ptr,
        try bytesToCInt(raw_pids.len * @sizeOf(c_int)),
    );
    if (pid_bytes <= 0) return error.NoProcessOnPort;

    const pid_count = @min(@as(usize, @intCast(pid_bytes)) / @sizeOf(c_int), raw_pids.len);
    for (raw_pids[0..pid_count]) |raw_pid| {
        if (raw_pid <= 0) continue;

        const pid: ProcessId = @intCast(raw_pid);
        if (try macosProcessHasPort(allocator, raw_pid, port, protocol)) {
            try matches.put(pid, {});
        }
    }
}

fn macosProcessHasPort(allocator: Allocator, raw_pid: c_int, port: u16, protocol: Protocol) !bool {
    const fd_bytes_result = macos.proc_pidinfo(raw_pid, macos.PROC_PIDLISTFDS, 0, null, 0);
    if (fd_bytes_result <= 0) return false;

    const fd_capacity = @as(usize, @intCast(fd_bytes_result)) / @sizeOf(macos.struct_proc_fdinfo);
    if (fd_capacity == 0) return false;

    const fd_infos = try allocator.alloc(macos.struct_proc_fdinfo, fd_capacity);
    defer allocator.free(fd_infos);

    const fd_bytes = macos.proc_pidinfo(
        raw_pid,
        macos.PROC_PIDLISTFDS,
        0,
        fd_infos.ptr,
        try bytesToCInt(fd_infos.len * @sizeOf(macos.struct_proc_fdinfo)),
    );
    if (fd_bytes <= 0) return false;

    const fd_count = @min(@as(usize, @intCast(fd_bytes)) / @sizeOf(macos.struct_proc_fdinfo), fd_infos.len);
    for (fd_infos[0..fd_count]) |fd_info| {
        if (fd_info.proc_fdtype != macos.PROX_FDTYPE_SOCKET) continue;

        var socket_info: macos.struct_socket_fdinfo = undefined;
        const socket_bytes = macos.proc_pidfdinfo(
            raw_pid,
            fd_info.proc_fd,
            macos.PROC_PIDFDSOCKETINFO,
            &socket_info,
            @sizeOf(macos.struct_socket_fdinfo),
        );
        if (socket_bytes != @sizeOf(macos.struct_socket_fdinfo)) continue;

        if (macosSocketMatchesPort(socket_info, port, protocol)) return true;
    }

    return false;
}

fn macosSocketMatchesPort(socket_info: macos.struct_socket_fdinfo, port: u16, protocol: Protocol) bool {
    return switch (protocol) {
        .tcp => blk: {
            if (socket_info.psi.soi_kind != macos.SOCKINFO_TCP) break :blk false;
            if (socket_info.psi.soi_proto.pri_tcp.tcpsi_state != macos.TSI_S_LISTEN) break :blk false;

            break :blk macosPort(socket_info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport) == port;
        },
        .udp => blk: {
            if (socket_info.psi.soi_kind != macos.SOCKINFO_IN) break :blk false;
            if (socket_info.psi.soi_protocol != macos.IPPROTO_UDP) break :blk false;

            break :blk macosPort(socket_info.psi.soi_proto.pri_in.insi_lport) == port;
        },
    };
}

fn macosPort(network_order_port: c_int) u16 {
    const lower_bits: u16 = @intCast(@as(u32, @intCast(network_order_port)) & 0xffff);
    return std.mem.bigToNative(u16, lower_bits);
}

fn bytesToCInt(value: usize) !c_int {
    if (value > std.math.maxInt(c_int)) return error.Unexpected;
    return @intCast(value);
}

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

fn killPortWindows(allocator: Allocator, port: u16, protocol: Protocol) !KillResult {
    var pids = std.AutoHashMap(ProcessId, void).init(allocator);
    defer pids.deinit();

    switch (protocol) {
        .tcp => {
            try collectWindowsTcpPids(allocator, AF_INET, port, &pids);
            try collectWindowsTcp6Pids(allocator, AF_INET6, port, &pids);
        },
        .udp => {
            try collectWindowsUdpPids(allocator, AF_INET, port, &pids);
            try collectWindowsUdp6Pids(allocator, AF_INET6, port, &pids);
        },
    }

    if (pids.count() == 0) return error.NoProcessOnPort;

    var killed: std.ArrayList(ProcessId) = .empty;
    errdefer killed.deinit(allocator);

    var first_error: ?anyerror = null;
    var iterator = pids.keyIterator();
    while (iterator.next()) |pid| {
        terminateWindowsProcess(pid.*) catch |err| {
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

fn collectWindowsTcpPids(
    allocator: Allocator,
    address_family: windows.ULONG,
    port: u16,
    pids: *std.AutoHashMap(ProcessId, void),
) !void {
    const buffer = try getWindowsTcpTable(allocator, address_family);
    defer allocator.free(buffer);

    const count = windowsTableCount(buffer);
    const rows = windowsTableRows(MibTcpRowOwnerPid, buffer, count);
    for (rows) |row| {
        if (row.state == MIB_TCP_STATE_LISTEN and windowsPort(row.local_port) == port) {
            try pids.put(row.owning_pid, {});
        }
    }
}

fn collectWindowsTcp6Pids(
    allocator: Allocator,
    address_family: windows.ULONG,
    port: u16,
    pids: *std.AutoHashMap(ProcessId, void),
) !void {
    const buffer = try getWindowsTcpTable(allocator, address_family);
    defer allocator.free(buffer);

    const count = windowsTableCount(buffer);
    const rows = windowsTableRows(MibTcp6RowOwnerPid, buffer, count);
    for (rows) |row| {
        if (row.state == MIB_TCP_STATE_LISTEN and windowsPort(row.local_port) == port) {
            try pids.put(row.owning_pid, {});
        }
    }
}

fn collectWindowsUdpPids(
    allocator: Allocator,
    address_family: windows.ULONG,
    port: u16,
    pids: *std.AutoHashMap(ProcessId, void),
) !void {
    const buffer = try getWindowsUdpTable(allocator, address_family);
    defer allocator.free(buffer);

    const count = windowsTableCount(buffer);
    const rows = windowsTableRows(MibUdpRowOwnerPid, buffer, count);
    for (rows) |row| {
        if (windowsPort(row.local_port) == port) {
            try pids.put(row.owning_pid, {});
        }
    }
}

fn collectWindowsUdp6Pids(
    allocator: Allocator,
    address_family: windows.ULONG,
    port: u16,
    pids: *std.AutoHashMap(ProcessId, void),
) !void {
    const buffer = try getWindowsUdpTable(allocator, address_family);
    defer allocator.free(buffer);

    const count = windowsTableCount(buffer);
    const rows = windowsTableRows(MibUdp6RowOwnerPid, buffer, count);
    for (rows) |row| {
        if (windowsPort(row.local_port) == port) {
            try pids.put(row.owning_pid, {});
        }
    }
}

fn getWindowsTcpTable(allocator: Allocator, address_family: windows.ULONG) ![]align(4) u8 {
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

fn getWindowsUdpTable(allocator: Allocator, address_family: windows.ULONG) ![]align(4) u8 {
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

fn windowsTableCount(buffer: []align(4) const u8) usize {
    const count: *align(4) const windows.DWORD = @ptrCast(buffer.ptr);
    return count.*;
}

fn windowsTableRows(comptime Row: type, buffer: []align(4) const u8, count: usize) []align(4) const Row {
    const rows_ptr: [*]align(4) const Row = @ptrCast(buffer[@sizeOf(windows.DWORD)..].ptr);
    return rows_ptr[0..count];
}

fn windowsPort(network_order_port: windows.DWORD) u16 {
    const lower_bits: u16 = @intCast(network_order_port & 0xffff);
    return std.mem.bigToNative(u16, lower_bits);
}

fn terminateWindowsProcess(pid: ProcessId) !void {
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

test parseProcNetPort {
    try std.testing.expectEqual(@as(u16, 8080), try parseProcNetPort("0100007F:1F90"));
    try std.testing.expectEqual(@as(u16, 5432), try parseProcNetPort("00000000000000000000000000000000:1538"));
}

test parseSocketLink {
    try std.testing.expectEqual(@as(?u64, 12345), parseSocketLink("socket:[12345]"));
    try std.testing.expectEqual(@as(?u64, null), parseSocketLink("anon_inode:[eventpoll]"));
}

test windowsPort {
    try std.testing.expectEqual(@as(u16, 8080), windowsPort(0x901F));
    try std.testing.expectEqual(@as(u16, 5353), windowsPort(0xE914));
}

test macosPort {
    try std.testing.expectEqual(@as(u16, 8080), macosPort(0x901F));
    try std.testing.expectEqual(@as(u16, 5353), macosPort(0xE914));
}
