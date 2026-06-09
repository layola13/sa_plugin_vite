# sa_plugin_vite — Public Surface Ledger

> Per design §1.7.1, a plugin replacing/extending an external runtime keeps a public-surface ledger.
> This file tracks every exported symbol and its `.sai` contract.

| Symbol (libvite.so) | .sai contract | Status |
|---------------------|---------------|--------|
| `saasm_plugin_descriptor_v1` | (descriptor) | ✅ Implemented Phase 0 |
| `sa_vite_dev_new` | `vite.sai` | ✅ Implemented |
| `sa_vite_dev_set_entry` | `vite.sai` | ✅ Implemented |
| `sa_vite_dev_set_out_dir` | `vite.sai` | ✅ Implemented |
| `sa_vite_dev_set_port` | `vite.sai` | ✅ Implemented |
| `sa_vite_dev_set_debounce_ms` | `vite.sai` | ✅ Implemented |
| `sa_vite_dev_run` | `vite.sai` | ✅ Implemented |
| `sa_vite_dev_stop` | `vite.sai` | ✅ Implemented |
| `sa_vite_dev_free` | `vite.sai` | ✅ Implemented |

Reused (NOT exported by vite — provided by declared dependencies/source APIs):
- HTTP serve + SSE chunked streaming — reused from `sa_plugin_http_server/src/vite_api.zig`. Verified with `nm -D libvite.so`: no `sa_http_server_*` symbols are exported by vite.
- SAX compile/build implementation — reused from `sa_plugin_sax/src/vite_api.zig`; no shell-out to `sa sax` and no JS/TS toolchain.

CLI surface implemented by descriptor command dispatch:
- `vite build <entry.sax> [--out-dir <dir>]`
- `vite dev <entry.sax> [--out-dir <dir>] [--port <port>] [--debounce-ms <ms>]`
- `vite preview [dist-dir] [--port <port>]`
