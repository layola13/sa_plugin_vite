// sa_plugin_vite — reload client generator (PLACEHOLDER SCAFFOLD)
//
// Generates the tiny, MACHINE-GENERATED reload client injected into the served index.html.
// This is the ONLY browser-side script vite adds. It is NOT user-authored JS and introduces
// NO JS/TS build toolchain — same nature as sax's generated airlock.js.
//
// Pure no-JS-author hot reload is physically impossible in browsers: the reload trigger needs
// some client code. We keep that code a generated constant, isolated from user source.
//
// TODO(Phase 1): emit the snippet below and inject before </body> of the sax-generated shell.
//   Prefer requesting a stable injection hook from sa_plugin_sax's html_shell_gen.zig
//   rather than brittle string splicing.

const std = @import("std");

// PLACEHOLDER snippet (intent only). ~5 lines, listens for rebuild signal and reloads.
pub const reload_client_snippet =
    \\<script>
    \\  // sa_plugin_vite: generated reload client (not user JS). See plan.md Phase 1.
    \\  new EventSource('/__sax_live').onmessage = function (e) {
    \\    // TODO(Phase 2): if payload is an error, render overlay instead of reloading.
    \\    location.reload();
    \\  };
    \\</script>
;

// TODO(Phase 1): pub fn injectInto(html: []const u8, allocator) ![]u8 { ... }
