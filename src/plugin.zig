// sa_plugin_vite — plugin descriptor + skills + command dispatch (PLACEHOLDER SCAFFOLD)
//
// TODO(Phase 0): export `saasm_plugin_descriptor_v1` (PluginDescriptor) like the other plugins.
// TODO(Phase 0): declare skills: "vite dev <entry.sax>", "vite build", "vite preview".
// TODO(Phase 1): dispatch `vite dev` -> dev_server.run(...).
//
// Reference: ../sa_plugin_http_server/src/plugin.zig and ../sa_plugin_sax/src/plugin.zig.

const std = @import("std");
// const plugin_api = @import("plugin_api"); // TODO: import the shared plugin ABI module

// PLACEHOLDER skills metadata — shape only, not wired into a descriptor yet.
pub const skills_preview = [_]struct { name: []const u8, items: []const []const u8 }{
    .{
        .name = "vite dev server",
        .items = &.{
            "vite dev <entry.sax>      # watch + rebuild + hot reload on http://127.0.0.1:<port>",
            "vite build <entry.sax>    # one-shot production build (delegates to sax)",
            "vite preview              # serve a prior build",
            "edits to .sax trigger automatic browser reload (no JS/TS toolchain)",
        },
    },
};

// TODO(Phase 0): pub export const saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = .{ ... };
// TODO(Phase 0): fn handleCommand(...) -> dispatch "dev"/"build"/"preview".
