const std = @import("std");
const build_config = @import("build_options");
const sax_api = @import("sax_vite_api");
const sax_build = sax_api.build;
const react_api = @import("react_vite_api");
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
    use_react: bool = false,
    includes: []const []const u8 = &.{},
    title: ?[]const u8 = null,
    css: ?[]const u8 = null,
    public_dir: ?[]const u8 = null,
    stop_signal: ?*std.atomic.Value(bool) = null,
};

pub const BuildOptions = struct {
    use_react: bool = false,
    includes: []const []const u8 = &.{},
    title: ?[]const u8 = null,
    css: ?[]const u8 = null,
    public_dir: ?[]const u8 = null,
};

pub const PreviewOptions = struct {
    dist_dir: []const u8 = "dist",
    port: u16 = 5173,
};

const ServerMode = enum {
    dev,
    preview,
};

fn devScanIntervalMs(debounce_ms: u64, has_public_dir: bool) u64 {
    const floor: u64 = if (has_public_dir) 1000 else 250;
    return if (debounce_ms < floor) floor else debounce_ms;
}

const ServerState = struct {
    allocator: std.mem.Allocator,
    dist_dir: []const u8,
    build_version: std.atomic.Value(u64),
    build_error: std.atomic.Value(bool),
};

const DevFingerprint = struct {
    source: u64,
    css: ?u64 = null,
    public: ?u64 = null,

    fn eql(a: DevFingerprint, b: DevFingerprint) bool {
        return a.source == b.source and a.css == b.css and a.public == b.public;
    }
};

const build_cache_version = "sa-vite-build-cache-v1";

const BuildCacheStatus = enum {
    hit,
    miss,
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

fn copyFileTo(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, src_path, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    try writeAllFile(dst_path, bytes);
}

fn copyPublicDir(allocator: std.mem.Allocator, src_root: []const u8, rel: []const u8, dist_dir: []const u8) !void {
    const dir_path = if (rel.len == 0) try allocator.dupe(u8, src_root) else try std.fs.path.join(allocator, &.{ src_root, rel });
    defer allocator.free(dir_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, "node_modules")) continue;
            const child_rel = if (rel.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ rel, entry.name });
            defer allocator.free(child_rel);
            try copyPublicDir(allocator, src_root, child_rel, dist_dir);
            continue;
        }
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const rel_path = if (rel.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ rel, entry.name });
        defer allocator.free(rel_path);
        const src_path = try std.fs.path.join(allocator, &.{ src_root, rel_path });
        defer allocator.free(src_path);
        const dst_path = try std.fs.path.join(allocator, &.{ dist_dir, rel_path });
        defer allocator.free(dst_path);
        try copyFileTo(allocator, src_path, dst_path);
    }
}

fn injectTitle(allocator: std.mem.Allocator, html: []const u8, title: []const u8) ![]u8 {
    const open = "<title>";
    const close = "</title>";
    const start = std.mem.indexOf(u8, html, open) orelse return try allocator.dupe(u8, html);
    const content_start = start + open.len;
    const end_rel = std.mem.indexOf(u8, html[content_start..], close) orelse return try allocator.dupe(u8, html);
    const end = content_start + end_rel;
    return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ html[0..content_start], title, html[end..] });
}

fn injectStylesheet(allocator: std.mem.Allocator, html: []const u8, href: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, html, href) != null) return try allocator.dupe(u8, html);

    const link_tag = try std.fmt.allocPrint(allocator, "  <link rel=\"stylesheet\" href=\"./{s}\">", .{href});
    defer allocator.free(link_tag);
    if (std.mem.lastIndexOf(u8, html, "</head>")) |idx| {
        return try std.fmt.allocPrint(allocator, "{s}{s}\n{s}", .{ html[0..idx], link_tag, html[idx..] });
    }
    return try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ html, link_tag });
}

fn mixU64(hasher: *std.hash.Wyhash, value: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    hasher.update(&buf);
}

fn mixI128(hasher: *std.hash.Wyhash, value: i128) void {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(i128, &buf, value, .little);
    hasher.update(&buf);
}

fn mixBool(hasher: *std.hash.Wyhash, value: bool) void {
    hasher.update(if (value) "\x01" else "\x00");
}

fn mixBytes(hasher: *std.hash.Wyhash, bytes: []const u8) void {
    mixU64(hasher, bytes.len);
    hasher.update(bytes);
}

fn mixOptionalBytes(hasher: *std.hash.Wyhash, bytes: ?[]const u8) void {
    if (bytes) |value| {
        mixBool(hasher, true);
        mixBytes(hasher, value);
    } else {
        mixBool(hasher, false);
    }
}

fn mixBuildOptions(hasher: *std.hash.Wyhash, options: BuildOptions) void {
    mixBool(hasher, options.use_react);
    mixU64(hasher, options.includes.len);
    for (options.includes) |include_file| mixBytes(hasher, include_file);
    mixOptionalBytes(hasher, options.title);
    mixOptionalBytes(hasher, options.css);
    mixOptionalBytes(hasher, options.public_dir);
}

fn mixSaStdFingerprint(allocator: std.mem.Allocator, hasher: *std.hash.Wyhash) !void {
    const std_root = try std.fs.path.join(allocator, &.{ build_config.repo_root, "sa_std" });
    defer allocator.free(std_root);
    mixBytes(hasher, build_config.repo_root);
    const fingerprint_value = try watch.fingerprintAll(allocator, std_root);
    mixU64(hasher, fingerprint_value);
}

fn mixPluginPathFingerprint(allocator: std.mem.Allocator, hasher: *std.hash.Wyhash, path: []const u8) !void {
    mixBytes(hasher, path);
    const stat = std.fs.cwd().statFile(path) catch |err| {
        mixBool(hasher, false);
        mixBytes(hasher, @errorName(err));
        return;
    };
    mixBool(hasher, true);
    mixU64(hasher, stat.size);
    mixI128(hasher, stat.mtime);
    var file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{}) catch |err| {
            mixBool(hasher, false);
            mixBytes(hasher, @errorName(err));
            return;
        }
    else
        std.fs.cwd().openFile(path, .{}) catch |err| {
            mixBool(hasher, false);
            mixBytes(hasher, @errorName(err));
            return;
        };
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 256 * 1024 * 1024);
    defer allocator.free(bytes);
    mixBool(hasher, true);
    mixBytes(hasher, bytes);
}

fn mixPluginEnvironmentFingerprint(allocator: std.mem.Allocator, hasher: *std.hash.Wyhash) !void {
    const value = std.process.getEnvVarOwned(allocator, "SA_PLUGINS_PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            mixBool(hasher, false);
            return;
        },
        else => return err,
    };
    defer allocator.free(value);

    mixBool(hasher, true);
    mixBytes(hasher, value);
    var parts = std.mem.splitScalar(u8, value, ':');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try mixPluginPathFingerprint(allocator, hasher, part);
    }
}

fn buildFingerprint(allocator: std.mem.Allocator, entry_sax: []const u8, watch_root: []const u8, options: BuildOptions) !u64 {
    const inputs = try devFingerprint(allocator, entry_sax, watch_root, options);
    var hasher = std.hash.Wyhash.init(0x5a17_b117_cace_a55a);
    mixBytes(&hasher, build_cache_version);
    try mixSaStdFingerprint(allocator, &hasher);
    try mixPluginEnvironmentFingerprint(allocator, &hasher);
    mixU64(&hasher, inputs.source);
    mixBool(&hasher, inputs.css != null);
    if (inputs.css) |css| mixU64(&hasher, css);
    mixBool(&hasher, inputs.public != null);
    if (inputs.public) |public| mixU64(&hasher, public);
    mixBuildOptions(&hasher, options);
    return hasher.final();
}

fn buildCacheManifestPath(allocator: std.mem.Allocator, dist_dir: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ dist_dir, ".sa_vite_build_cache" });
}

fn buildCacheFingerprintText(allocator: std.mem.Allocator, fingerprint: u64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}\n{x}\n", .{ build_cache_version, fingerprint });
}

fn readBuildCacheFingerprint(allocator: std.mem.Allocator, dist_dir: []const u8) !?u64 {
    const manifest_path = try buildCacheManifestPath(allocator, dist_dir);
    defer allocator.free(manifest_path);

    const bytes = std.fs.cwd().readFileAlloc(allocator, manifest_path, 4096) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const version = lines.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, version, " \t\r"), build_cache_version)) return null;
    const fingerprint_line = lines.next() orelse return null;
    const trimmed = std.mem.trim(u8, fingerprint_line, " \t\r");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u64, trimmed, 16) catch null;
}

fn writeBuildCacheFingerprint(allocator: std.mem.Allocator, dist_dir: []const u8, fingerprint: u64) !void {
    const manifest_path = try buildCacheManifestPath(allocator, dist_dir);
    defer allocator.free(manifest_path);
    const text = try buildCacheFingerprintText(allocator, fingerprint);
    defer allocator.free(text);
    try writeAllFile(manifest_path, text);
}

fn distFilePresent(allocator: std.mem.Allocator, dist_dir: []const u8, rel_path: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ dist_dir, rel_path });
    defer allocator.free(path);
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return stat.kind == .file and stat.size != 0;
}

fn buildOutputsPresent(allocator: std.mem.Allocator, dist_dir: []const u8, options: BuildOptions) !bool {
    if (!try distFilePresent(allocator, dist_dir, "app.wasm")) return false;
    if (!try distFilePresent(allocator, dist_dir, "app.sa")) return false;
    if (!try distFilePresent(allocator, dist_dir, "airlock.js")) return false;
    if (!try distFilePresent(allocator, dist_dir, "index.html")) return false;
    if (options.css) |css_path| {
        if (!try distFilePresent(allocator, dist_dir, std.fs.path.basename(css_path))) return false;
    }
    return true;
}

fn checkBuildCache(
    allocator: std.mem.Allocator,
    entry_sax: []const u8,
    dist_dir: []const u8,
    watch_root: []const u8,
    options: BuildOptions,
) !struct { status: BuildCacheStatus, fingerprint: u64 } {
    const fingerprint = try buildFingerprint(allocator, entry_sax, watch_root, options);
    const cached = try readBuildCacheFingerprint(allocator, dist_dir);
    if (cached != null and cached.? == fingerprint and try buildOutputsPresent(allocator, dist_dir, options)) {
        return .{ .status = .hit, .fingerprint = fingerprint };
    }
    return .{ .status = .miss, .fingerprint = fingerprint };
}

fn refreshBuildCacheHitAssets(allocator: std.mem.Allocator, dist_dir: []const u8, options: BuildOptions, stderr: anytype) !u8 {
    if (options.public_dir) |public_dir| {
        copyPublicDir(allocator, public_dir, "", dist_dir) catch |err| {
            try stderr.print("error: failed to copy public dir {s}: {}\n", .{ public_dir, err });
            return 1;
        };
    }
    if (options.css) |css_path| {
        const css_target = try std.fs.path.join(allocator, &.{ dist_dir, std.fs.path.basename(css_path) });
        defer allocator.free(css_target);
        copyFileTo(allocator, css_path, css_target) catch |err| {
            try stderr.print("error: failed to copy css {s}: {}\n", .{ css_path, err });
            return 1;
        };
    }
    return 0;
}

fn applyHtmlOptions(allocator: std.mem.Allocator, html: []const u8, options: BuildOptions) ![]u8 {
    var current = try allocator.dupe(u8, html);
    errdefer allocator.free(current);

    if (options.title) |title| {
        const updated = try injectTitle(allocator, current, title);
        allocator.free(current);
        current = updated;
    }

    if (options.css) |css_path| {
        const updated = try injectStylesheet(allocator, current, std.fs.path.basename(css_path));
        allocator.free(current);
        current = updated;
    }

    return current;
}

fn sourceFingerprint(allocator: std.mem.Allocator, entry_sax: []const u8, watch_root: []const u8, options: BuildOptions) !u64 {
    var hasher = std.hash.Wyhash.init(0x5a17_d3f5_a55a);
    var buf: [8]u8 = undefined;

    const sax_fp = try watch.fingerprint(allocator, watch_root);
    std.mem.writeInt(u64, &buf, sax_fp, .little);
    hasher.update(&buf);

    if (options.use_react) {
        for (options.includes) |include_file| {
            const include_path = try react_api.resolveIncludePath(allocator, entry_sax, include_file);
            defer allocator.free(include_path);
            const include_fp = try watch.fingerprintFile(allocator, include_path);
            std.mem.writeInt(u64, &buf, include_fp, .little);
            hasher.update(&buf);
        }
    }

    return hasher.final();
}

fn devFingerprint(allocator: std.mem.Allocator, entry_sax: []const u8, watch_root: []const u8, options: BuildOptions) !DevFingerprint {
    var out = DevFingerprint{
        .source = try sourceFingerprint(allocator, entry_sax, watch_root, options),
    };

    if (options.css) |css_path| {
        out.css = try watch.fingerprintFile(allocator, css_path);
    }

    if (options.public_dir) |public_dir| {
        out.public = try watch.fingerprintAll(allocator, public_dir);
    }

    return out;
}

fn refreshAssetsOnly(
    allocator: std.mem.Allocator,
    dist_dir: []const u8,
    options: BuildOptions,
    refresh_css: bool,
    refresh_public: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var refreshed = false;

    if (refresh_public) {
        if (options.public_dir) |public_dir| {
            copyPublicDir(allocator, public_dir, "", dist_dir) catch |err| {
                try stderr.print("error: failed to copy public dir {s}: {}\n", .{ public_dir, err });
                return 1;
            };
            refreshed = true;
            try stdout.print("✓ vite public assets refreshed\n", .{});
        }
    }

    if (refresh_css) {
        if (options.css) |css_path| {
            const css_target = try std.fs.path.join(allocator, &.{ dist_dir, std.fs.path.basename(css_path) });
            defer allocator.free(css_target);
            copyFileTo(allocator, css_path, css_target) catch |err| {
                try stderr.print("error: failed to copy css {s}: {}\n", .{ css_path, err });
                return 1;
            };
            refreshed = true;
            try stdout.print("✓ vite css refreshed\n", .{});
        }
    }

    if (!refreshed) {
        try stdout.print("✓ vite assets unchanged\n", .{});
    }
    return 0;
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
    options: BuildOptions,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (options.use_react) {
        var compiled = react_api.compileBrowserArtifacts(allocator, entry_sax, options.includes, stderr) catch |err| {
            try stderr.print("error: React/SAX compilation failed: {}\n", .{err});
            return 1;
        };
        defer compiled.deinit(allocator);

        const source_dir_abs = try sourceDirAbs(allocator, entry_sax);
        defer allocator.free(source_dir_abs);
        const generated_source_path = try std.fmt.allocPrint(allocator, "{s}/{s}.sa", .{ source_dir_abs, sourceStem(entry_sax) });
        defer allocator.free(generated_source_path);

        const wasm_path = try std.fs.path.join(allocator, &.{ dist_dir, "app.wasm" });
        defer allocator.free(wasm_path);
        const build_code = try react_api.buildBrowserWasmFromSourceText(
            allocator,
            generated_source_path,
            compiled.sa_code.items,
            wasm_path,
            false,
            .release_small,
            stderr,
        );
        if (build_code != 0) return build_code;

        const sa_path = try std.fs.path.join(allocator, &.{ dist_dir, "app.sa" });
        defer allocator.free(sa_path);
        const airlock_path = try std.fs.path.join(allocator, &.{ dist_dir, "airlock.js" });
        defer allocator.free(airlock_path);
        const html_path = try std.fs.path.join(allocator, &.{ dist_dir, "index.html" });
        defer allocator.free(html_path);

        if (options.public_dir) |public_dir| {
            copyPublicDir(allocator, public_dir, "", dist_dir) catch |err| {
                try stderr.print("error: failed to copy public dir {s}: {}\n", .{ public_dir, err });
                return 1;
            };
        }

        if (options.css) |css_path| {
            const css_target = try std.fs.path.join(allocator, &.{ dist_dir, std.fs.path.basename(css_path) });
            defer allocator.free(css_target);
            copyFileTo(allocator, css_path, css_target) catch |err| {
                try stderr.print("error: failed to copy css {s}: {}\n", .{ css_path, err });
                return 1;
            };
        }

        const live_html = if (inject_reload_client)
            try reload_client.injectInto(allocator, compiled.index_html.items)
        else
            try allocator.dupe(u8, compiled.index_html.items);
        defer allocator.free(live_html);

        const injected_html = try applyHtmlOptions(allocator, live_html, options);
        defer allocator.free(injected_html);

        try writeAllFile(sa_path, compiled.sa_code.items);
        try writeAllFile(airlock_path, compiled.airlock_js.items);
        try writeAllFile(html_path, injected_html);

        try stdout.print("✓ vite react build refreshed\n", .{});
        try stdout.print("  .sa: {s}\n", .{sa_path});
        try stdout.print("  app.wasm: {s}\n", .{wasm_path});
        try stdout.print("  airlock.js: {s}\n", .{airlock_path});
        try stdout.print("  index.html: {s}\n", .{html_path});
        return 0;
    }

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

    if (options.public_dir) |public_dir| {
        copyPublicDir(allocator, public_dir, "", dist_dir) catch |err| {
            try stderr.print("error: failed to copy public dir {s}: {}\n", .{ public_dir, err });
            return 1;
        };
    }

    if (options.css) |css_path| {
        const css_target = try std.fs.path.join(allocator, &.{ dist_dir, std.fs.path.basename(css_path) });
        defer allocator.free(css_target);
        copyFileTo(allocator, css_path, css_target) catch |err| {
            try stderr.print("error: failed to copy css {s}: {}\n", .{ css_path, err });
            return 1;
        };
    }

    const live_html = if (inject_reload_client)
        try reload_client.injectInto(allocator, compiled.index_html.items)
    else
        try allocator.dupe(u8, compiled.index_html.items);
    defer allocator.free(live_html);

    const injected_html = try applyHtmlOptions(allocator, live_html, options);
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
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".sa")) return "text/plain";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
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

fn staticRelativePathWithIndex(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
    const relative = try staticRelativePath(target);
    if (std.mem.endsWith(u8, relative, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}index.html", .{relative});
    }
    return try allocator.dupe(u8, relative);
}

fn sendResponse(request: *http_api.HttpRequest, status: std.http.Status, content_type: []const u8, body: []const u8) !void {
    const response = try http_api.HttpResponse.init(request, @intFromEnum(status));
    defer response.deinit();
    try response.setContentType(content_type);
    try response.send(body);
}

fn serveStaticFile(allocator: std.mem.Allocator, request: *http_api.HttpRequest, dist_dir: []const u8, target: []const u8) !void {
    const relative = staticRelativePathWithIndex(allocator, target) catch {
        try sendResponse(request, .bad_request, "text/plain", "bad request\n");
        return;
    };
    defer allocator.free(relative);
    const full_path = try std.fs.path.join(allocator, &.{ dist_dir, relative });
    defer allocator.free(full_path);
    const body = std.fs.cwd().readFileAlloc(allocator, full_path, 32 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            try sendResponse(request, .not_found, "text/plain", "not found\n");
            return;
        },
        error.IsDir => {
            const index_path = try std.fs.path.join(allocator, &.{ full_path, "index.html" });
            defer allocator.free(index_path);
            const index_body = std.fs.cwd().readFileAlloc(allocator, index_path, 32 * 1024 * 1024) catch |index_err| switch (index_err) {
                error.FileNotFound => {
                    try sendResponse(request, .not_found, "text/plain", "not found\n");
                    return;
                },
                else => return index_err,
            };
            defer allocator.free(index_body);
            try sendResponse(request, .ok, "text/html", index_body);
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
    options: BuildOptions,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const dist_dir = if (dist_dir_opt) |dir| try allocator.dupe(u8, dir) else try defaultDistDir(allocator, entry_sax);
    defer allocator.free(dist_dir);
    try std.fs.cwd().makePath(dist_dir);

    const watch_root = try sourceDirAbs(allocator, entry_sax);
    defer allocator.free(watch_root);
    const cache = checkBuildCache(allocator, entry_sax, dist_dir, watch_root, options) catch |err| blk: {
        try stderr.print("warning: vite build cache unavailable: {}\n", .{err});
        break :blk null;
    };
    if (cache) |cache_state| {
        if (cache_state.status == .hit) {
            const asset_code = try refreshBuildCacheHitAssets(allocator, dist_dir, options, stderr);
            if (asset_code != 0) return asset_code;
            try stdout.print("✓ vite build cache hit\n", .{});
            try stdout.print("  dist: {s}\n", .{dist_dir});
            return 0;
        }
    }

    const code = try buildOnce(allocator, entry_sax, dist_dir, false, options, stdout, stderr);
    if (code == 0) {
        if (cache) |cache_state| {
            writeBuildCacheFingerprint(allocator, dist_dir, cache_state.fingerprint) catch |err| {
                try stderr.print("warning: failed to write vite build cache manifest: {}\n", .{err});
            };
        }
    }
    return code;
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

    const build_options = BuildOptions{ .use_react = options.use_react, .includes = options.includes, .title = options.title, .css = options.css, .public_dir = options.public_dir };

    if (try buildOnce(allocator, options.entry_sax, dist_dir, true, build_options, stdout, stderr) != 0) return 1;

    var state = ServerState{
        .allocator = allocator,
        .dist_dir = dist_dir,
        .build_version = std.atomic.Value(u64).init(1),
        .build_error = std.atomic.Value(bool).init(false),
    };
    return try serveLoop(allocator, &state, options.entry_sax, options.port, options.debounce_ms, options.stop_signal, .dev, build_options, stdout, stderr);
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
    return try serveLoop(allocator, &state, null, options.port, 0, null, .preview, .{}, stdout, stderr);
}

fn pushBuildEvent(state: *ServerState, failed: bool) void {
    state.build_error.store(failed, .seq_cst);
    _ = state.build_version.fetchAdd(1, .seq_cst);
}

fn isTransientAcceptError(err: anyerror) bool {
    return switch (err) {
        error.WouldBlock,
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        error.EndOfStream,
        error.HttpHeadersInvalid,
        error.HttpHeadersExceededSize,
        => true,
        else => false,
    };
}

fn serveLoop(
    allocator: std.mem.Allocator,
    state: *ServerState,
    entry_sax: ?[]const u8,
    port: u16,
    debounce_ms: u64,
    stop_signal: ?*std.atomic.Value(bool),
    mode: ServerMode,
    build_options: BuildOptions,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const watch_root = if (entry_sax) |path| try sourceDirAbs(allocator, path) else null;
    defer if (watch_root) |root| allocator.free(root);

    var last_fingerprint: ?DevFingerprint = null;
    if (mode == .dev) {
        last_fingerprint = devFingerprint(allocator, entry_sax.?, watch_root.?, build_options) catch |err| blk: {
            try stderr.print("error: failed to scan dev inputs under {s}: {}\n", .{ watch_root.?, err });
            break :blk null;
        };
    }

    var server = try http_api.HttpServer.init(allocator);
    defer server.deinit();
    try server.startWithOptions("127.0.0.1", port, .{ .reuse_address = true, .force_nonblocking = true });
    try stdout.print("✓ vite {s} server listening on http://127.0.0.1:{d}\n", .{ @tagName(mode), port });

    const scan_interval_ms = devScanIntervalMs(debounce_ms, build_options.public_dir != null);
    var next_scan_ns: i128 = 0;
    while (true) {
        if (stop_signal) |signal| {
            if (signal.load(.seq_cst)) return 0;
        }

        if (mode == .dev) {
            const now_ns = std.time.nanoTimestamp();
            if (now_ns >= next_scan_ns) {
                next_scan_ns = now_ns + @as(i128, @intCast(scan_interval_ms * ns_per_ms));
                const path = entry_sax.?;
                const current_fingerprint = devFingerprint(allocator, path, watch_root.?, build_options) catch |err| {
                    try stderr.print("error: failed to scan dev inputs under {s}: {}\n", .{ watch_root.?, err });
                    std.Thread.sleep(100 * ns_per_ms);
                    continue;
                };
                if (last_fingerprint == null) {
                    last_fingerprint = current_fingerprint;
                } else if (!current_fingerprint.eql(last_fingerprint.?)) {
                    std.Thread.sleep(debounce_ms * ns_per_ms);
                    const previous_fingerprint = last_fingerprint.?;
                    const debounced_fingerprint = devFingerprint(allocator, path, watch_root.?, build_options) catch current_fingerprint;
                    last_fingerprint = debounced_fingerprint;

                    const source_changed = debounced_fingerprint.source != previous_fingerprint.source;
                    const css_changed = debounced_fingerprint.css != previous_fingerprint.css;
                    const public_changed = debounced_fingerprint.public != previous_fingerprint.public;
                    const build_code = if (source_changed)
                        try buildOnce(allocator, path, state.dist_dir, true, build_options, stdout, stderr)
                    else
                        try refreshAssetsOnly(allocator, state.dist_dir, build_options, css_changed, public_changed, stdout, stderr);
                    if (build_code == 0) {
                        pushBuildEvent(state, false);
                        try stdout.print("✓ vite pushed reload version {d}\n", .{state.build_version.load(.seq_cst)});
                    } else {
                        pushBuildEvent(state, true);
                        try stderr.print("error: vite rebuild failed; pushed error version {d}\n", .{state.build_version.load(.seq_cst)});
                    }
                }
            }
        }

        const request = server.accept() catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(50 * ns_per_ms);
                continue;
            }
            if (isTransientAcceptError(err)) continue;
            try stderr.print("error: vite accept failed: {}\n", .{err});
            std.Thread.sleep(50 * ns_per_ms);
            continue;
        };
        handleRequest(state, request) catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => continue,
            else => {
                try stderr.print("error: vite request failed: {}\n", .{err});
                continue;
            },
        };
    }
}

test "static relative path rejects traversal" {
    try std.testing.expectError(error.InvalidPath, staticRelativePath("/../secret"));
    try std.testing.expectEqualStrings("index.html", try staticRelativePath("/"));
    try std.testing.expectEqualStrings("airlock.js", try staticRelativePath("/airlock.js?x=1"));
}

test "dev fingerprint separates source css and public inputs" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "app.sax", .data = "<Component name=\"A\"><div></div></Component>" });
    try tmp.dir.writeFile(.{ .sub_path = "style.css", .data = "body{color:#111}" });
    try tmp.dir.makePath("public");
    try tmp.dir.writeFile(.{ .sub_path = "public/info.txt", .data = "asset-a" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const entry_path = try std.fs.path.join(std.testing.allocator, &.{ root, "app.sax" });
    defer std.testing.allocator.free(entry_path);
    const css_path = try std.fs.path.join(std.testing.allocator, &.{ root, "style.css" });
    defer std.testing.allocator.free(css_path);
    const public_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "public" });
    defer std.testing.allocator.free(public_dir);

    const options = BuildOptions{ .css = css_path, .public_dir = public_dir };
    const before = try devFingerprint(std.testing.allocator, entry_path, root, options);

    std.Thread.sleep(20 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "style.css", .data = "body{color:#222;background:#fff}" });
    const css_after = try devFingerprint(std.testing.allocator, entry_path, root, options);
    try std.testing.expectEqual(before.source, css_after.source);
    try std.testing.expect(before.css != css_after.css);
    try std.testing.expectEqual(before.public, css_after.public);

    std.Thread.sleep(20 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "public/info.txt", .data = "asset-b-updated" });
    const public_after = try devFingerprint(std.testing.allocator, entry_path, root, options);
    try std.testing.expectEqual(css_after.source, public_after.source);
    try std.testing.expectEqual(css_after.css, public_after.css);
    try std.testing.expect(css_after.public != public_after.public);

    std.Thread.sleep(20 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "app.sax", .data = "<Component name=\"A\"><p>x</p></Component>" });
    const source_after = try devFingerprint(std.testing.allocator, entry_path, root, options);
    try std.testing.expect(public_after.source != source_after.source);
}

test "build cache manifest and required outputs are validated" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const dist_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "dist" });
    defer std.testing.allocator.free(dist_dir);
    try std.fs.cwd().makePath(dist_dir);

    try writeBuildCacheFingerprint(std.testing.allocator, dist_dir, 0x1234);
    try std.testing.expectEqual(@as(?u64, 0x1234), try readBuildCacheFingerprint(std.testing.allocator, dist_dir));
    try std.testing.expect(!try buildOutputsPresent(std.testing.allocator, dist_dir, .{}));

    const wasm_path = try std.fs.path.join(std.testing.allocator, &.{ dist_dir, "app.wasm" });
    defer std.testing.allocator.free(wasm_path);
    const sa_path = try std.fs.path.join(std.testing.allocator, &.{ dist_dir, "app.sa" });
    defer std.testing.allocator.free(sa_path);
    const airlock_path = try std.fs.path.join(std.testing.allocator, &.{ dist_dir, "airlock.js" });
    defer std.testing.allocator.free(airlock_path);
    const html_path = try std.fs.path.join(std.testing.allocator, &.{ dist_dir, "index.html" });
    defer std.testing.allocator.free(html_path);
    try writeAllFile(wasm_path, "wasm");
    try writeAllFile(sa_path, "sa");
    try writeAllFile(airlock_path, "js");
    try writeAllFile(html_path, "html");
    try std.testing.expect(try buildOutputsPresent(std.testing.allocator, dist_dir, .{}));
}

test "build fingerprint includes build options" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "app.sax", .data = "<Component name=\"A\"><div></div></Component>" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const entry_path = try std.fs.path.join(std.testing.allocator, &.{ root, "app.sax" });
    defer std.testing.allocator.free(entry_path);

    const first = try buildFingerprint(std.testing.allocator, entry_path, root, .{ .title = "A" });
    const second = try buildFingerprint(std.testing.allocator, entry_path, root, .{ .title = "B" });
    try std.testing.expect(first != second);
}

test "build fingerprint changes when explicit react include changes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "app.sax", .data = "<Component name=\"A\"><div></div></Component>" });
    try tmp.dir.writeFile(.{ .sub_path = "material.sax", .data = "<Component name=\"One\"><div></div></Component>" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const entry_path = try std.fs.path.join(std.testing.allocator, &.{ root, "app.sax" });
    defer std.testing.allocator.free(entry_path);
    const include_path = try std.fs.path.join(std.testing.allocator, &.{ root, "material.sax" });
    defer std.testing.allocator.free(include_path);

    const before = try buildFingerprint(std.testing.allocator, entry_path, root, .{ .use_react = true, .includes = &.{include_path} });
    std.Thread.sleep(20 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "material.sax", .data = "<Component name=\"Two\"><span></span></Component>" });
    const after = try buildFingerprint(std.testing.allocator, entry_path, root, .{ .use_react = true, .includes = &.{include_path} });
    try std.testing.expect(before != after);
}

test "plugin fingerprint changes for same-size content edits" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "libplugin.so", .data = "aaaa" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const plugin_path = try std.fs.path.join(std.testing.allocator, &.{ root, "libplugin.so" });
    defer std.testing.allocator.free(plugin_path);

    var before_hasher = std.hash.Wyhash.init(0x5a17_71a6_1d11_a55a);
    try mixPluginPathFingerprint(std.testing.allocator, &before_hasher, plugin_path);
    const before = before_hasher.final();

    try tmp.dir.writeFile(.{ .sub_path = "libplugin.so", .data = "bbbb" });
    var after_hasher = std.hash.Wyhash.init(0x5a17_71a6_1d11_a55a);
    try mixPluginPathFingerprint(std.testing.allocator, &after_hasher, plugin_path);
    const after = after_hasher.final();

    try std.testing.expect(before != after);
}

test "dev scan interval is throttled for small debounce windows" {
    try std.testing.expectEqual(@as(u64, 250), devScanIntervalMs(20, false));
    try std.testing.expectEqual(@as(u64, 250), devScanIntervalMs(250, false));
    try std.testing.expectEqual(@as(u64, 500), devScanIntervalMs(500, false));
    try std.testing.expectEqual(@as(u64, 1000), devScanIntervalMs(20, true));
    try std.testing.expectEqual(@as(u64, 1200), devScanIntervalMs(1200, true));
}
