const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const rpmPkg = std.build.Pkg{ .name = "rpmalloc", .source = std.build.FileSource{ .path = "vendor/rpmalloc-zig-port/src/rpmalloc.zig"}};
    const ecsPkg = std.build.Pkg{ .name = "coyote-ecs", .source = std.build.FileSource{ .path = "src/coyote.zig" }, .dependencies = &[_]std.build.Pkg{ rpmPkg }};

    const exe = b.addExecutable("ecs", "examples/fruits.zig");
    exe.setBuildMode(mode);
    exe.linkLibC();
    exe.addPackage(ecsPkg);
    exe.addPackage(rpmPkg);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const main_tests = b.addExecutable("tests", "examples/tests.zig");
    main_tests.setBuildMode(mode);
    main_tests.linkLibC();
    main_tests.addPackage(ecsPkg);
    main_tests.addPackage(rpmPkg);
    main_tests.install();

    const test_step = b.step("tests", "Run library tests");
    test_step.dependOn(&main_tests.step);
}