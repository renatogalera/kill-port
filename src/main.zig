const std = @import("std");
const kill_port = @import("kill_port");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

const CliError = Allocator.Error || error{
    InvalidMethod,
    InvalidPort,
    MissingPort,
    MissingValue,
    UnknownOption,
};

const Options = struct {
    ports: std.ArrayList(u16) = .empty,
    protocol: kill_port.Protocol = .tcp,
    verbose: bool = false,
    help: bool = false,
    version: bool = false,

    fn deinit(self: *Options, allocator: Allocator) void {
        self.ports.deinit(allocator);
        self.* = undefined;
    }
};

pub fn main() void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa_state.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = run(allocator, stdout, stderr) catch |err| blk: {
        stderr.print("kill-port: {s}\n", .{@errorName(err)}) catch {};
        break :blk 1;
    };

    stdout.flush() catch {};
    stderr.flush() catch {};
    _ = gpa_state.deinit();
    std.process.exit(exit_code);
}

fn run(allocator: Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    var args_iterator = try std.process.argsWithAllocator(allocator);
    defer args_iterator.deinit();

    _ = args_iterator.next();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    while (args_iterator.next()) |arg| {
        try args.append(allocator, arg);
    }

    var options = parseArgs(allocator, args.items) catch |err| {
        try stderr.print("error: {s}\n\n", .{cliErrorMessage(err)});
        try printUsage(stderr);
        return 2;
    };
    defer options.deinit(allocator);

    if (options.help) {
        try printUsage(stdout);
        return 0;
    }

    if (options.version) {
        try stdout.print("kill-port {s}\n", .{build_options.version});
        return 0;
    }

    var failed = false;
    for (options.ports.items) |port| {
        var result = kill_port.killPort(allocator, port, options.protocol) catch |err| {
            try stdout.print("Could not kill process on port {}. {s}.\n", .{ port, killErrorMessage(err) });
            failed = true;
            continue;
        };
        defer result.deinit(allocator);

        try stdout.print("Process on port {} killed\n", .{port});
        if (options.verbose) {
            try stdout.print("method: {s}\n", .{options.protocol.name()});
            try stdout.print("pids:", .{});
            for (result.pids) |pid| {
                try stdout.print(" {}", .{pid});
            }
            try stdout.print("\n", .{});
        }
    }

    return if (failed) 1 else 0;
}

fn parseArgs(allocator: Allocator, args: []const []const u8) CliError!Options {
    var options = Options{};
    errdefer options.deinit(allocator);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            options.version = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            options.verbose = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            try appendPorts(allocator, &options.ports, args[index]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--port=")) {
            try appendPorts(allocator, &options.ports, arg["--port=".len..]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--method") or std.mem.eql(u8, arg, "-m")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.protocol = kill_port.parseProtocol(args[index]) catch return error.InvalidMethod;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--method=")) {
            options.protocol = kill_port.parseProtocol(arg["--method=".len..]) catch return error.InvalidMethod;
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            while (index < args.len) : (index += 1) {
                try appendPorts(allocator, &options.ports, args[index]);
            }
            break;
        }

        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;

        try appendPorts(allocator, &options.ports, arg);
    }

    if (!options.help and !options.version and options.ports.items.len == 0) {
        return error.MissingPort;
    }

    return options;
}

fn appendPorts(allocator: Allocator, ports: *std.ArrayList(u16), value: []const u8) CliError!void {
    var parts = std.mem.splitScalar(u8, value, ',');
    var found = false;

    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidPort;
        try ports.append(allocator, kill_port.parsePort(part) catch return error.InvalidPort);
        found = true;
    }

    if (!found) return error.InvalidPort;
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  kill-port [options] <ports...>
        \\  kill-port --port <port[,port...]> [--method tcp|udp]
        \\
        \\Options:
        \\  -p, --port <ports>      Port or comma-separated ports to kill
        \\  -m, --method <method>   Protocol to match: tcp or udp (default: tcp)
        \\  -v, --verbose           Print killed PIDs
        \\  -h, --help              Show this help
        \\  -V, --version           Show version
        \\
        \\Examples:
        \\  kill-port 8080
        \\  kill-port 8080 3000 5000
        \\  kill-port --port 8080,3000 --method udp
        \\
    );
}

fn cliErrorMessage(err: CliError) []const u8 {
    return switch (err) {
        error.InvalidMethod => "invalid method; use tcp or udp",
        error.InvalidPort => "invalid port number provided",
        error.MissingPort => "no port provided",
        error.MissingValue => "missing value after option",
        error.OutOfMemory => "out of memory",
        error.UnknownOption => "unknown option",
    };
}

fn killErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NoProcessOnPort => "No process running on port",
        error.UnsupportedPlatform => "Unsupported platform; this native implementation currently supports Linux",
        error.PermissionDenied => "Permission denied",
        error.ProcessNotFound => "Process disappeared before it could be killed",
        else => @errorName(err),
    };
}

test parseArgs {
    const allocator = std.testing.allocator;

    var first = try parseArgs(allocator, &.{ "8080", "3000" });
    defer first.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), first.ports.items.len);
    try std.testing.expectEqual(@as(u16, 8080), first.ports.items[0]);
    try std.testing.expectEqual(@as(u16, 3000), first.ports.items[1]);

    var second = try parseArgs(allocator, &.{ "--port", "8080,5000", "--method", "udp", "--verbose" });
    defer second.deinit(allocator);
    try std.testing.expectEqual(kill_port.Protocol.udp, second.protocol);
    try std.testing.expect(second.verbose);
    try std.testing.expectEqual(@as(usize, 2), second.ports.items.len);
}

test "parseArgs rejects invalid input" {
    try std.testing.expectError(error.MissingPort, parseArgs(std.testing.allocator, &.{}));
    try std.testing.expectError(error.InvalidPort, parseArgs(std.testing.allocator, &.{"70000"}));
    try std.testing.expectError(error.InvalidMethod, parseArgs(std.testing.allocator, &.{ "--method", "icmp", "8080" }));
    try std.testing.expectError(error.UnknownOption, parseArgs(std.testing.allocator, &.{ "--wat", "8080" }));
}
