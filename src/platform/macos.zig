const std = @import("std");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const KillResult = shared.KillResult;
const ProcessId = shared.ProcessId;
const Protocol = shared.Protocol;

const macos = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
    @cInclude("netinet/in.h");
});

pub fn killPort(allocator: Allocator, port: u16, protocol: Protocol) !KillResult {
    var pids = std.AutoHashMap(ProcessId, void).init(allocator);
    defer pids.deinit();

    try collectPidsForPort(allocator, port, protocol, &pids);
    return shared.killCollectedPids(allocator, &pids, shared.terminatePosixProcess);
}

fn collectPidsForPort(
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
        if (try processHasPort(allocator, raw_pid, port, protocol)) {
            try matches.put(pid, {});
        }
    }
}

fn processHasPort(allocator: Allocator, raw_pid: c_int, port: u16, protocol: Protocol) !bool {
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

        if (socketMatchesPort(socket_info, port, protocol)) return true;
    }

    return false;
}

fn socketMatchesPort(socket_info: macos.struct_socket_fdinfo, port: u16, protocol: Protocol) bool {
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

test macosPort {
    try std.testing.expectEqual(@as(u16, 8080), macosPort(0x901F));
    try std.testing.expectEqual(@as(u16, 5353), macosPort(0xE914));
}
