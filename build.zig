const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const assets_mod = b.addModule("assets", .{
        .root_source_file = b.path("assets.zig"),
    });

    const uuid_mod = b.dependency("uuid", .{}).module("uuid");

    const exe = b.addExecutable(.{
        .name = "anvilauth",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    exe.root_module.addImport("assets", assets_mod);
    exe.root_module.addImport("uuid", uuid_mod);

    exe.linkSystemLibrary("pq");
    exe.linkSystemLibrary("crypto");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
