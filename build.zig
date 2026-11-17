const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");

    const exe = b.addExecutable(.{
        .name = "ilgi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
    });
    exe.root_module.addAnonymousImport("app_icon", .{
        .root_source_file = b.path("assets/icon.png"),
    });
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);

    const app_step = b.step("app", "Build Ilgi.app bundle");
    app_step.dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "Ilgi.app/Contents/MacOS" } },
    }).step);
    app_step.dependOn(&b.addInstallFile(b.path("assets/Info.plist"), "Ilgi.app/Contents/Info.plist").step);
    app_step.dependOn(&b.addInstallFile(b.path("assets/AppIcon.icns"), "Ilgi.app/Contents/Resources/AppIcon.icns").step);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Ilgi").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
    });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
