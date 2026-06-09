const std = @import("std");
const sax_api = @import("sax_vite_api");
const sax_build = sax_api.build;
const http_api = @import("http_vite_api");
const reload_client = @import("reload_client_gen.zig");
const watch = @import("watch.zig");

const ns_per_ms = std.time.ns_per_ms;

pub const BuildResult = enum {
    refreshed,
    failed,
};

pub const DevOptions = struct {
    entry_sax: []const u8,
    dist_dir: ?[]const u8 = null,
    port: u16 = 5173,
    debounce_ms: u64 = 80,
    stop_signal: ?*std.atomic.Value(bool) = null,
};

pub const PreviewOptions = struct {
    dist_dir: []const u8 = "dist",
    port: u16 = 5173,
};

const ServerMode = enum {
    dev,
    preview,
};

const ServerState = struct {
    allocator: std.mem.Allocator,
    dist_dir: []const u8,
    build_version: std.atomic.Value(u64),
    build_error: std.atomic.Value(bool),
};

fn sourceStem(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const dot_idx = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    return basename[0..dot_idx];
}

fn sourceDir(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn sourceDirAbs(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().realpathAlloc(allocator, sourceDir(path));
}

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try std.fs.cwd().makePath(dir);
    }
}

fn writeAllFile(path: []const u8, bytes: []const u8) !void {
    try ensureParentDir(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn readSource(allocator: std.mem.Allocator, sax_file: []const u8, stderr: anytype) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, sax_file, 16 * 1024 * 1024) catch |err| {
        try stderr.print("error: failed to read {s}: {}\n", .{ sax_file, err });
        return error.ReadFailed;
    };
}

pub fn buildOnce(
    allocator: std.mem.Allocator,
    entry_sax: []const u8,
    dist_dir: []const u8,
    inject_reload_client: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const source = try readSource(allocator, entry_sax, stderr);
    defer allocator.free(source);

    var compiler = sax_api.SaxCompiler.init(allocator);
    const compiled = compiler.compile(source, sourceStem(entry_sax)) catch |err| {
        try stderr.print("error: SAX compilation failed: {}\n", .{err});
        return 1;
    };
    defer compiled.sa_code.deinit();
    defer compiled.airlock_js.deinit();
    defer compiled.index_html.deinit();

    const source_dir_abs = try sourceDirAbs(allocator, entry_sax);
    defer allocator.free(source_dir_abs);
    const generated_source_path = try std.fmt.allocPrint(allocator, "{s}/{s}.sa", .{ source_dir_abs, sourceStem(entry_sax) });
    defer allocator.free(generated_source_path);

    const wasm_path = try std.fs.path.join(allocator, &.{ dist_dir, "app.wasm" });
    defer allocator.free(wasm_path);
    const build_code = try sax_build.buildBrowserWasmFromSourceText(
        allocator,
        generated_source_path,
        compiled.sa_code.items,
        wasm_path,
        false,
        .release_small,
        .{},
        stderr,
    );
    if (build_code != 0) return build_code;

    const sa_path = try std.fs.path.join(allocator, &.{ dist_dir, "app.sa" });
    defer allocator.free(sa_path);
    const airlock_path = try std.fs.path.join(allocator, &.{ dist_dir, "airlock.js" });
    defer allocator.free(airlock_path);
    const html_path = try std.fs.path.join(allocator, &.{ dist_dir, "index.html" });
    defer allocator.free(html_path);

    const injected_html = if (inject_reload_client)
        try reload_client.injectInto(allocator, compiled.index_html.items)
    else
        try allocator.dupe(u8, compiled.index_html.items);
    defer allocator.free(injected_html);

    try writeAllFile(sa_path, compiled.sa_code.items);
    try writeAllFile(airlock_path, compiled.airlock_js.items);
    try writeAllFile(html_path, injected_html);

    try stdout.print("✓ vite build refreshed\n", .{});
    try stdout.print("  .sa: {s}\n", .{sa_path});
    try stdout.print("  app.wasm: {s}\n", .{wasm_path});
    try stdout.print("  airlock.js: {s}\n", .{airlock_path});
    try stdout.print("  index.html: {s}\n", .{html_path});
    return 0;
}

fn contentTypeFor(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".sa")) return "text/plain";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    return "application/octet-stream";
}

fn requestPath(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |idx| return target[0..idx];
    return target;
}

fn staticRelativePath(target: []const u8) ![]const u8 {
    const without_query = if (std.mem.indexOfScalar(u8, target, '?')) |idx| target[0..idx] else target;
    const relative = if (std.mem.eql(u8, without_query, "/")) "index.html" else if (std.mem.startsWith(u8, without_query, "/")) without_query[1..] else without_query;
    if (relative.len == 0 or std.mem.indexOf(u8, relative, "..") != null) return error.InvalidPath;
    return relative;
}

fn sendResponse(request: *http_api.HttpRequest, status: std.http.Status, content_type: []const u8, body: []const u8) !void {
    const response = try http_api.HttpResponse.init(request, @intFromEnum(status));
    defer response.deinit();
    try response.setContentType(content_type);
    try response.send(body);
}

fn serveStaticFile(allocator: std.mem.Allocator, request: *http_api.HttpRequest, dist_dir: []const u8, target: []const u8) !void {
    const relative = staticRelativePath(target) catch {
        try sendResponse(request, .bad_request, "text/plain", "bad request\n");
        return;
    };
    const full_path = try std.fs.path.join(allocator, &.{ dist_dir, relative });
    defer allocator.free(full_path);
    const body = std.fs.cwd().readFileAlloc(allocator, full_path, 32 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            try sendResponse(request, .not_found, "text/plain", "not found\n");
            return;
        },
        else => return err,
    };
    defer allocator.free(body);
    try sendResponse(request, .ok, contentTypeFor(relative), body);
}

fn writeSseEvent(response: *http_api.HttpStreamResponse, version: u64, is_error: bool) !void {
    if (is_error) {
        var buf: [64]u8 = undefined;
        const event = try std.fmt.bufPrint(&buf, "data: error:{d}\n\n", .{version});
        try response.writeChunk(event);
    } else {
        var buf: [64]u8 = undefined;
        const event = try std.fmt.bufPrint(&buf, "data: {d}\n\n", .{version});
        try response.writeChunk(event);
    }
    try response.flush();
}

fn sseClientThread(request: *http_api.HttpRequest, build_version: *std.atomic.Value(u64), build_error: *std.atomic.Value(bool)) void {
    defer request.deinit();
    const response = http_api.HttpStreamResponse.init(request, 200) catch return;
    defer response.deinit();
    response.writeChunk(": connected\n\n") catch return;
    response.flush() catch return;

    var last = build_version.load(.seq_cst);
    while (true) {
        const current = build_version.load(.seq_cst);
        if (current != last) {
            last = current;
            writeSseEvent(response, current, build_error.load(.seq_cst)) catch return;
        }
        std.Thread.sleep(100 * ns_per_ms);
    }
}

fn handleRequest(state: *ServerState, request: *http_api.HttpRequest) !void {
    const target = requestPath(request.target);
    if (std.mem.eql(u8, target, "/__sax_live")) {
        const thread = try std.Thread.spawn(.{}, sseClientThread, .{ request, &state.build_version, &state.build_error });
        thread.detach();
        return;
    }

    if (std.mem.eql(u8, target, reload_client.reload_client_path)) {
        defer request.deinit();
        try sendResponse(request, .ok, "application/javascript", reload_client.reload_client_script);
        return;
    }

    defer request.deinit();
    try serveStaticFile(state.allocator, request, state.dist_dir, target);
}

fn defaultDistDir(allocator: std.mem.Allocator, entry_sax: []const u8) ![]u8 {
    const root = try sourceDirAbs(allocator, entry_sax);
    defer allocator.free(root);
    return try std.fs.path.join(allocator, &.{ root, "dist" });
}

pub fn runBuild(
    allocator: std.mem.Allocator,
    entry_sax: []const u8,
    dist_dir_opt: ?[]const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const dist_dir = if (dist_dir_opt) |dir| try allocator.dupe(u8, dir) else try defaultDistDir(allocator, entry_sax);
    defer allocator.free(dist_dir);
    try std.fs.cwd().makePath(dist_dir);
    return try buildOnce(allocator, entry_sax, dist_dir, false, stdout, stderr);
}

pub fn runDev(
    allocator: std.mem.Allocator,
    options: DevOptions,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const dist_dir = if (options.dist_dir) |dir| try allocator.dupe(u8, dir) else try defaultDistDir(allocator, options.entry_sax);
    defer allocator.free(dist_dir);
    try std.fs.cwd().makePath(dist_dir);

    if (try buildOnce(allocator, options.entry_sax, dist_dir, true, stdout, stderr) != 0) return 1;

    var state = ServerState{
        .allocator = allocator,
        .dist_dir = dist_dir,
        .build_version = std.atomic.Value(u64).init(1),
        .build_error = std.atomic.Value(bool).init(false),
    };
    return try serveLoop(allocator, &state, options.entry_sax, options.port, options.debounce_ms, options.stop_signal, .dev, stdout, stderr);
}

pub fn runPreview(
    allocator: std.mem.Allocator,
    options: PreviewOptions,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var state = ServerState{
        .allocator = allocator,
        .dist_dir = options.dist_dir,
        .build_version = std.atomic.Value(u64).init(0),
        .build_error = std.atomic.Value(bool).init(false),
    };
    return try serveLoop(allocator, &state, null, options.port, 0, null, .preview, stdout, stderr);
}

fn pushBuildEvent(state: *ServerState, failed: bool) void {
    state.build_error.store(failed, .seq_cst);
    _ = state.build_version.fetchAdd(1, .seq_cst);
}

fn serveLoop(
    allocator: std.mem.Allocator,
    state: *ServerState,
    entry_sax: ?[]const u8,
    port: u16,
    debounce_ms: u64,
    stop_signal: ?*std.atomic.Value(bool),
    mode: ServerMode,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var server = try http_api.HttpServer.init(allocator);
    defer server.deinit();
    try server.startWithOptions("127.0.0.1", port, .{ .reuse_address = true, .force_nonblocking = true });
    try stdout.print("✓ vite {s} server listening on http://127.0.0.1:{d}\n", .{ @tagName(mode), port });

    const watch_root = if (entry_sax) |path| try sourceDirAbs(allocator, path) else null;
    defer if (watch_root) |root| allocator.free(root);

    var last_fingerprint: ?u64 = null;
    while (true) {
        if (stop_signal) |signal| {
            if (signal.load(.seq_cst)) return 0;
        }

        if (mode == .dev) {
            const path = entry_sax.?;
            const current_fingerprint = watch.fingerprint(allocator, watch_root.?) catch |err| {
                try stderr.print("error: failed to scan SAX files under {s}: {}\n", .{ watch_root.?, err });
                std.Thread.sleep(100 * ns_per_ms);
                continue;
            };
            if (last_fingerprint == null) {
                last_fingerprint = current_fingerprint;
            } else if (current_fingerprint != last_fingerprint.?) {
                std.Thread.sleep(debounce_ms * ns_per_ms);
                const debounced_fingerprint = watch.fingerprint(allocator, watch_root.?) catch current_fingerprint;
                last_fingerprint = debounced_fingerprint;
                const build_code = try buildOnce(allocator, path, state.dist_dir, true, stdout, stderr);
                if (build_code == 0) {
                    pushBuildEvent(state, false);
                    try stdout.print("✓ vite pushed reload version {d}\n", .{state.build_version.load(.seq_cst)});
                } else {
                    pushBuildEvent(state, true);
                    try stderr.print("error: vite rebuild failed; pushed error version {d}\n", .{state.build_version.load(.seq_cst)});
                }
            }
        }

        const request = server.accept() catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(50 * ns_per_ms);
                continue;
            },
            else => return err,
        };
        try handleRequest(state, request);
    }
}

test "static relative path rejects traversal" {
    try std.testing.expectError(error.InvalidPath, staticRelativePath("/../secret"));
    try std.testing.expectEqualStrings("index.html", try staticRelativePath("/"));
    try std.testing.expectEqualStrings("airlock.js", try staticRelativePath("/airlock.js?x=1"));
}
