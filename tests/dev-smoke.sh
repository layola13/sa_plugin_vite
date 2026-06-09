#!/usr/bin/env bash
# sa_plugin_vite — build + symbol + dev smoke (PLACEHOLDER SCAFFOLD)
#
# TODO(Phase 0): once build.zig produces libvite.so, assert:
#   1. `zig build` succeeds and emits zig-out/lib/libvite.so
#   2. `nm -D zig-out/lib/libvite.so | grep saasm_plugin_descriptor_v1`
#   3. `nm -D` exposes every @extern declared in vite.sai
# TODO(Phase 1): start `sa vite dev examples/counter.sax`, curl /__sax_live, edit the file,
#   assert a new build_version is pushed on the SSE stream.

set -euo pipefail
echo "[vite-smoke] PLACEHOLDER: not implemented yet (see plan.md Phase 0/1)"
exit 0
