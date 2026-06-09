# sa_plugin_vite 实现计划（plan.md）

> 目标：`.sax` 存盘 → 浏览器立即更新，全程不依赖 JS/TS 工具链。
> 设计原则：**瘦编排，不重造**。构建复用 sa_plugin_sax，serve 复用 sa_plugin_http_server。

---

## 0. 背景与决策依据（来自评估 issue7 / SAX 现状）

现有 `sa_plugin_sax` 已具备：
- `.sax → WASM` 完整构建（sax_design.md §9；src/sax/cli.zig `buildDevArtifacts`）。
- `sa sax dev` 的 `devServerLoop`（src/sax/cli.zig:431-485）：**已实现**单文件 mtime 轮询监听 + 自动重建 + 静态 serve。
- `airlock_gen.zig` / `html_shell_gen.zig`：生成 WASM↔DOM 胶水与 index.html shell。

**唯一缺口**：服务器重建后**不通知浏览器**，需手动 F5。补齐"浏览器自动刷新这一根线"即得到 hot reload。

**为何独立插件而非改 sax**：保持 sax 为纯编译器插件（单一职责）；dev-server/HMR 作为可组合产品，通过插件依赖机制复用 sax + http-server（参照 sa_plugin_deno 依赖 http-server 的既有模式）。

---

## 1. 范围

### In scope
- `sa vite dev`：文件树监听 → 防抖重建 → serve → `/__sax_live` 信号 → 浏览器整页 reload。
- reload 客户端注入（机器生成，非用户手写 JS）。
- 编译失败错误浮层（页面显示 Trap，不白屏）。
- 多 `.sax` / 多组件监听。

### Out of scope（明确不做）
- 任何 JS/TS 编译、esbuild、bundler、模块图。
- 状态保留式真 HMR（Phase 3 评估，默认整页 reload）。
- 跨端 native 渲染（属 sax 插件 Phase 3）。

---

## 2. 分阶段路线

### Phase 0：脚手架成形
- [x] 目录结构 + README + plan
- [x] `sap.json`：声明依赖 sax + http-server，权限 deny-all 起步（仅 `$PROJECT/**` 读 + dist 写 + `127.0.0.1`/`localhost` net）
- [x] `build.zig`：产出 `libvite.so`，链接/解析依赖插件符号
- [x] `src/plugin.zig`：`saasm_plugin_descriptor_v1` + skills 元数据 + 命令派发骨架
- [x] `vite.sai` / `vite.sal`：dev-session handle ABI + macro facade
- **验收**：`zig build` 产出 `.so`；`nm -D` 暴露 `saasm_plugin_descriptor_v1` 与 `sa_vite_dev_*`；`sa skills` 能看到 vite 能力（dev/build/preview）。

### Phase 1：基础 hot reload（核心，1-2 天，决定性）
1. **`/__sax_live` SSE 端点**（`src/dev_server.zig`） ✅
   - dev server 维护 `build_version: u64`，每次重建成功 `+1`。
   - `GET /__sax_live` 返回 `text/event-stream`，每次版本变化推一行 `data: <version>\n\n`。
   - 复用 http-server 的核心 `HttpStreamResponse`（chunked 流式；`sa_plugin_http_server/src/vite_api.zig`，与 `sa_http_server.sai` 的 streaming ABI 同源）。
2. **reload 客户端注入**（`src/reload_client_gen.zig`） ✅
   - 生成 ~5 行常量脚本：`new EventSource('/__sax_live').onmessage = () => location.reload()`。
   - 注入点：拦截 sax 生成的 index.html，在 `</body>` 前插入（或请求 html_shell_gen 暴露注入钩子）。
   - 标注：**机器生成，非用户 JS**，与 airlock.js 同性质。
3. **重建编排**（`src/dev_server.zig`） ✅
   - 监听命中 → 调用 sax build（依赖符号 / 子命令）→ 成功则 `build_version+=1` 触发 SSE。
- **验收**：浏览器打开 `:port`，编辑 `.sax` 存盘，**无需手动刷新**页面在 ~1s 内更新。当前已由 `tests/dev-smoke.sh` 覆盖 HTTP 页面、wasm 魔数、`/__sax_live` 连接和修改入口 `.sax` 后推送 `data: 2`。

### Phase 2：体验完善（小）
- [x] **文件树递归监听**（`src/watch.zig`）：替换单文件 mtime，支持多 `.sax`/组件；当前使用递归 mtime/size fingerprint 扫描。
- [x] **防抖**：连续保存合并为一次重建（默认 80ms，可用 `--debounce-ms` 调整）。
- [x] **错误浮层**：重建失败时，`/__sax_live` 推错误负载，reload 客户端渲染浮层而非 reload。
- **验收**：多组件项目改任一 `.sax` 文件触发重建；编译错误在页面可读，不白屏。当前 `tests/dev-smoke.sh` 覆盖嵌套 `.sax` 新增触发 reload、入口错误触发 `data: error:<version>`、修复后恢复成功 reload。

### 后续性能工作
- **构建缓存对齐**：复用 sci 项目缓存（见 issue6 IMP-1/CACHE-1），避免每次全量重展开 sa_std。这是 compiler/sax 构建层的共享缓存问题，不阻塞 vite dev server 功能完成。

### Phase 3：进阶（大，可后置）
- **状态保留 HMR**：重建后经 airlock 把旧 state 迁移到新 WASM 实例，替代整页 reload。需 sax 侧导出状态序列化/重注入钩子。
- **HMR 边界**：组件级替换而非整模块。
- **多入口 / dev 路由**：配合 sax `<Router>`。

---

## 3. 依赖契约

通过 `sap.json` 声明（参照 deno → http-server 模式）：
- `sax`（>= 0.1.0, abi 1）：构建复用 `sa_plugin_sax/src/vite_api.zig`，直接调用 `.sax → .sa → wasm` 编译层；不派生 `sa sax build` 子进程。
- `http-server`（>= 0.1.0, abi 1）：serve/SSE 复用 `sa_plugin_http_server/src/vite_api.zig` 的 `HttpServer`、`HttpResponse`、`HttpStreamResponse` 核心类型；`sa_http_server_*` ABI 仍由 http-server 自己导出，vite 不重导出这些符号。

---

## 4. 权限规划（deny-all 起步，最小授权）

```jsonc
"permissions": {
  "fs": [
    { "op": "read",   "path": "$PROJECT/**" },     // 读 .sax 源
    { "op": "metadata","path": "$PROJECT/**" },     // watch mtime
    { "op": "read",   "path": "$PROJECT/dist/**" }, // serve 产物
    { "op": "write",  "path": "$PROJECT/dist/**" }, // 写构建产物
    { "op": "create", "path": "$PROJECT/dist/**" }
  ],
  "net": [
    { "url": "http://127.0.0.1", "methods": ["GET"] },
    { "url": "http://localhost", "methods": ["GET"] }
  ],
  "env": ["HOME", "TMPDIR", "SA_*"],
  "process": { "spawn": false, "exec": [] }   // 若改为派生 sa sax build 子进程，再按需放开并白名单
}
```
- 远程网络一律不需要（dev server 只绑本地）。
- `process.spawn` 默认 false；仅当 Phase 0 决定走"子进程编排 sax"时才放开，并精确白名单 `sa` 二进制。

---

## 5. 风险与开放问题

| 项 | 说明 | 处置 |
|---|---|---|
| sax 构建调用面 | 已通过 `sa_plugin_sax/src/vite_api.zig` 复用源码级构建入口 | `sa_vite_dev_*` handle ABI 已提供 dev session 生命周期入口 |
| `sa run` 解释器一致性 | extern-heavy 插件在 `sa run` 可能 InvalidInstruction（design §1.7.1） | dev server 走 native build；文档明示需 `sa build-exe` |
| index.html 注入耦合 | 注入依赖 sax 的 shell 生成格式 | 请求 html_shell_gen 暴露稳定注入钩子，避免脆性字符串拼接 |
| 浏览器端零 JS 的误解 | reload/airlock 需客户端脚本 | README 已澄清：机器生成、非用户 JS、不引入 JS/TS 构建链 |
| 单进程 serve 并发 | 当前复用 http-server 核心并以非阻塞 accept 融入 watch loop；SSE 客户端独立线程 | 多标签页可用，极高并发仍非 dev server 目标 |

---

## 6. 验收里程碑

- **M0**：`zig build` 出 `.so`，`sa skills` 列出 vite 能力。
- **M1**：编辑 `examples/counter.sax` 存盘，浏览器自动刷新显示新内容（核心目标达成）。
- **M2**：多文件监听 + 防抖 + 错误浮层。
- **M3**（可选）：状态保留 HMR。
