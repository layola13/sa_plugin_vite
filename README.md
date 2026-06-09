# sa_plugin_vite

> SAX 热重载开发服务器插件（dev server + hot reload）。
> **占位符脚手架** —— 当前仅含目录结构、接口契约与实现计划，尚无可用实现。实现路线见 `plan.md`。

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

## 命令（规划中，见 plan.md）

| 命令 | 说明 | 状态 |
|------|------|------|
| `sa vite dev <entry.sax>` | 启动 dev server + 监听 + 热重载 | 🚧 占位 |
| `sa vite build <entry.sax>` | 一次性生产构建（委托 sax build） | 🚧 占位 |
| `sa vite preview` | 预览已构建产物 | 🚧 占位 |

## 目录结构

```
sa_plugin_vite/
├── README.md                  # 本文件
├── plan.md                    # 分阶段实现计划与改动点
├── API_COVERAGE.md            # 公开 ABI 账本（占位）
├── sap.json                   # 插件清单：依赖 sax + http-server，权限 deny-all 起步
├── build.zig                  # 构建脚本（占位）
├── vite.sai                   # SA-facing @extern 契约（占位）
├── vite.sal                   # SA-facing 宏/布局 facade（占位）
├── src/
│   ├── plugin.zig             # saasm_plugin_descriptor_v1 + skills（占位）
│   ├── vite_saasm_api.zig     # pub export fn sa_vite_* C-ABI 符号（占位）
│   ├── dev_server.zig         # dev server 主循环：watch→rebuild→serve→signal（占位）
│   ├── watch.zig              # 文件树递归监听（占位）
│   └── reload_client_gen.zig  # 生成注入 index.html 的 reload 客户端（占位）
├── examples/
│   └── counter.sax            # 最小示例（占位）
└── tests/
    └── dev-smoke.sh           # build + 符号 + dev 启动冒烟（占位）
```

## 状态

🚧 **脚手架阶段**。所有 `src/*.zig` 均为带 TODO 的占位桩，不可构建运行。下一步见 `plan.md` Phase 0。
