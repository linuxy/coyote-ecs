const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const ecsPkg = std.build.Pkg{ .name = "coyote-ecs", .source = std.build.FileSource{ .path = "src/coyote.zig" }};

    const exe = b.addExecutable("ecs", "examples/fruits.zig");
    exe.setBuildMode(mode);
    exe.linkLibC();
    exe.addLibraryPath("vendor/mimalloc");
    exe.linkSystemLibrary("mimalloc");
    exe.addPackage(ecsPkg);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}