const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .root_source_file = .{ .path = "examples/fruits.zig"},
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
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const main_tests = b.addExecutable(.{
        .root_source_file = .{ .path = "examples/tests.zig"},
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
    main_tests.install();

    const test_step = b.step("tests", "Run library tests");
    test_step.dependOn(&main_tests.step);
}