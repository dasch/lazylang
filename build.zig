const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create shared modules
    const cli_module = b.addModule("cli", .{
        .root_source_file = b.path("src/cli.zig"),
    });

    const evaluator_module = b.addModule("evaluator", .{
        .root_source_file = b.path("src/eval.zig"),
    });

    // Create executable module
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_module.addImport("cli", cli_module);
    exe_module.addImport("evaluator", evaluator_module);

    const exe = b.addExecutable(.{
        .name = "lazylang",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the lazylang CLI");
    run_step.dependOn(&run_cmd.step);

    // Create test modules
    const cli_test_module = b.createModule(.{
        .root_source_file = b.path("tests/cli_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    cli_test_module.addImport("cli", cli_module);
    cli_test_module.addImport("evaluator", evaluator_module);

    const tests = b.addTest(.{
        .root_module = cli_test_module,
    });

    const eval_test_module = b.createModule(.{
        .root_source_file = b.path("tests/eval_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    eval_test_module.addImport("cli", cli_module);
    eval_test_module.addImport("evaluator", evaluator_module);

    const eval_tests = b.addTest(.{
        .root_module = eval_test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(eval_tests).step);
}
