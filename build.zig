const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add a debug option for release builds
    const debug_info = b.option(bool, "debug-info", "Include debug information in release builds") orelse false;

    // Create a modified optimize option that includes debug info when requested
    const effective_optimize = if (debug_info and optimize == .ReleaseFast)
        .ReleaseFast
    else
        optimize;

    const coyote_mod = b.createModule(.{
        .root_source_file = b.path("src/coyote.zig"),
        .target = target,
        .optimize = effective_optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/fruits.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "coyote-ecs", .module = coyote_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "ecs",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("examples/tests.zig"),
        .target = target,
        .optimize = effective_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "coyote-ecs", .module = coyote_mod },
        },
    });

    const main_tests = b.addExecutable(.{
        .name = "tests",
        .root_module = tests_mod,
    });
    b.installArtifact(main_tests);

    const test_step = b.step("tests", "Run library tests");
    test_step.dependOn(&main_tests.step);

    // Zig unit tests (in-source `test` blocks).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/coyote.zig"),
            .target = target,
            .optimize = effective_optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("test-unit", "Run Zig unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_unit_tests.step);

    const test_install = b.option(
        bool,
        "install-tests",
        "Install the test binaries into zig-out",
    ) orelse false;

    // Static C lib
    const static_c_lib: ?*std.Build.Step.Compile = if (target.result.os.tag != .wasi) lib: {
        const static_lib_mod = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = effective_optimize,
            .link_libc = true,
        });

        const static_lib = b.addLibrary(.{
            .name = "coyote",
            .linkage = .static,
            .root_module = static_lib_mod,
        });
        b.installArtifact(static_lib);
        b.default_step.dependOn(&static_lib.step);

        const static_binding_test_mod = b.createModule(.{
            .target = target,
            .optimize = effective_optimize,
            .link_libc = true,
        });
        static_binding_test_mod.addIncludePath(b.path("include"));
        static_binding_test_mod.addCSourceFile(.{ .file = b.path("examples/fruits.c"), .flags = &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99", "-D_POSIX_C_SOURCE=199309L" } });
        static_binding_test_mod.linkLibrary(static_lib);

        const static_binding_test = b.addExecutable(.{
            .name = "static-binding-test",
            .root_module = static_binding_test_mod,
        });
        if (test_install) b.installArtifact(static_binding_test);

        const static_binding_test_run = b.addRunArtifact(static_binding_test);
        test_step.dependOn(&static_binding_test_run.step);

        break :lib static_lib;
    } else null;

    _ = static_c_lib;

    // Dynamic C lib
    if (target.query.isNative()) {
        const dynamic_lib_name = "coyote";

        const dynamic_lib_mod = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = effective_optimize,
            .link_libc = true,
        });

        const dynamic_lib = b.addLibrary(.{
            .name = dynamic_lib_name,
            .linkage = .dynamic,
            .root_module = dynamic_lib_mod,
        });
        b.installArtifact(dynamic_lib);
        b.default_step.dependOn(&dynamic_lib.step);

        const dynamic_binding_test_mod = b.createModule(.{
            .target = target,
            .optimize = effective_optimize,
            .link_libc = true,
        });
        dynamic_binding_test_mod.addIncludePath(b.path("include"));
        dynamic_binding_test_mod.addCSourceFile(.{ .file = b.path("examples/fruits.c"), .flags = &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99", "-D_POSIX_C_SOURCE=199309L" } });
        dynamic_binding_test_mod.linkLibrary(dynamic_lib);

        const dynamic_binding_test = b.addExecutable(.{
            .name = "dynamic-binding-test",
            .root_module = dynamic_binding_test_mod,
        });
        if (test_install) b.installArtifact(dynamic_binding_test);

        const dynamic_binding_test_run = b.addRunArtifact(dynamic_binding_test);
        test_step.dependOn(&dynamic_binding_test_run.step);
    }
}
