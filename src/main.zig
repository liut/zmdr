const std = @import("std");
const Webview = @import("webview").Webview;
const html_resource = @import("html_resource");

const Context = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    base_dir: []const u8,
};

var global_ctx: *Context = undefined;
var global_io: std.Io = undefined;
var global_easy: *Webview.Easy(Context) = undefined;

// HTML content embedded at compile time
const html_content = html_resource.html_content;

pub fn main(ctx: std.process.Init) !void {
    const allocator = ctx.gpa;
    global_io = ctx.io;

    const ArgsIter = blk: {
        if (@import("builtin").os.tag == .windows) {
            break :blk try std.process.Args.initAllocator(ctx.minimal.args, allocator);
        } else {
            break :blk std.process.Args.iterate(ctx.minimal.args);
        }
    };
    var args = ArgsIter;
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

    var easy: Webview.Easy(Context) = try .init(&ctx_local, .release);
    global_easy = &easy;
    defer easy.deinit();

    try easy.bindFn("reloadFile", reloadFile);
    try easy.bindFn("getFilePath", getFilePath);
    try easy.bindFn("closeWindow", closeWindow);
    try easy.bindFn("openExternal", openExternal);

    var title_buf: [256:0]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "mdr - {s}", .{file_path}) catch @panic("title too long");
    try easy.setTitle(title);
    try easy.setSize(1100, 900, .none);

    // Load initial markdown file content
    const initial_content = try readFileAlloc(file_path, allocator);
    defer allocator.free(initial_content);

    // Inline images as data URIs
    const inlined_content = try inlineImages(allocator, initial_content, base_dir);
    defer allocator.free(inlined_content);

    const escaped = try escapeJson(allocator, inlined_content);
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

fn closeWindow(req: Webview.Easy(Context).Request) !void {
    req.resolve();
    global_easy.terminate() catch {};
}

fn openExternal(req: Webview.Easy(Context).Request) !void {
    // Extract URL from JSON args, stripping any JSON escaping artifacts
    const start = std.mem.indexOf(u8, req.args, "http") orelse {
        req.reject("No URL found");
        return;
    };
    var end: usize = start;
    while (end < req.args.len and req.args[end] != '"' and req.args[end] != '\\') : (end += 1) {}
    const url = req.args[start..end];
    const argv = [_][]const u8{ "open", url };
    const result = std.process.run(global_ctx.allocator, global_io, .{ .argv = &argv }) catch {
        req.reject("Failed to open");
        return;
    };
    global_ctx.allocator.free(result.stdout);
    global_ctx.allocator.free(result.stderr);
    req.resolve();
}

fn inlineImages(allocator: std.mem.Allocator, content: []const u8, base_dir: []const u8) ![]u8 {
    var result = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < content.len) {
        if (i + 1 < content.len and content[i] == '!' and content[i + 1] == '[') {
            if (try tryImg(allocator, content, &i, base_dir, &result)) continue;
        }
        try result.append(allocator, content[i]);
        i += 1;
    }
    return result.toOwnedSlice(allocator);
}

fn tryImg(allocator: std.mem.Allocator, content: []const u8, i: *usize, base_dir: []const u8, result: *std.ArrayList(u8)) !bool {
    const start = i.*;
    const alt_end = std.mem.indexOfPos(u8, content, start + 2, "](") orelse return false;
    const path_start = alt_end + 2;
    if (path_start >= content.len) return false;
    const path_end = std.mem.indexOfScalarPos(u8, content, path_start, ')') orelse return false;
    const img_path = content[path_start..path_end];

    // Resolve absolute path
    const abs_path = if (std.fs.path.isAbsolute(img_path))
        try allocator.dupe(u8, img_path)
    else if (base_dir.len > 0)
        try std.fs.path.resolve(allocator, &.{ base_dir, img_path })
    else
        img_path;
    defer if (std.fs.path.isAbsolute(img_path) or base_dir.len > 0) allocator.free(abs_path);

    // Use system base64 command
    const b64_result = std.process.run(allocator, global_io, .{ .argv = &.{ "base64", "-i", abs_path } }) catch return false;
    defer allocator.free(b64_result.stdout);
    defer allocator.free(b64_result.stderr);
    // Trim trailing newline
    var b64_data = b64_result.stdout;
    if (b64_data.len > 0 and b64_data[b64_data.len - 1] == '\n') b64_data.len -= 1;

    // MIME type
    const ext = std.fs.path.extension(img_path);
    const mime = if (std.mem.eql(u8, ext, ".png")) "image/png"
    else if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) "image/jpeg"
    else if (std.mem.eql(u8, ext, ".gif")) "image/gif"
    else if (std.mem.eql(u8, ext, ".svg")) "image/svg+xml"
    else if (std.mem.eql(u8, ext, ".webp")) "image/webp"
    else "image/png";

    // Build data URI
    const prefix = try std.fmt.allocPrint(allocator, "data:{s};base64,", .{mime});
    defer allocator.free(prefix);

    try result.appendSlice(allocator, content[start..path_start]); // ![...](
    try result.appendSlice(allocator, prefix);
    try result.appendSlice(allocator, b64_data);
    try result.append(allocator, ')');
    i.* = path_end + 1;
    return true;
}

fn getFilePath(req: Webview.Easy(Context).Request) !void {
    var buf: [1024:0]u8 = undefined;
    const result = std.fmt.bufPrintZ(&buf, "\"{s}\"", .{global_ctx.file_path}) catch @panic("path too long");
    req.resolveWith(result);
}