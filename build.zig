const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lazylang",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const cli_module = b.addModule("cli", .{
        .root_source_file = .{ .path = "src/cli.zig" },
    });

    exe.root_module.addImport("cli", cli_module);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the lazylang CLI");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "tests/cli_test.zig" },
        .target = target,
        .optimize = optimize,
    });

    tests.root_module.addImport("cli", cli_module);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const eval_tests = b.addTest(.{
        .root_source_file = .{ .path = "tests/eval_test.zig" },
        .target = target,
        .optimize = optimize,
    });

    test_step.dependOn(&b.addRunArtifact(eval_tests).step);
}
