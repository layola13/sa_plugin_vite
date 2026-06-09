# sa_plugin_vite

> SAX 热重载开发服务器插件（dev server + hot reload）。
> **Phase 2 基础体验** —— 当前已具备可安装插件清单、动态库构建、descriptor/skills 导出、`vite build`、`vite dev` 静态服务、递归 `.sax` 监听、防抖和 `/__sax_live` 自动刷新/错误信号。实现路线见 `plan.md`。

## 它是什么

`sa_plugin_vite` 是一个**瘦编排插件**：把"改了 `.sax` → 浏览器立即更新"的开发体验包装成一个 `sa vite dev` 命令。

它**不重新实现**编译或 HTTP，而是通过 `sap.json` 声明依赖、复用现有插件：

```
sa vite dev app.sax
   │
   ├─(依赖) sa_plugin_sax        ← .sax → .sa → Flattener → Referee → WASM 构建
   └─(依赖) sa_plugin_http_server ← 静态产物 serve + SSE/chunked 流式响应

vite 插件自己只负责：
   ├── 文件树监听（多 .sax / 组件，而非单文件 mtime）
   ├── 重建编排（防抖、增量、错误捕获）
   ├── /__sax_live 实时信号端点（SSE）
   ├── reload 客户端注入（向生成的 index.html 注入 ~5 行 reload 脚本）
   └── 错误浮层（编译失败时在页面显示 Trap，而非白屏）
```

## 与 JS/TS 的关系（重要）

- **你的代码与 JS/TS 物理隔离**：`.sax → WASM` 全程是 SA 工具链，零 esbuild/tsc/node。
- **唯一的浏览器端 JS 是机器生成的胶水**：
  - `airlock.js`（由 sa_plugin_sax 生成）—— WASM↔DOM 桥，WASM 碰 DOM 的不可避免最小胶水。
  - reload 客户端（由本插件生成）—— 监听 `/__sax_live`、收到新版本就 reload 的几行脚本。
  - 这两段都**不是你手写的**，是工具生成的常量字符串。浏览器自动刷新在物理上必须有客户端脚本触发，SA 也不例外；但它不进入你的源码，也不引入 JS/TS 构建链。

## 命令

| 命令 | 说明 | 状态 |
|------|------|------|
| `sa vite dev <entry.sax> [--out-dir <dir>] [--port <port>] [--debounce-ms <ms>]` | 启动 dev server + 递归 `.sax` 监听 + 热重载 | ✅ 可用 |
| `sa vite build <entry.sax> [--out-dir <dir>]` | 一次性构建，生成可静态部署产物 | ✅ 可用 |
| `sa vite preview [dist-dir] [--port <port>]` | 预览已构建产物，不监听文件变化 | ✅ 可用 |

## 启动参数

### `sa vite dev`

```bash
sa vite dev <entry.sax> [--out-dir <dir>] [--port <port>] [--debounce-ms <ms>]
```

- `<entry.sax>`：入口 SAX 文件，必填。
- `--out-dir <dir>`：构建产物目录，默认是入口文件所在目录下的 `dist`。
- `--port <port>`：HTTP dev server 端口，默认 `5173`。
- `--debounce-ms <ms>`：递归 `.sax` 文件监听的防抖时间，默认 `80` 毫秒。

`dev` 模式会在生成的 `index.html` 中注入同源外部脚本 `/__sax_live_client.js`，浏览器通过 `/__sax_live` SSE 接收 reload/error 事件。修改入口目录下任意 `.sax` 文件都会触发重新构建；构建成功后浏览器刷新，构建失败时页面显示错误浮层。

示例：

```bash
sa vite dev examples/counter.sax --out-dir /tmp/sa-vite-demo/dist --port 5199 --debounce-ms 20
```

### `sa vite build`

```bash
sa vite build <entry.sax> [--out-dir <dir>]
```

- `<entry.sax>`：入口 SAX 文件，必填。
- `--out-dir <dir>`：构建产物目录，默认是入口文件所在目录下的 `dist`。

`build` 模式只生成静态产物，不注入 live reload 客户端。

### `sa vite preview`

```bash
sa vite preview [dist-dir] [--port <port>]
```

- `[dist-dir]`：要预览的构建产物目录，默认 `dist`。
- `--port <port>`：HTTP preview server 端口，默认 `5173`。

`preview` 只提供静态服务，不 watch，也不会触发重新构建。

## 目录结构

```
sa_plugin_vite/
├── README.md                  # 本文件
├── plan.md                    # 分阶段实现计划与改动点
├── API_COVERAGE.md            # 公开 ABI 账本
├── sap.json                   # 插件清单：依赖 sax + http-server，最小本地 dev 权限
├── build.zig                  # 构建 libvite.so
├── vite.sai                   # SA-facing @extern 契约
├── vite.sal                   # SA-facing 宏 facade
├── src/
│   ├── plugin.zig             # saasm_plugin_descriptor_v1 + skills + 命令派发
│   ├── vite_saasm_api.zig     # pub export fn sa_vite_* C-ABI 符号
│   ├── dev_server.zig         # dev server 主循环：watch→rebuild→serve→signal
│   ├── watch.zig              # 文件树递归 `.sax` fingerprint 监听
│   └── reload_client_gen.zig  # 生成注入 index.html 的 reload 客户端
├── examples/
│   └── counter.sax            # 最小示例
└── tests/
    └── dev-smoke.sh           # build + 安装 + HTTP/SSE/rebuild 冒烟
```

## 状态

✅ **Phase 2 基础体验已成形**。`zig build` 可产出 `libvite.so`，`sa plugin install --dev` 可递归安装 `sax`、`http-server`、`vite`，`sa skills` 可看到 vite 能力。`sa vite build` 会生成 `dist/app.wasm`、`airlock.js`、`index.html` 和 `app.sa`；`sa vite dev` 会递归扫描入口目录下的 `.sax` 文件、按防抖窗口重建 dist、通过复用的 http-server 核心 API 提供静态服务和 `/__sax_live` SSE reload/error 事件，并用 `/__sax_live_client.js` 提供符合 SAX CSP 的浏览器刷新客户端。`vite.sai`/`vite.sal` 也提供可审计的 dev-session handle ABI。
