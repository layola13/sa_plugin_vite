const std = @import("std");

const skip_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-out", "dist", "node_modules" };

fn shouldSkipDir(name: []const u8) bool {
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

fn mixFile(hasher: *std.hash.Wyhash, rel_path: []const u8, stat: std.fs.File.Stat) void {
    hasher.update(rel_path);
    hasher.update("\x00");
    var buf: [16]u8 = undefined;
    std.mem.writeInt(i128, &buf, stat.mtime, .little);
    hasher.update(&buf);
    var size_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &size_buf, stat.size, .little);
    hasher.update(&size_buf);
}

fn scanDir(allocator: std.mem.Allocator, root: []const u8, rel: []const u8, hasher: *std.hash.Wyhash, count: *u64) !void {
    const dir_path = if (rel.len == 0) try allocator.dupe(u8, root) else try std.fs.path.join(allocator, &.{ root, rel });
    defer allocator.free(dir_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipDir(entry.name)) continue;
            const child_rel = if (rel.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ rel, entry.name });
            defer allocator.free(child_rel);
            try scanDir(allocator, root, child_rel, hasher, count);
            continue;
        }
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sax")) continue;

        const rel_path = if (rel.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ rel, entry.name });
        defer allocator.free(rel_path);
        const full_path = try std.fs.path.join(allocator, &.{ root, rel_path });
        defer allocator.free(full_path);
        const stat = try std.fs.cwd().statFile(full_path);
        mixFile(hasher, rel_path, stat);
        count.* += 1;
    }
}

pub fn fingerprint(allocator: std.mem.Allocator, root: []const u8) !u64 {
    var hasher = std.hash.Wyhash.init(0x5a17_710e_d15c_a55a);
    var count: u64 = 0;
    try scanDir(allocator, root, "", &hasher, &count);
    var count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_buf, count, .little);
    hasher.update(&count_buf);
    return hasher.final();
}

test "fingerprint changes for sax edits" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "app.sax", .data = "<Component name=\"A\"><div></div></Component>" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const before = try fingerprint(std.testing.allocator, root);
    std.Thread.sleep(1 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "app.sax", .data = "<Component name=\"A\"><p>x</p></Component>" });
    const after = try fingerprint(std.testing.allocator, root);
    try std.testing.expect(before != after);
}

test "fingerprint includes nested sax files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("components");
    try tmp.dir.writeFile(.{ .sub_path = "app.sax", .data = "<Component name=\"A\"><div></div></Component>" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const before = try fingerprint(std.testing.allocator, root);
    try tmp.dir.writeFile(.{ .sub_path = "components/child.sax", .data = "<Component name=\"B\"><div></div></Component>" });
    const after = try fingerprint(std.testing.allocator, root);
    try std.testing.expect(before != after);
}
