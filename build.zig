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

    const exe = b.addExecutable(.{
        .root_source_file = b.path("examples/fruits.zig"),
        .optimize = effective_optimize,
        .target = target,
        .name = "ecs",
    });

    exe.root_module.addAnonymousImport("coyote-ecs", .{
        .root_source_file = b.path("src/coyote.zig"),
    });

    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const main_tests = b.addExecutable(.{
        .root_source_file = b.path("examples/tests.zig"),
        .optimize = effective_optimize,
        .target = target,
        .name = "tests",
    });
    main_tests.linkLibC();

    main_tests.root_module.addAnonymousImport("coyote-ecs", .{
        .root_source_file = b.path("src/coyote.zig"),
    });
    b.installArtifact(main_tests);

    const test_step = b.step("tests", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const test_install = b.option(
        bool,
        "install-tests",
        "Install the test binaries into zig-out",
    ) orelse false;

    // Static C lib
    const static_c_lib: ?*std.Build.Step.Compile = if (target.result.os.tag != .wasi) lib: {
        const static_lib = b.addStaticLibrary(.{
            .name = "coyote",
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = effective_optimize,
        });
        b.installArtifact(static_lib);
        static_lib.linkLibC();
        b.default_step.dependOn(&static_lib.step);

        const static_binding_test = b.addExecutable(.{
            .name = "static-binding-test",
            .target = target,
            .optimize = effective_optimize,
        });
        static_binding_test.linkLibC();
        static_binding_test.addIncludePath(b.path("include"));
        static_binding_test.addCSourceFile(.{ .file = b.path("examples/fruits.c"), .flags = &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99", "-D_POSIX_C_SOURCE=199309L" } });
        static_binding_test.linkLibrary(static_lib);
        if (test_install) b.installArtifact(static_binding_test);

        const static_binding_test_run = b.addRunArtifact(static_binding_test);
        test_step.dependOn(&static_binding_test_run.step);

        break :lib static_lib;
    } else null;

    _ = static_c_lib;

    // Dynamic C lib
    if (target.query.isNative()) {
        const dynamic_lib_name = "coyote";

        const dynamic_lib = b.addSharedLibrary(.{
            .name = dynamic_lib_name,
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = effective_optimize,
        });
        dynamic_lib.linkLibC();
        b.installArtifact(dynamic_lib);
        b.default_step.dependOn(&dynamic_lib.step);

        const dynamic_binding_test = b.addExecutable(.{
            .name = "dynamic-binding-test",
            .target = target,
            .optimize = effective_optimize,
        });
        dynamic_binding_test.linkLibC();
        dynamic_binding_test.addIncludePath(b.path("include"));
        dynamic_binding_test.addCSourceFile(.{ .file = b.path("examples/fruits.c"), .flags = &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99", "-D_POSIX_C_SOURCE=199309L" } });
        dynamic_binding_test.linkLibrary(dynamic_lib);
        if (test_install) b.installArtifact(dynamic_binding_test);

        const dynamic_binding_test_run = b.addRunArtifact(dynamic_binding_test);
        test_step.dependOn(&dynamic_binding_test_run.step);
    }
}
