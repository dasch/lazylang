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

    // Create JSON-RPC module for LSP
    const json_rpc_module = b.addModule("json_rpc", .{
        .root_source_file = b.path("src/json_rpc.zig"),
    });

    // Create LSP module
    const lsp_module = b.createModule(.{
        .root_source_file = b.path("src/lsp.zig"),
    });
    lsp_module.addImport("json_rpc", json_rpc_module);
    lsp_module.addImport("evaluator", evaluator_module);

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

    // Create LSP server executable
    const lsp_exe_module = b.createModule(.{
        .root_source_file = b.path("src/lsp_main.zig"),
        .target = target,
        .optimize = optimize,
    });

    lsp_exe_module.addImport("lsp", lsp_module);
    lsp_exe_module.addImport("json_rpc", json_rpc_module);
    lsp_exe_module.addImport("evaluator", evaluator_module);

    const lsp_exe = b.addExecutable(.{
        .name = "lazylang-lsp",
        .root_module = lsp_exe_module,
    });

    b.installArtifact(lsp_exe);

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

    // Eval test files
    const eval_test_files = [_][]const u8{
        "tests/eval/arithmetic_test.zig",
        "tests/eval/functions_test.zig",
        "tests/eval/arrays_test.zig",
        "tests/eval/objects_test.zig",
        "tests/eval/imports_test.zig",
        "tests/eval/strings_test.zig",
        "tests/eval/tuples_test.zig",
        "tests/eval/booleans_test.zig",
        "tests/eval/null_test.zig",
        "tests/eval/conditionals_test.zig",
        "tests/eval/variables_test.zig",
        "tests/eval/destructuring_test.zig",
        "tests/eval/pattern_matching_test.zig",
        "tests/eval/where_test.zig",
        "tests/eval/do_test.zig",
        "tests/eval/symbols_test.zig",
    };

    // Examples test module
    const examples_test_module = b.createModule(.{
        .root_source_file = b.path("tests/examples_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    examples_test_module.addImport("cli", cli_module);
    examples_test_module.addImport("evaluator", evaluator_module);

    const examples_tests = b.addTest(.{
        .root_module = examples_test_module,
    });

    // LSP test module
    const lsp_test_module = b.createModule(.{
        .root_source_file = b.path("tests/lsp_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    lsp_test_module.addImport("lsp", lsp_module);
    lsp_test_module.addImport("json_rpc", json_rpc_module);
    lsp_test_module.addImport("evaluator", evaluator_module);

    const lsp_tests = b.addTest(.{
        .root_module = lsp_test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(examples_tests).step);
    test_step.dependOn(&b.addRunArtifact(lsp_tests).step);

    for (eval_test_files) |test_file| {
        const eval_test_module = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });

        eval_test_module.addImport("cli", cli_module);
        eval_test_module.addImport("evaluator", evaluator_module);

        const eval_tests = b.addTest(.{
            .root_module = eval_test_module,
        });

        test_step.dependOn(&b.addRunArtifact(eval_tests).step);
    }
}
