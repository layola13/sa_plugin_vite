const std = @import("std");
const plugin_api = @import("plugin_api");
const dev_server = @import("dev_server.zig");

const allocator = std.heap.page_allocator;

const DevSession = struct {
    entry_sax: ?[]u8 = null,
    dist_dir: ?[]u8 = null,
    port: u16 = 5173,
    debounce_ms: u64 = 80,
    stop_signal: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn deinit(self: *DevSession) void {
        if (self.entry_sax) |entry| allocator.free(entry);
        if (self.dist_dir) |dir| allocator.free(dir);
        allocator.destroy(self);
    }

    fn setEntry(self: *DevSession, entry: []const u8) !void {
        if (entry.len == 0) return error.InvalidEntry;
        const copied = try allocator.dupe(u8, entry);
        if (self.entry_sax) |old| allocator.free(old);
        self.entry_sax = copied;
    }

    fn setOutDir(self: *DevSession, out_dir: []const u8) !void {
        if (out_dir.len == 0) {
            if (self.dist_dir) |old| allocator.free(old);
            self.dist_dir = null;
            return;
        }
        const copied = try allocator.dupe(u8, out_dir);
        if (self.dist_dir) |old| allocator.free(old);
        self.dist_dir = copied;
    }
};

fn sessionFrom(handle: ?*anyopaque) ?*DevSession {
    const ptr = handle orelse return null;
    return @as(*DevSession, @ptrCast(@alignCast(ptr)));
}

pub export fn sa_vite_dev_new(out_handle: ?*?*anyopaque) u32 {
    const slot = out_handle orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const session = allocator.create(DevSession) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    session.* = .{};
    slot.* = @ptrCast(session);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_vite_dev_set_entry(handle: ?*anyopaque, path_ptr: ?[*]const u8, path_len: u64) u32 {
    const session = sessionFrom(handle) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const path = path_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    session.setEntry(path[0..@intCast(path_len)]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_vite_dev_set_out_dir(handle: ?*anyopaque, path_ptr: ?[*]const u8, path_len: u64) u32 {
    const session = sessionFrom(handle) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    if (path_len == 0) {
        session.setOutDir("") catch return @intFromEnum(plugin_api.AbiStatus.failed);
        return @intFromEnum(plugin_api.AbiStatus.ok);
    }
    const path = path_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    session.setOutDir(path[0..@intCast(path_len)]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_vite_dev_set_port(handle: ?*anyopaque, port: u16) u32 {
    const session = sessionFrom(handle) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    session.port = port;
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_vite_dev_set_debounce_ms(handle: ?*anyopaque, debounce_ms: u64) u32 {
    const session = sessionFrom(handle) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    session.debounce_ms = debounce_ms;
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_vite_dev_run(handle: ?*anyopaque) u32 {
    const session = sessionFrom(handle) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const entry = session.entry_sax orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    session.stop_signal.store(false, .seq_cst);

    const code = dev_server.runDev(allocator, .{
        .entry_sax = entry,
        .dist_dir = session.dist_dir,
        .port = session.port,
        .debounce_ms = session.debounce_ms,
        .stop_signal = &session.stop_signal,
    }, std.io.getStdOut().writer(), std.io.getStdErr().writer()) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    if (code == 0) return @intFromEnum(plugin_api.AbiStatus.ok);
    return @intFromEnum(plugin_api.AbiStatus.failed);
}

pub export fn sa_vite_dev_stop(handle: ?*anyopaque) u32 {
    const session = sessionFrom(handle) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    session.stop_signal.store(true, .seq_cst);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_vite_dev_free(handle: ?*anyopaque) u32 {
    const session = sessionFrom(handle) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    session.stop_signal.store(true, .seq_cst);
    session.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

test "vite dev session ABI stores options and frees handle" {
    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), sa_vite_dev_new(&handle));
    defer _ = sa_vite_dev_free(handle);

    const session = sessionFrom(handle).?;
    const entry = "examples/counter.sax";
    const out_dir = "zig-cache/vite-dist";
    try std.testing.expectEqual(@as(u32, 0), sa_vite_dev_set_entry(handle, entry.ptr, entry.len));
    try std.testing.expectEqual(@as(u32, 0), sa_vite_dev_set_out_dir(handle, out_dir.ptr, out_dir.len));
    try std.testing.expectEqual(@as(u32, 0), sa_vite_dev_set_port(handle, 5199));
    try std.testing.expectEqual(@as(u32, 0), sa_vite_dev_set_debounce_ms(handle, 25));

    try std.testing.expectEqualStrings(entry, session.entry_sax.?);
    try std.testing.expectEqualStrings(out_dir, session.dist_dir.?);
    try std.testing.expectEqual(@as(u16, 5199), session.port);
    try std.testing.expectEqual(@as(u64, 25), session.debounce_ms);
}
