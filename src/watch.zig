// sa_plugin_vite — file-tree watcher (PLACEHOLDER SCAFFOLD)
//
// Watches a directory tree of .sax sources (multi-component), unlike sax's single-file mtime poll.
//
// TODO(Phase 2): prefer node plugin's vfs_watch (sa_node_plugin_vfs_watch / watcher_next,
//                node_extra.sai:823-826) when available; otherwise recursive mtime scan.
// TODO(Phase 2): return the changed file set so the orchestrator can do a minimal rebuild.

const std = @import("std");

pub const WatchEvent = struct {
    path: []const u8,
    // TODO(Phase 2): kind (created/modified/deleted), mtime.
};

// TODO(Phase 2): pub fn poll(allocator, root) ![]WatchEvent { ... }

comptime {
    // PLACEHOLDER. See plan.md Phase 2.
}
