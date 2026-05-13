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

    // Embed HTML template at compile time
    const embed_html = @embedFile("assets/index.html");

    // Create our module with src/main.zig as root
    const zmdr_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "webview", .module = webview_mod },
        },
    });

    // Pass embedded HTML to main.zig via an options module
    const opts = b.addOptions();
    opts.addOption([]const u8, "html_content", embed_html);
    zmdr_mod.addImport("html_resource", opts.createModule());

    const exe = b.addExecutable(.{
        .name = "zmdr",
        .root_module = zmdr_mod,
        .use_llvm = true,
    });

    b.installArtifact(exe);
}
