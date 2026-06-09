const std = @import("std");
const plugin_api = @import("plugin_api");
const dev_server = @import("dev_server.zig");
pub usingnamespace @import("vite_saasm_api.zig");

const skills = [_]plugin_api.SkillSection{
    .{
        .name = "vite dev server",
        .summary = "SAX dev server orchestration with browser reload planning",
        .items = &.{
            "vite dev <entry.sax>      # watch + rebuild + hot reload on http://127.0.0.1:<port>",
            "vite build <entry.sax>    # one-shot production build delegated to sax",
            "vite preview              # serve a prior build",
            "edits to .sax trigger automatic browser reload without a JS/TS toolchain",
        },
    },
};

const StreamCtx = struct {
    stream: plugin_api.HostStream,
};

const CaptureCtx = struct {
    buffer: *std.ArrayList(u8),
};

fn writeAll(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
    const self = @as(*const StreamCtx, @ptrCast(@alignCast(ctx)));
    const write_all = self.stream.write_all orelse return error.WriteFailed;
    if (write_all(self.stream.ctx, bytes.ptr, bytes.len) != @intFromEnum(plugin_api.AbiStatus.ok)) return error.WriteFailed;
    return bytes.len;
}

fn captureWriteAll(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    const self = @as(*CaptureCtx, @ptrCast(@alignCast(ctx.?)));
    self.buffer.appendSlice(bytes[0..len]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

fn makeCaptureStream(ctx: *CaptureCtx) plugin_api.HostStream {
    return .{ .ctx = ctx, .write_all = captureWriteAll };
}

fn cArgvToSlice(argv: []const [*:0]const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(out);
    for (argv, 0..) |arg, idx| {
        out[idx] = std.mem.span(arg);
    }
    return out;
}

fn writeUsage(writer: std.io.AnyWriter) !void {
    try writer.writeAll(
        \\usage: sa vite <dev|build|preview> [args...]\n
        \\  sa vite dev <entry.sax>\n
        \\  sa vite build <entry.sax>\n
        \\  sa vite preview [dist-dir]\n
    );
}

fn parsePort(text: []const u8) !u16 {
    return std.fmt.parseInt(u16, text, 10) catch error.InvalidPort;
}

const DevArgs = struct {
    entry: []const u8,
    dist_dir: ?[]const u8 = null,
    port: u16 = 5173,
    debounce_ms: u64 = 80,
};

fn parseEntryCommandArgs(argv: []const []const u8, start: usize) !DevArgs {
    if (argv.len <= start) return error.MissingEntry;
    var out = DevArgs{ .entry = argv[start] };
    var idx = start + 1;
    while (idx < argv.len) : (idx += 1) {
        const arg = argv[idx];
        if (std.mem.eql(u8, arg, "--out-dir")) {
            idx += 1;
            if (idx >= argv.len) return error.MissingOptionValue;
            out.dist_dir = argv[idx];
        } else if (std.mem.eql(u8, arg, "--port")) {
            idx += 1;
            if (idx >= argv.len) return error.MissingOptionValue;
            out.port = try parsePort(argv[idx]);
        } else if (std.mem.eql(u8, arg, "--debounce-ms")) {
            idx += 1;
            if (idx >= argv.len) return error.MissingOptionValue;
            out.debounce_ms = std.fmt.parseInt(u64, argv[idx], 10) catch return error.InvalidDebounce;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return out;
}

fn parsePreviewArgs(argv: []const []const u8, start: usize) !dev_server.PreviewOptions {
    var out = dev_server.PreviewOptions{};
    var dist_seen = false;
    var idx = start;
    while (idx < argv.len) : (idx += 1) {
        const arg = argv[idx];
        if (std.mem.eql(u8, arg, "--port")) {
            idx += 1;
            if (idx >= argv.len) return error.MissingOptionValue;
            out.port = try parsePort(argv[idx]);
        } else if (!dist_seen) {
            out.dist_dir = arg;
            dist_seen = true;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return out;
}

fn writeCliError(writer: std.io.AnyWriter, err: anyerror, subcommand: []const u8) !void {
    const message = switch (err) {
        error.MissingEntry => "missing entry .sax file",
        error.MissingOptionValue => "missing option value",
        error.InvalidPort => "invalid port",
        error.InvalidDebounce => "invalid debounce window",
        error.UnexpectedArgument => "unexpected argument",
        else => @errorName(err),
    };
    try writer.print("error[SA-VITE-CLI]: {s}\n", .{message});
    if (std.mem.eql(u8, subcommand, "dev")) {
        try writer.writeAll("  help: usage: sa vite dev <entry.sax> [--out-dir <dir>] [--port <port>] [--debounce-ms <ms>]\n");
    } else if (std.mem.eql(u8, subcommand, "build")) {
        try writer.writeAll("  help: usage: sa vite build <entry.sax> [--out-dir <dir>]\n");
    } else if (std.mem.eql(u8, subcommand, "preview")) {
        try writer.writeAll("  help: usage: sa vite preview [dist-dir] [--port <port>]\n");
    }
}

fn runViteCommand(ctx: *const plugin_api.Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 2 or !std.mem.eql(u8, argv[1], "vite")) return null;
    if (argv.len < 3) {
        try writeUsage(stderr);
        return 1;
    }

    const subcommand = argv[2];
    if (std.mem.eql(u8, subcommand, "dev")) {
        const parsed = parseEntryCommandArgs(argv, 3) catch |err| {
            try writeCliError(stderr, err, subcommand);
            return 1;
        };
        return try dev_server.runDev(ctx.allocator, .{
            .entry_sax = parsed.entry,
            .dist_dir = parsed.dist_dir,
            .port = parsed.port,
            .debounce_ms = parsed.debounce_ms,
        }, stdout, stderr);
    }
    if (std.mem.eql(u8, subcommand, "build")) {
        const parsed = parseEntryCommandArgs(argv, 3) catch |err| {
            try writeCliError(stderr, err, subcommand);
            return 1;
        };
        return try dev_server.runBuild(ctx.allocator, parsed.entry, parsed.dist_dir, stdout, stderr);
    }
    if (std.mem.eql(u8, subcommand, "preview")) {
        const parsed = parsePreviewArgs(argv, 3) catch |err| {
            try writeCliError(stderr, err, subcommand);
            return 1;
        };
        return try dev_server.runPreview(ctx.allocator, parsed, stdout, stderr);
    }

    try stderr.print("error[SA-VITE-CLI]: unknown vite subcommand: {s}\n", .{subcommand});
    try writeUsage(stderr);
    return 1;
}

fn runViteCommandAbi(ctx: *const plugin_api.Context, argv: [*]const [*:0]const u8, argv_len: usize, stdout: plugin_api.HostStream, stderr: plugin_api.HostStream, out_code: *u8) callconv(.c) u32 {
    out_code.* = 0;
    var stdout_ctx = StreamCtx{ .stream = stdout };
    var stderr_ctx = StreamCtx{ .stream = stderr };
    const stdout_writer = std.io.AnyWriter{ .context = &stdout_ctx, .writeFn = writeAll };
    const stderr_writer = std.io.AnyWriter{ .context = &stderr_ctx, .writeFn = writeAll };
    const args = cArgvToSlice(argv[0..argv_len], ctx.allocator) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer ctx.allocator.free(args);

    const result = runViteCommand(ctx, args, stdout_writer, stderr_writer) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    if (result) |code| {
        out_code.* = code;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    }
    return @intFromEnum(plugin_api.AbiStatus.unknown_command);
}

const descriptor = plugin_api.PluginDescriptor{
    .abi_version = plugin_api.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin_api.PluginDescriptor))),
    .name = "vite",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = runViteCommandAbi,
    .skills_ptr = skills[0..].ptr,
    .skills_len = skills.len,
};

pub export const saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = descriptor;

pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin_api.PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}

test "vite plugin exports runtime descriptor and skills" {
    const exported = &saasm_plugin_descriptor_v1;
    try std.testing.expectEqual(plugin_api.abi_version, exported.abi_version);
    try std.testing.expectEqualStrings("vite", std.mem.span(exported.name));
    try std.testing.expectEqual(@as(usize, 1), exported.skills_len);
    try std.testing.expectEqualStrings("vite dev server", exported.skills_ptr[0].name);
}

test "vite command validates missing entry" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    var stdout_ctx = CaptureCtx{ .buffer = &stdout_buf };
    var stderr_ctx = CaptureCtx{ .buffer = &stderr_buf };
    var out_code: u8 = 255;
    const c_argv = [_][*:0]const u8{ "sa", "vite", "dev" };

    const status = runViteCommandAbi(
        &plugin_api.Context{ .allocator = std.testing.allocator },
        c_argv[0..].ptr,
        c_argv.len,
        makeCaptureStream(&stdout_ctx),
        makeCaptureStream(&stderr_ctx),
        &out_code,
    );

    try std.testing.expectEqual(@as(u32, @intFromEnum(plugin_api.AbiStatus.ok)), status);
    try std.testing.expectEqual(@as(u8, 1), out_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "missing entry .sax file"));
}

test "vite command parses build options" {
    const parsed = try parseEntryCommandArgs(&.{ "sa", "vite", "build", "app.sax", "--out-dir", "dist-vite", "--port", "5180" }, 3);
    try std.testing.expectEqualStrings("app.sax", parsed.entry);
    try std.testing.expectEqualStrings("dist-vite", parsed.dist_dir.?);
    try std.testing.expectEqual(@as(u16, 5180), parsed.port);
}

test "vite command parses debounce option" {
    const parsed = try parseEntryCommandArgs(&.{ "sa", "vite", "dev", "app.sax", "--debounce-ms", "25" }, 3);
    try std.testing.expectEqual(@as(u64, 25), parsed.debounce_ms);
}
