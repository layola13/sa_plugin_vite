// sa_plugin_vite — C-ABI export surface (PLACEHOLDER SCAFFOLD)
//
// Public `pub export fn sa_vite_*` symbols backing vite.sai.
// Keep complex objects behind opaque handles + explicit *_free (per design §1.7.1).
//
// TODO(Phase 1): implement the dev-server lifecycle surface. Sketch below is intent only.

const std = @import("std");

// TODO(Phase 1): sa_vite_dev_new(out_handle)            -> u32   // create dev session
// TODO(Phase 1): sa_vite_dev_set_entry(h, path, len)    -> u32   // entry .sax
// TODO(Phase 1): sa_vite_dev_set_port(h, port)          -> u32
// TODO(Phase 1): sa_vite_dev_run(h)                     -> u32   // blocking watch+serve loop
// TODO(Phase 1): sa_vite_dev_stop(h)                    -> u32
// TODO(Phase 1): sa_vite_dev_free(^h)                   -> u32

comptime {
    // PLACEHOLDER: no exported symbols yet. See plan.md Phase 1.
}
