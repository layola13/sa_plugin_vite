# sa_plugin_vite — Public Surface Ledger (PLACEHOLDER)

> Per design §1.7.1, a plugin replacing/extending an external runtime keeps a public-surface ledger.
> This file tracks every exported symbol and its `.sai` contract. Currently empty (scaffold stage).

| Symbol (libvite.so) | .sai contract | Status |
|---------------------|---------------|--------|
| `saasm_plugin_descriptor_v1` | (descriptor) | 🚧 TODO Phase 0 |
| `sa_vite_dev_new` | `vite.sai` | 🚧 TODO Phase 1 |
| `sa_vite_dev_set_entry` | `vite.sai` | 🚧 TODO Phase 1 |
| `sa_vite_dev_set_port` | `vite.sai` | 🚧 TODO Phase 1 |
| `sa_vite_dev_run` | `vite.sai` | 🚧 TODO Phase 1 |
| `sa_vite_dev_stop` | `vite.sai` | 🚧 TODO Phase 1 |
| `sa_vite_dev_free` | `vite.sai` | 🚧 TODO Phase 1 |

Reused (NOT exported by vite — provided by declared dependencies):
- `sa_http_server_*` — from `sa_plugin_http_server` (serve + SSE)
- sax build entry — from `sa_plugin_sax` (TODO Phase 0: confirm library symbol vs subprocess)
