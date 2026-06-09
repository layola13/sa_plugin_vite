// sa_plugin_vite — dev server main loop (PLACEHOLDER SCAFFOLD)
//
// Responsibility: watch -> debounce -> rebuild (via sax) -> serve dist -> signal /__sax_live.
// This REPLACES the single-file mtime poll in sa_plugin_sax's devServerLoop with a richer,
// reusable orchestrator. It does NOT reimplement compilation or HTTP.
//
// Reference for the existing single-file loop:
//   ../sa_plugin_sax/src/sax/cli.zig : devServerLoop (lines ~431-485)
//
// TODO(Phase 1): bind http-server (resp_stream_*) and expose:
//   GET /            -> dist/index.html (with injected reload client)
//   GET /app.wasm    -> dist/app.wasm
//   GET /airlock.js  -> dist/airlock.js
//   GET /__sax_live  -> text/event-stream, push "data: <build_version>\n\n" on each rebuild
// TODO(Phase 1): build_version: u64, incremented after each successful rebuild.
// TODO(Phase 2): debounce window (default 80ms); error overlay payload on rebuild failure.

const std = @import("std");

// TODO(Phase 1): pub fn run(allocator, entry_sax, dist_dir, port) !void { ... }

pub const DevServerStatus = enum { not_implemented };

pub fn run() DevServerStatus {
    // PLACEHOLDER. See plan.md Phase 1.
    return .not_implemented;
}
