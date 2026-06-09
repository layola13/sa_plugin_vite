#!/usr/bin/env bash
set -euo pipefail

plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sa_bin="${SA_BIN:-/home/vscode/projects/sci/zig-out/bin/sa}"
port="${SA_VITE_SMOKE_PORT:-5197}"
work_dir="${TMPDIR:-/tmp}/sa-vite-dev-smoke.$$"
plugin_home="$work_dir/plugins"
server_log="$work_dir/server.log"
sse_out="$work_dir/sse.out"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$work_dir/project"
cp /home/vscode/projects/sa_plugins/sa_plugin_sax/demos/counter.sax "$work_dir/project/app.sax"
cp "$work_dir/project/app.sax" "$work_dir/project/app.valid.sax"

cd "$plugin_dir"
zig build test --summary all >/dev/null
nm -D zig-out/lib/libvite.so | grep -F saasm_plugin_descriptor_v1 >/dev/null
for symbol in \
  sa_vite_dev_new \
  sa_vite_dev_set_entry \
  sa_vite_dev_set_out_dir \
  sa_vite_dev_set_port \
  sa_vite_dev_set_debounce_ms \
  sa_vite_dev_run \
  sa_vite_dev_stop \
  sa_vite_dev_free; do
  nm -D zig-out/lib/libvite.so | grep -F " $symbol" >/dev/null
done

SA_PLUGINS_HOME="$plugin_home" SA_PLUGIN_DEV=1 "$sa_bin" plugin install --dev "$plugin_dir" >/dev/null
SA_PLUGINS_HOME="$plugin_home" SA_PLUGIN_DEV=1 "$sa_bin" plugin list | grep -F $'vite	' >/dev/null

SA_PLUGINS_HOME="$plugin_home" SA_PLUGIN_DEV=1 "$sa_bin" vite build "$work_dir/project/app.sax" --out-dir "$work_dir/project/dist" >/dev/null
test -s "$work_dir/project/dist/app.wasm"
! grep -F "/__sax_live" "$work_dir/project/dist/index.html" >/dev/null

SA_PLUGINS_HOME="$plugin_home" SA_PLUGIN_DEV=1 "$sa_bin" vite build "$plugin_dir/examples/counter.sax" --out-dir "$work_dir/example-dist" >/dev/null
test -s "$work_dir/example-dist/app.wasm"

SA_PLUGINS_HOME="$plugin_home" SA_PLUGIN_DEV=1 "$sa_bin" vite dev "$work_dir/project/app.sax" --out-dir "$work_dir/project/dist" --port "$port" --debounce-ms 20 >"$server_log" 2>&1 &
server_pid=$!

for _ in $(seq 1 80); do
  if grep -F "vite dev server listening" "$server_log" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
grep -F "vite dev server listening" "$server_log" >/dev/null

curl -fsS "http://127.0.0.1:$port/" | grep -F "/__sax_live_client.js" >/dev/null
curl -fsS "http://127.0.0.1:$port/__sax_live_client.js" | grep -F "/__sax_live" >/dev/null
curl -fsS -o "$work_dir/app.wasm" "http://127.0.0.1:$port/app.wasm"
head -c 4 "$work_dir/app.wasm" | od -An -tx1 | grep -F "00 61 73 6d" >/dev/null

curl -fsS -N "http://127.0.0.1:$port/__sax_live" >"$sse_out" &
curl_pid=$!
sleep 1
touch "$work_dir/project/app.sax"
for _ in $(seq 1 80); do
  if grep -F "data: 2" "$sse_out" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
kill "$curl_pid" 2>/dev/null || true
wait "$curl_pid" 2>/dev/null || true
grep -F "data: 2" "$sse_out" >/dev/null

curl -fsS -N "http://127.0.0.1:$port/__sax_live" >"$sse_out" &
curl_pid=$!
sleep 1
printf '<Component name="Broken"><foo></foo></Component>\n' > "$work_dir/project/app.sax"
for _ in $(seq 1 80); do
  if grep -F "data: error:3" "$sse_out" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
grep -F "data: error:3" "$sse_out" >/dev/null
cp "$work_dir/project/app.valid.sax" "$work_dir/project/app.sax"
for _ in $(seq 1 80); do
  if grep -F "data: 4" "$sse_out" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
grep -F "data: 4" "$sse_out" >/dev/null
mkdir -p "$work_dir/project/components"
printf '<Component name="Child"><div></div></Component>\n' > "$work_dir/project/components/child.sax"
for _ in $(seq 1 80); do
  if grep -F "data: 5" "$sse_out" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
kill "$curl_pid" 2>/dev/null || true
wait "$curl_pid" 2>/dev/null || true
grep -F "data: 5" "$sse_out" >/dev/null

echo "[vite-smoke] ok"
