const std = @import("std");
const shared = @import("shared.zig");

const Allocator = std.mem.Allocator;
const KillResult = shared.KillResult;
const ProcessId = shared.ProcessId;
const Protocol = shared.Protocol;

pub fn killPort(allocator: Allocator, port: u16, protocol: Protocol) !KillResult {
    var inodes = std.AutoHashMap(u64, void).init(allocator);
    defer inodes.deinit();

    switch (protocol) {
        .tcp => {
            try collectSocketInodes(allocator, "/proc/net/tcp", port, protocol, &inodes);
            try collectSocketInodes(allocator, "/proc/net/tcp6", port, protocol, &inodes);
        },
        .udp => {
            try collectSocketInodes(allocator, "/proc/net/udp", port, protocol, &inodes);
            try collectSocketInodes(allocator, "/proc/net/udp6", port, protocol, &inodes);
        },
    }

    if (inodes.count() == 0) return error.NoProcessOnPort;

    var pids = std.AutoHashMap(ProcessId, void).init(allocator);
    defer pids.deinit();

    try collectPidsForInodes(allocator, &inodes, &pids);
    return shared.killCollectedPids(allocator, &pids, shared.terminatePosixProcess);
}

fn collectSocketInodes(
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

fn collectPidsForInodes(
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

test parseProcNetPort {
    try std.testing.expectEqual(@as(u16, 8080), try parseProcNetPort("0100007F:1F90"));
    try std.testing.expectEqual(@as(u16, 5432), try parseProcNetPort("00000000000000000000000000000000:1538"));
}

test parseSocketLink {
    try std.testing.expectEqual(@as(?u64, 12345), parseSocketLink("socket:[12345]"));
    try std.testing.expectEqual(@as(?u64, null), parseSocketLink("anon_inode:[eventpoll]"));
}
