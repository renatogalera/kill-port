const std = @import("std");
const package = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = normalizeVersion(b.option([]const u8, "version", "Version shown by kill-port --version") orelse package.version);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const lib = b.addModule("kill_port", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "kill_port", .module = lib },
        },
    });
    exe_module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "kill-port",
        .root_module = exe_module,
    });
    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("iphlpapi");
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run kill-port");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = lib,
    });
    if (target.result.os.tag == .windows) {
        lib_tests.linkSystemLibrary("iphlpapi");
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    if (target.result.os.tag == .windows) {
        exe_tests.linkSystemLibrary("iphlpapi");
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}

fn normalizeVersion(version: []const u8) []const u8 {
    if (std.mem.startsWith(u8, version, "v") and version.len > 1) {
        return version[1..];
    }

    return version;
}
