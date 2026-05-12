const std = @import("std");
const Webview = @import("webview").Webview;

const Context = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    base_dir: []const u8,
};

var global_ctx: *Context = undefined;
var global_io: std.Io = undefined;
var global_easy: *Webview.Easy(Context) = undefined;

// HTML content loaded at runtime (null-terminated for Webview)
var html_content: [:0]u8 = undefined;

pub fn main(ctx: std.process.Init) !void {
    const allocator = ctx.gpa;
    global_io = ctx.io;

    var args = std.process.Args.iterate(ctx.minimal.args);
    _ = args.next(); // skip executable path
    const file_path = args.next() orelse {
        std.debug.print("Usage: zmdr <file.md>\n", .{});
        std.process.exit(1);
    };

    const base_dir = std.fs.path.dirname(file_path) orelse "";
    std.debug.print("Opening: {s}\n", .{file_path});
    std.debug.print("Base dir: {s}\n", .{base_dir});

    var ctx_local: Context = .{
        .allocator = allocator,
        .file_path = file_path,
        .base_dir = base_dir,
    };
    global_ctx = &ctx_local;

    // Load HTML from assets/index.html relative to executable
    const html_alloc = try std.Io.Dir.cwd().readFileAlloc(global_io, "assets/index.html", allocator, .unlimited);
    defer allocator.free(html_alloc);
    // Create null-terminated version for Webview
    html_content = try allocator.dupeZ(u8, html_alloc);
    defer allocator.free(html_content);

    var easy: Webview.Easy(Context) = try .init(&ctx_local, .release);
    global_easy = &easy;
    defer easy.deinit();

    try easy.bindFn("reloadFile", reloadFile);
    try easy.bindFn("getFilePath", getFilePath);

    var title_buf: [256:0]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "mdr - {s}", .{file_path}) catch @panic("title too long");
    try easy.setTitle(title);
    try easy.setSize(1100, 900, .none);

    // Load initial markdown file content
    const initial_content = try readFileAlloc(file_path, allocator);
    defer allocator.free(initial_content);

    const escaped = try escapeJson(allocator, initial_content);
    defer allocator.free(escaped);

    // Inject markdown into HTML before setting
    const html_with_mermaid = std.mem.concat(allocator, u8, &.{
        html_content,
        "<script>window.zigMarkdown=\"",
        escaped,
        "\";window.zigUpdateContent(window.zigMarkdown);</script>",
    }) catch {
        std.debug.print("Error injecting markdown\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(html_with_mermaid);

    const html_final = try allocator.dupeZ(u8, html_with_mermaid);
    defer allocator.free(html_final);

    try easy.setHtml(html_final);

    // Start file watcher thread
    const thread = std.Thread.spawn(.{}, fileWatcherThread, .{file_path, allocator}) catch |err| {
        std.debug.print("Failed to start file watcher: {}\n", .{err});
        return;
    };
    thread.detach();

    try easy.run();
}

fn fileWatcherThread(file_path: []const u8, allocator: std.mem.Allocator) void {
    _ = allocator;
    // Get initial modification time
    var last_mtime = getFileMtime(file_path);

    while (true) {
        const sleep_duration = std.Io.Duration{ .nanoseconds = 1_000_000_000 };
        std.Io.sleep(global_io, sleep_duration, std.Io.Clock.real) catch {};
        const current_mtime = getFileMtime(file_path);
        if (current_mtime != last_mtime) {
            last_mtime = current_mtime;
            global_easy.dispatchSimple(dispatchReloadSimple) catch {};
        }
    }
}

fn getFileMtime(path: []const u8) i96 {
    const dir = std.Io.Dir.cwd();
    const file = dir.openFile(global_io, path, .{}) catch return 0;
    defer file.close(global_io);
    const stat = file.stat(global_io) catch return 0;
    return stat.mtime.nanoseconds;
}

fn dispatchReloadSimple(w: *Webview) void {
    const allocator = global_ctx.allocator;
    const file_path = global_ctx.file_path;

    const content = readFileAlloc(file_path, allocator) catch return;
    defer allocator.free(content);

    const escaped = escapeJson(allocator, content) catch {
        allocator.free(content);
        return;
    };
    defer allocator.free(escaped);

    const escaped_z = allocator.dupeZ(u8, escaped) catch {
        allocator.free(escaped);
        return;
    };
    defer allocator.free(escaped_z);

    var js_buf: [8192:0]u8 = undefined;
    const js = std.fmt.bufPrintZ(&js_buf, "window.zigReloadMarkdown(\"{s}\");", .{escaped_z}) catch return;

    w.eval(js) catch return;
}

fn readFileAlloc(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(global_io, path, .{});
    defer file.close(global_io);

    const stat = try file.stat(global_io);
    const file_size: usize = @intCast(stat.size);

    const content = try allocator.alloc(u8, file_size);
    errdefer allocator.free(content);

    const n = try file.readPositionalAll(global_io, content, 0);
    return content[0..n];
}

fn escapeJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len * 2);
    defer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }
    return result.toOwnedSlice(allocator);
}

fn reloadFile(req: Webview.Easy(Context).Request) !void {
    const content = readFileAlloc(global_ctx.file_path, global_ctx.allocator) catch |err| {
        req.rejectError(err);
        return;
    };
    defer global_ctx.allocator.free(content);
    const json = escapeJson(global_ctx.allocator, content) catch |err| {
        req.rejectError(err);
        return;
    };
    defer global_ctx.allocator.free(json);
    const json_z = try global_ctx.allocator.dupeZ(u8, json);
    defer global_ctx.allocator.free(json_z);
    req.resolveWith(json_z);
}

fn getFilePath(req: Webview.Easy(Context).Request) !void {
    var buf: [1024:0]u8 = undefined;
    const result = std.fmt.bufPrintZ(&buf, "\"{s}\"", .{global_ctx.file_path}) catch @panic("path too long");
    req.resolveWith(result);
}