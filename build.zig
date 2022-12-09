const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const ecsPkg = std.build.Pkg{ .name = "coyote-ecs", .source = std.build.FileSource{ .path = "src/coyote.zig" }};

    const mimalloc = build_mimalloc(b);

    const exe = b.addExecutable("ecs", "examples/fruits.zig");
    exe.setBuildMode(mode);
    exe.linkLibC();
    exe.addPackage(ecsPkg);
    exe.addLibraryPath("vendor/mimalloc");
    exe.linkSystemLibrary("mimalloc");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const make_step = b.step("mimalloc", "Make mimalloc library");
    make_step.dependOn(&mimalloc.step);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn build_mimalloc(b: *std.build.Builder) *std.build.RunStep {

    const cmake = b.addSystemCommand(
        &[_][]const u8{
            "cmake",
            "-S./vendor/mimalloc/",
            "-B./vendor/mimalloc/",
        },
    );
    const make = b.addSystemCommand(
        &[_][]const u8{
            "make",
            "-j4",
            "-C./vendor/mimalloc",
        },
    );

    make.step.dependOn(&cmake.step);
    return make;
}