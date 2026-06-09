// sa_plugin_vite — build script (PLACEHOLDER SCAFFOLD)
//
// This is an intentional no-op stub. It compiles but produces no artifact yet.
//
// TODO(Phase 0): produce zig-out/lib/libvite.so exporting saasm_plugin_descriptor_v1.
// TODO(Phase 0): wire dependency resolution to ../sa_plugin_sax and ../sa_plugin_http_server
//                (decide: link library symbols vs orchestrate via host plugin broker — see plan.md §3).
// Mirror the structure of ../sa_plugin_http_server/build.zig once the call surface is settled.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // PLACEHOLDER: no build graph yet. See plan.md Phase 0.
    const note = b.step("status", "sa_plugin_vite is a scaffold placeholder (see plan.md)");
    _ = note;
}
