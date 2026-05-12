const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the webview module from dependency
    const webview_dep = b.dependency("webview", .{
        .target = target,
        .optimize = optimize,
    });
    const webview_mod = webview_dep.module("webview");

    // Create our module with src/main.zig as root
    const zmdr_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "webview", .module = webview_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zmdr",
        .root_module = zmdr_mod,
        .use_llvm = true,
    });

    b.installArtifact(exe);
}