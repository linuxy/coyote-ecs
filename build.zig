const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .root_source_file = .{ .path = "examples/fruits.zig" },
        .optimize = optimize,
        .target = target,
        .name = "ecs",
    });

    exe.addAnonymousModule("rpmalloc", .{
        .source_file = .{ .path = "vendor/rpmalloc-zig-port/src/rpmalloc.zig" },
    });

    exe.addAnonymousModule("coyote-ecs", .{
        .source_file = .{ .path = "src/coyote.zig" },
    });

    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const main_tests = b.addExecutable(.{
        .root_source_file = .{ .path = "examples/tests.zig" },
        .optimize = optimize,
        .target = target,
        .name = "tests",
    });
    main_tests.linkLibC();
    main_tests.addAnonymousModule("rpmalloc", .{
        .source_file = .{ .path = "vendor/rpmalloc-zig-port/src/rpmalloc.zig" },
    });

    main_tests.addAnonymousModule("coyote-ecs", .{
        .source_file = .{ .path = "src/coyote.zig" },
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
    const static_c_lib: ?*std.build.LibExeObjStep = if (target.getOsTag() != .wasi) lib: {
        const static_lib = b.addStaticLibrary(.{
            .name = "coyote",
            .root_source_file = .{ .path = "src/c_api.zig" },
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(static_lib);
        static_lib.linkLibC();
        b.default_step.dependOn(&static_lib.step);

        const static_binding_test = b.addExecutable(.{
            .name = "static-binding-test",
            .target = target,
            .optimize = optimize,
        });
        static_binding_test.linkLibC();
        static_binding_test.addIncludePath(.{ .path = "include" });
        static_binding_test.addCSourceFile(.{ .file = .{ .path = "examples/fruits.c" }, .flags = &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99", "-D_POSIX_C_SOURCE=199309L" } });
        static_binding_test.linkLibrary(static_lib);
        if (test_install) b.installArtifact(static_binding_test);

        const static_binding_test_run = b.addRunArtifact(static_binding_test);
        test_step.dependOn(&static_binding_test_run.step);

        break :lib static_lib;
    } else null;

    _ = static_c_lib;

    // Dynamic C lib
    if (target.isNative()) {
        const dynamic_lib_name = "coyote";

        const dynamic_lib = b.addSharedLibrary(.{
            .name = dynamic_lib_name,
            .root_source_file = .{ .path = "src/c_api.zig" },
            .target = target,
            .optimize = optimize,
        });
        dynamic_lib.linkLibC();
        b.installArtifact(dynamic_lib);
        b.default_step.dependOn(&dynamic_lib.step);

        const dynamic_binding_test = b.addExecutable(.{
            .name = "dynamic-binding-test",
            .target = target,
            .optimize = optimize,
        });
        dynamic_binding_test.linkLibC();
        dynamic_binding_test.addIncludePath(.{ .path = "include" });
        dynamic_binding_test.addCSourceFile(.{ .file = .{ .path = "examples/fruits.c" }, .flags = &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99", "-D_POSIX_C_SOURCE=199309L" } });
        dynamic_binding_test.linkLibrary(dynamic_lib);
        if (test_install) b.installArtifact(dynamic_binding_test);

        const dynamic_binding_test_run = b.addRunArtifact(dynamic_binding_test);
        test_step.dependOn(&dynamic_binding_test_run.step);
    }
}
