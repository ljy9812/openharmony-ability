# openharmony-ability ↔ Tauri 解耦方案（Bridge 迁移后审计版）

> **状态**：基于 PR #67/#68 bridge 架构迁移完成后的代码现状审计
> **审计时间**：2026-08-12
> **前置依赖**：Bridge Architecture Migration（A0-A3 + B1/B2/B4 全部完成）
> **判据**：「是否 Tauri-shaped」是判据，「是否组合了 OHOS API」不是

## 判定原则

| 问题 | 是 → 归属 |
|---|---|
| 签名/注释/时序是否假设 Tauri 运行时概念？ | 迁 tauri 仓 |
| 是否任意 OHOS 原生应用都想要的平台能力，或组合 OHOS API 的跨 OS 平级功能？ | 留 openharmony-ability |
| 两者皆是（底层通用但暴露形态被 Tauri 污染）？ | 拆：通用层保留能力 + 发中性 Event；Tauri 形态入口迁 tauri 仓 |

## 一、Bridge 迁移带来的架构变化

PR #67（pluginized bridge core）+ PR #68（built-in plugins）引入了全新的插件化 bridge 架构：

```
旧模型：                              新模型：
Rust (tao/wry/tauri)                  Rust (tao/wry/tauri)
  ↓ get_named_property("method")        ↓ bridgeInvoke(pluginId, action, ...)
ArkHelper.ets (50 方法)               plugin crate (Rust facade)
  ↓ 直接调用 ArkUI API                   ↓ impl_bridge_napi_type! 类型契约
OHOS Runtime                          ArkTS plugin (WebviewPlugin.ets / ...)
                                        ↓ pluginContext.invokeAsync(...)
                                      OHOS Runtime
```

### 新增 Plugin Crate

| Plugin | ID | 替代的旧代码 | 状态 |
|--------|-----|------------|------|
| plugin-webview | `ohos.webview` | ArkHelper webview 方法 + helper/webview.rs | ✓ 已完成 |
| plugin-window | `ohos.window` | 新增（窗口操作） | ✓ 已完成 |
| plugin-app-control | `ohos.app-control` | ArkHelper exit/restart/setColorMode | ✓ 已完成 |
| plugin-clipboard | `ohos.clipboard` | ArkHelper writeImageToClipboard + 新增文本读写 | ✓ 已完成 |
| plugin-menu | `ohos.menu` | ability::menu channel | ✓ 已完成 |
| plugin-statusbar | `ohos.statusbar` | ability::statusbar channel | ✓ 已完成 |
| plugin-global-shortcut | `ohos.global-shortcut` | global_shortcut dispatcher + forwarder | ✓ 已完成 |
| plugin-deep-link | `ohos.deep-link` | take_initial_want_uri（AppStorage 方案） | ✓ 已完成 |
| plugin-autostart | `ohos.autostart` | ArkHelper autostart* | ✓ 已完成 |
| plugin-files | `ohos.files` | 文件系统操作（新增） | ✓ 已有 |
| plugin-permission | `ohos.permission` | 权限请求（新增） | ✓ 已有 |
| plugin-resource | `ohos.resource` | 资源管理（新增） | ✓ 已有 |
| plugin-url | `ohos.url` | URL 处理（新增） | ✓ 已有 |

> 注：`node.rs` 是 ability 核心模块（非独立 plugin crate），提供容器管理基础设施

---

## 二、原 5 组 Tauri 耦合接缝现状

### 接缝 1：close 队列 — ❌ 未迁移

| 项目 | 详情 |
|------|------|
| 定义位置 | `crates/ability/src/app.rs:793` (`PENDING_WINDOW_CLOSES`), `:806` (`notify_window_close`), `:825` (`drain_pending_window_closes`) |
| 消费位置 | `tauri/crates/tauri-runtime-wry/src/lib.rs:4479` → `tao::platform::ohos::ability::drain_pending_window_closes()` |
| Tauri 注释 | `app.rs:789,791,802,817,819-822` 明写 `tauri-runtime-wry event loop` / `WindowsStore` / `tao ZST WindowId` |
| 新架构影响 | bridge 迁移未触及关窗通道。无 plugin 替代品 |
| 根因 | tao OHOS 后端的 `WindowId` 是 ZST（零大小类型），不携带真实 OHOS window id（遗留问题一） |

**建议**：
- 选项 A：tauri-runtime-wry OHOS 适配层自建 close 队列（需 `notify_window_close` NAPI 入口留在 ability 或迁到适配层）
- 选项 B：根治 tao `WindowId` ZST 问题，让 `MainEvent::WindowDestroy` 携带真实 window id
- **不要删除** `drain_pending_window_closes`——删除会直接破坏关窗

### 接缝 2：deep-link 冷启动 — ⚠️ 双轨并存

| 项目 | 详情 |
|------|------|
| 旧 API | `app.rs:889` (`take_want_parameters`), `app.rs:901` (`INITIAL_WANT_URI`), `app.rs:911` (`take_initial_want_uri`)，未标 deprecated |
| 新 Plugin | `plugin-deep-link` 用 AppStorage 双键（`initialWantUri` 冷启动 + `wantUri` 最新） |
| tauri 侧 | `plugins-workspace/plugins/deep-link/src/lib.rs:246` 仍调 `openharmony_ability::take_initial_want_uri()` |
| tauri 侧 | `plugins-workspace/plugins/single-instance/src/platform_impl/ohos.rs:27` 仍调 `openharmony_ability::take_want_parameters()` |

**建议**：tauri 侧切到新 `DeepLinkClient` facade → 删旧 API（`take_initial_want_uri` + `take_want_parameters` + `INITIAL_WANT_URI`）

### 接缝 3：cursor 全局 — ❌ 未迁移

| 项目 | 详情 |
|------|------|
| 定义位置 | `app.rs:838` (`CURSOR_POSITION_X`), `app.rs:841` (`CURSOR_POSITION_Y`), `app.rs:847` (`update_cursor_position`) |
| 消费位置 | `tao/src/platform_impl/ohos/mod.rs:800-801, 1375-1376` 直接 `openharmony_ability::CURSOR_POSITION_X/Y.load(...)` |
| Tauri 注释 | `app.rs:834` "tao reads these values in cursor_position()" |
| 冗余双路 | tao `handle_mouse_event` Move 分支已拿到 `mouse_event.x/y` 并 emit `CursorMoved`，但未本地缓存 |

**建议**（低成本纯内部重构）：
1. tao `handle_mouse_event` Move 分支存本地 `self.cursor_x/y`
2. `cursor_position()` 改读本地缓存
3. 删除 `app.rs` 全局变量 + NAPI `update_cursor_position` + ArkTS `onMouse→NAPI` 旁路

### 接缝 4：menu/statusbar channel — ⚠️ 部分解决（含新发现）

| 项目 | 详情 |
|------|------|
| 消费者已迁移 | `muda:560` → `plugin_menu::menu_event_receiver()`；`tray-icon:48-49` → `plugin_statusbar::icon_click_receiver()/menu_click_receiver()` |
| 旧代码仍存活 | `ability::menu/mod.rs:64,96,103`（MENU_EVENT_CHANNEL 三件套）+ `ability::statusbar/event.rs:8,11,15,19`（ICON/MENU_CLICK_CHANNEL）未删、未标 deprecated |
| **新发现** | plugin-menu 和 plugin-statusbar **不是中性 OHOS 能力门面**，而是 **muda/tray-icon 形状的复刻** |

**关键发现 — plugin crate 承载 Tauri 契约**：
- `plugin-menu/src/lib.rs:8-9,85-86,95,100-101` 明写 `muda's event listener thread`、`tray-icon to bridge`
- `plugin-statusbar/src/lib.rs:9,25,134-135` 明写 `tray-icon's event-forward thread`、`used by tray-icon`
- 按「是否 Tauri-shaped」判据，`menu_event_receiver`/`send_menu_event`/`icon_click_receiver`/`menu_click_receiver` 本质是 muda/tray-icon 契约

**建议**：
1. **立即**：ability 核心仓 `menu/mod.rs` + `statusbar/event.rs` 旧 channel 标 `#[deprecated]`。全限定调用已零命中（无外部消费者），仅需清理 `lib.rs:138-139` 的 re-export
2. **后续**：plugin-menu/plugin-statusbar 的 channel API（`menu_event_receiver` 等）进一步迁到 muda/tray-icon OHOS 适配层——它们目前留在 openharmony-ability 仓的 plugin 子 crate 内，按判据应迁出
3. plugin crate 保留 ArkTS bridge 对接 + 类型契约，但删除 consumer-facing channel API

### 接缝 5：global-shortcut dispatcher — ⚠️ 双轨并存

| 项目 | 详情 |
|------|------|
| 旧 API | `global_shortcut/mod.rs:115` (`DISPATCHER`), `:122` (`init_forwarder`)，未标 deprecated |
| 新 Plugin | `plugin-global-shortcut` 用 bridge + `invokeNativeSync` + 自有 `SHORTCUT_EVENT_CHANNEL` |
| tauri 侧 | `plugins-workspace/plugins/global-shortcut/src/lib.rs:333` 仍调 `openharmony_ability::init_forwarder(...)` |

**建议**：tauri 侧切到 `GlobalShortcutClient` facade → 删旧 `init_forwarder` + `DISPATCHER`（不再需要独立 `run_on_main_thread`，bridge `AsyncBridge` 已提供执行能力）

---

## 三、Tauri 耦合注释扫描结果

**验收标准**：非版权头的 tauri/tao/wry/muda/tray-icon 注释命中降至 0。

**当前状态：约 39 处命中，跨 7 文件。bridge 迁移未清理任何注释，反而新增。**

| 文件 | 命中数 | 典型内容 |
|------|--------|---------|
| `app.rs` | 8 | `tauri-runtime-wry event loop`、`WindowsStore`、`tao ZST WindowId` |
| `menu/mod.rs` | 11 | `for muda`、`tauri's on_menu_event chain` |
| `window/mod.rs` | 9 | `tao caller`、`tao's Window::close`、`wry/WebView` |
| `helper/webview.rs` | 6 | `installed by wry`、`wry's InnerWebView drop` |
| `global_shortcut/mod.rs` | 3 | `AppHandle::run_on_main_thread` |
| `global_shortcut/event.rs` | 1 | `tauri-plugin-global-shortcut` |
| `version.rs` | 1 | Tauri 主仓 UT 路径 |

新增 plugin crate 中的描述性耦合（不计入上述命中，但需关注）：
- `plugin-menu/src/lib.rs` — 8 处 muda/tray-icon 引用
- `plugin-statusbar/src/lib.rs` — 4 处 tray-icon 引用
- `plugin-webview/src/lib.rs` — 6 处 wry 引用

---

## 四、原改造项（§3）在新架构下的必要性

### §3.1 中性 `run_on_main_thread` — ❌ 不再需要

bridge `AsyncBridge` + `invokeNativeSync` 反向事件已提供执行能力。tauri 侧 global-shortcut 切到新 plugin 后，`init_forwarder` + `DISPATCHER` 可直接删除，不再需要独立中性 `run_on_main_thread`。

### §3.2 `Event` 通道补中性变体 — ❌ 已被替代

每 plugin 自有 crossbeam channel + bridge `on_main_thread_event` 反向同步事件模型取代了集中式 `Event` 变体路由。`Event::MenuItemClicked` / `StatusBarIconClick` / `StatusBarMenuClick` 不再需要。

`Event::NewWant { uri }` 的 params 扩展也不再需要——plugin-deep-link 走 AppStorage，single-instance 仍用旧 `take_want_parameters`（待迁移）。

### §3.3 DRY `window/mod.rs` 样板 — ⚠️ 视 plugin-window 覆盖度

旧 `window/mod.rs`（21 处 `get_helper()` 调用 / 20 处 `func.call` 样板）仍存活编译。需确认 plugin-window 的 WindowClient 是否完整覆盖窗口管理方法集：
- 若覆盖 → 旧 `window/mod.rs` 迁 `_legacy/` 或删
- 若不覆盖 → DRY 抽 `fn call_helper<R>(method, args) -> Result<R>` 仍有意义

### §3.4 unsoundness 5 处 — ✅ 全部仍在，需独立修复

| # | 位置 | 问题 |
|---|------|------|
| 1 | `helper/mod.rs:43` | `std::mem::forget(helper)` |
| 2 | `helper/mod.rs:57-58,61,63,71,73` | `ptr::read` + `ManuallyDrop` 包裹 `ObjectRef` |
| 3 | `app.rs:736` | `run_loop` 的 `transmute<Box<dyn FnMut(Event)+'a>, Box<dyn FnMut(Event)+'static+Sync+Send>>` |
| 4 | `app.rs:751` | `on_back_press_intercept` 同款 transmute |
| 5 | `helper/mod.rs:1,63,73` | `ManuallyDrop` import + 使用 |

bridge 迁移未触及这些 unsoundness。可继续按原计划修复。

---

## 五、ArkHelper 双轨现状

### 已标 @deprecated 但仍被活跃调用

**Rust 侧**：
- `window/mod.rs` — 窗口管理整组方法仍经 `get_helper()` 调 ArkHelper
- `clipboard/mod.rs` — 剪贴板操作仍调 ArkHelper
- `opener.rs` — 文件打开仍调 ArkHelper
- `version.rs` — 版本查询仍调 ArkHelper
- `helper/mod.rs` — 整个 helper 模块仍活跃

**ArkTS 侧**：
- `StatusBarUtils.ets` — 强依赖 `ArkHelper` 类型（`import { ArkHelper }`、`helperRef: ArkHelper | null`）

### 无 plugin 替代的方法（需决定归属）

| 方法组 | 功能 | 建议归属 |
|--------|------|---------|
| `updaterCheck` / `updaterShowDialog` / `updaterDownloadAndInstall` | AppGallery 应用内更新 | 新建 plugin-updater 或留 ArkHelper |
| `requestPermission` | 权限请求 | 新建 plugin-permission 或留 ArkHelper |
| `checkCanIUse` | API 能力检测 | 留 ability core（通用基础设施） |
| `getWindowAvoidArea` | 安全区域查询 | 留 plugin-window 或 ability core |
| `createOSWindow` + 17 个窗口管理方法 | OS 级窗口管理 | 需确认 plugin-window 覆盖度 |

---

## 六、迁移顺序（Bridge 迁移后更新版）

```
阶段 0  清理双轨旧代码
        ├── ability::menu/mod.rs + statusbar/event.rs 标 #[deprecated]
        ├── 清理 lib.rs:138-139 的旧 channel re-export（全限定调用已零命中）
        ├── N9 删除 helper/webview.rs 死代码模块（900+ 行，永不编译）
        ├── N10 移除 drag_and_drop 空壳 feature
        └── _legacy/ 目录已不在编译路径（lib.rs 无 mod 声明），可直接删除

阶段 1  facade 覆盖度补齐 + tauri 侧切到新 plugin facade
        ├── 前置：plugin-window 补 set_window_touchable action（N12 facade 缺口）
        ├── 前置：plugin-menu 补 is_menubar_visible + set_menu_json action（N13 facade 缺口）
        ├── deep-link: plugins-workspace/plugins/deep-link:246 切到 DeepLinkClient
        ├── single-instance: plugins-workspace/plugins/single-instance:27 切到 DeepLinkClient
        ├── global-shortcut: 全套 API 迁移 ~20 处（N14），含 enum→String 适配
        ├── autostart: plugins-workspace/plugins/autostart:16 切到 AutostartClient (N5)
        ├── clipboard-manager: 切到 ClipboardClient (N5)
        ├── opener: 切到 OpenerClient (N5)
        ├── window-vibrancy: 切到 WindowClient facade (N7)
        ├── tauri-runtime-wry: focus_window/set_window_focusable/destroy_window 切到 WindowClient (N11)
        ├── tao: create_os_window/set_window_touchable 切到 WindowClient (N12)
        ├── tauri core window: set_menubar_visible/set_menu_json/is_menubar_visible 切到 MenuClient (N13)
        ├── tauri core start_popup_forwarder: 迁到 menu bridge plugin facade (N4)
        └── 删除旧 API: take_initial_want_uri / take_want_parameters / INITIAL_WANT_URI / init_forwarder / DISPATCHER

阶段 2  内部重构
        ├── 接缝 3 cursor: tao 本地缓存 → 删全局
        ├── 接缝 1 close: tauri-runtime-wry 自建队列（或接受为持久旁路 + 中性化注释）
        ├── N2 waker: 评估 tao EventLoop 自带 waker 可行性
        ├── N3 插件级 TSFN 族: 随 ArkHelper 双轨收尾删除旧 TSFN 全局
        ├── N8 ArkTS want 参数键名泛化: tauri_window_id → ohos_window_id
        └── §3.4 unsoundness 5 处修复

阶段 3  plugin crate channel 再迁移
        ├── N1 menu/event.rs GLOBAL_DISPATCHER 与 MENU_EVENT_CHANNEL 一起迁出
        ├── plugin-menu 的 menu_event_receiver/send_menu_event 迁到 muda OHOS 适配层
        ├── plugin-statusbar 的 icon_click_receiver/menu_click_receiver 迁到 tray-icon OHOS 适配层
        └── plugin crate 保留 bridge 对接 + 类型契约，删除 consumer-facing channel API

阶段 4  ArkHelper 收尾 + 新 facade
        ├── 确认 createOSWindow 整组方法的 plugin-window 覆盖度
        ├── 迁走 window/mod.rs / clipboard / opener 的 ArkHelper 调用
        ├── StatusBarUtils.ets 解耦 ArkHelper 类型
        ├── 决定 updater / requestPermission / getWindowAvoidArea 归属
        ├── N6 huawei-account: 新建 plugin-account facade crate（或确认核心特权）
        └── 删除 ArkHelper.ets

阶段 5  注释清理 + 验收 + 结构优化
        ├── 39 处 Tauri 耦合注释 → 0（中性化或删除）
        ├── plugin crate 注释清理（muda/tray-icon/wry 引用）
        ├── N15 tauri-runtime RuntimeInitArgs.app 类型抽象化评估
        ├── N16 tao/tauri blanket re-export 收敛为按需 use
        └── 验收标准逐项检查
```

**依赖约束**：阶段 1 先于阶段 4（旧 API 删后才能确认 ArkHelper 调用方全部迁走）。阶段 3 可与阶段 2 并行。

---

## 七、验收标准（更新版）

- [ ] 非版权头的 `tauri`/`tao`/`wry`/`muda`/`tray-icon`/`RunEvent`/`AppHandle`/`WindowsStore`/`on_menu_event`/`tauri-plugin-*` 注释命中降至 **0**（当前约 39 处/7 文件 + plugin crate ~18 处）
- [ ] **12 文件版权头**（`Copyright 2019-2024 Tauri Programme within The Commons Conservancy`）作为 Apache-2.0/MIT 双许可法定署名**保留**，不计入命中数
- [ ] `crates/ability/Cargo.toml` 仍无 tauri 系依赖
- [ ] 5 组接缝在通用层消失：
  - [ ] 接缝 1 close 队列：迁到 tauri-runtime-wry 适配层（或中性化后保留）
  - [ ] 接缝 2 deep-link：旧 API 删除，tauri 侧切到 DeepLinkClient
  - [ ] 接缝 3 cursor：tao 自维护，全局变量删除
  - [ ] 接缝 4 channel：旧 channel + `GLOBAL_DISPATCHER`（N1）删除，plugin crate channel API 迁到 muda/tray-icon
  - [ ] 接缝 5 dispatcher：旧 API 删除，tauri 侧切到 GlobalShortcutClient
- [ ] 16 项遗漏场景全部处理：
  - [ ] N1 `GLOBAL_DISPATCHER` 随接缝 #4 迁出
  - [ ] N2 `WAKER` 全局单例评估处理方案
  - [ ] N3 ~20 个插件级 TSFN 全局随 ArkHelper 收尾删除
  - [ ] N4 `start_popup_forwarder` 迁到 menu bridge plugin facade
  - [ ] N5 autostart/clipboard/opener 切到对应 facade
  - [ ] N6 huawei-account 新建 facade 或确认核心特权
  - [ ] N7 window-vibrancy 切到 WindowClient facade
  - [ ] N8 ArkTS `tauri_window_id`/`tauri_transparent` 键名泛化
  - [ ] N9 删除 `helper/webview.rs` 死代码模块
  - [ ] N10 移除 `drag_and_drop` 空壳 feature
  - [ ] N11 tauri-runtime-wry window API 切到 WindowClient
  - [ ] N12 tao window API 切到 WindowClient（需补 `set_window_touchable`）
  - [ ] N13 tauri core menu API 切到 MenuClient（需补 2 个 action）
  - [ ] N14 global-shortcut 全套 API 迁移（~20 处）
  - [ ] N15 tauri-runtime RuntimeInitArgs.app 类型抽象化评估
  - [ ] N16 tao/tauri blanket re-export 收敛
- [ ] plugin-menu/plugin-statusbar 不再暴露 consumer-facing channel API
- [ ] ArkHelper.ets 删除（或仅保留通用能力方法，Tauri 形态方法全部迁出）
- [ ] `_legacy/` 目录清空
- [ ] 通用层经 bridge plugin + `BridgeMainThreadEvent` 暴露能力，tauri 仓单向依赖 `openharmony-ability`
- [ ] 第三方非 Tauri 插件可仅凭 `openharmony-ability`（plugin facade + Event）实现功能
- [ ] Tauri 侧行为不回归：close 批量 drain 语义、cursor 同步读、deep-link 冷启动注入、热键主线程派发、菜单/statusBar 点击链路

---

## 八、与原方案差异总结

| 项目 | 原方案 | 审计后更新 |
|------|--------|-----------|
| §3.1 run_on_main_thread | 需要新建 | ❌ 不再需要（bridge AsyncBridge 替代） |
| §3.2 Event 变体 | 需要补充 | ❌ 已被替代（per-plugin channel + bridge 反向事件） |
| §3.3 DRY 样板 | 需要重构 | ⚠️ 视 plugin-window 覆盖度 |
| §3.4 unsoundness | 需要修复 | ✅ 仍需修复（bridge 未触及） |
| 接缝 4 channel | 迁到 tauri 仓 | 需**二次迁移**：plugin crate → muda/tray-icon 适配层 |
| plugin crate 定位 | 未涉及 | 新增审计项：plugin-menu/statusbar 承载 Tauri 契约 |
| ArkHelper 双轨 | 未涉及 | 新增审计项：标 deprecated 但仍被活跃调用 |
| Tauri 注释 | 27 处/9 文件 | 约 39 处/7 文件 + plugin crate ~18 处（不减反增） |
| 遗漏接缝 | 未涉及 | 新增 8 项（见下文 §九） |

---

## 九、遗漏扫描补充发现

> 以下为最终遗漏扫描发现的 8 个额外解耦场景，原方案未覆盖。

### N1. `menu/event.rs` GLOBAL_DISPATCHER — 接缝 #4 扩展

| 项目 | 详情 |
|------|------|
| 位置 | `menu/event.rs:50` `GLOBAL_DISPATCHER: LazyLock<Mutex<MenuEventDispatcher>>` |
| 问题 | 与 `MENU_EVENT_CHANNEL` 并行的第二套 menu 事件 pub/sub 分发机制，5 组代表符号中未列出 |
| 建议 | 显式纳入接缝 #4 解耦范围，与 channel 一起迁移 |

### N2. `waker.rs` WAKER — 核心运行时全局

| 项目 | 详情 |
|------|------|
| 位置 | `waker.rs:7` `WAKER: WakerType`，`app.rs:160/662` `create_waker` |
| 问题 | 全局单例事件循环 waker TSFN，是 tao `EventLoopProxy`/RuntimeHandle 在 OHOS 侧的载体，假设单一事件循环消费者 |
| 归属 | 运行时集成层耦合（新类别），非插件级 |
| 建议 | 作为独立接缝评估。tao EventLoop 可能需要自带 waker 而非依赖全局 |

### N3. 插件级单例 TSFN 族 — 插件桥接层

| 项目 | 详情 |
|------|------|
| 位置 | `clipboard/mod.rs:41`、`helper/account.rs`（3 个）、`helper/autostart.rs`（6 个）、`helper/opener.rs`（4 个）、`helper/permission.rs:26`、`helper/restart.rs:27`、`helper/updater.rs`（3 个）、`window/mod.rs:181-183`（3 个）— 共 ~20 个全局 TSFN |
| 问题 | 每个插件特性一个全局单例 TSFN，假设单一消费者实例。与 5 组运行时接缝不同类，但同样是单例耦合点 |
| 建议 | 随 ArkHelper 双轨收尾一并处理：迁移到对应 plugin crate 的 bridge 调用后，旧 TSFN 全局可删除 |

### N4. `start_popup_forwarder()` — tauri core menu 弹出转发

| 项目 | 详情 |
|------|------|
| 位置 | `tauri/crates/tauri/src/menu/plugin.rs:936` |
| 问题 | 菜单弹出转发机制，独立于接缝 #4 的 event channel，形态类似 `init_forwarder` |
| 建议 | 归入接缝 #4 或视为第 6 条接缝。迁移到 menu bridge plugin facade |

### N5. AutostartManager — 有 facade 但未迁移

| 项目 | 详情 |
|------|------|
| 位置 | `plugins-workspace/plugins/autostart/src/lib.rs:16` 直接调核心 crate |
| 问题 | `openharmony-ability-plugin-autostart` facade 已存在但未被使用 |
| 建议 | 低成本迁移：改用 `AutostartClient` facade |

### N6. HuaweiAccount / AccountInfo — 无 facade crate

| 项目 | 详情 |
|------|------|
| 位置 | `plugins-workspace/plugins/huawei-account/src/ohos.rs:20,31,42` + `models.rs:9,28,29` |
| 问题 | huawei-account 插件直接调核心 crate account 功能，**无对应 facade crate 存在** |
| 建议 | 新建 `plugin-account` bridge facade crate，或确认其为核心特权（华为账号是否通用 OHOS 能力） |

### N7. window-vibrancy 仓库 — 未追踪的 consumer

| 项目 | 详情 |
|------|------|
| 位置 | `window-vibrancy/src/ohos.rs:18,26,28,41,47,65,75` |
| 问题 | `set_window_blur`/`set_window_background_color` 直接调核心 crate。window-vibrancy 不在原始搜索列表中 |
| 建议 | `openharmony-ability-plugin-window` facade 已存在，改通过 facade 调用 |

### N8. NativeAbility.ets ArkTS 层 Tauri 硬耦合

| 项目 | 详情 |
|------|------|
| 位置 | `native_ability/src/main/ets/ability/NativeAbility.ets:257,263,271,277` |
| 问题 | 直接读取 want 参数键 `tauri_window_id` 和 `tauri_transparent`。ArkTS 层对 Tauri 命名约定的硬编码 |
| 建议 | 泛化为非 Tauri 专属键名（如 `ohos_window_id`/`ohos_transparent`），或通过 bridge 参数化传递 |

### N9. `helper/webview.rs` 死代码模块 — 900+ 行永不编译

| 项目 | 详情 |
|------|------|
| 位置 | `crates/ability/src/helper/webview.rs`（900+ 行） |
| 问题 | `helper/mod.rs:13` 声明 `#[cfg(feature = "webview")] mod webview;`，但 `ability/Cargo.toml` 的 features 中**未定义 `webview`**。模块永不编译。包含已废弃的 `HttpsInterceptHandler`、`HTTPS_INTERCEPT_REGISTRY`、NAPI struct 等 Tauri-shaped API |
| 影响 | 零运行时影响。注释扫描 39 处中有 6 处在此文件 |
| 建议 | 删除 `helper/webview.rs`，移除 `helper/mod.rs` 中的 `#[cfg(feature = "webview")]` 声明 |

### N10. `drag_and_drop` 空壳 feature

| 项目 | 详情 |
|------|------|
| 位置 | `ability/Cargo.toml:10` `drag_and_drop = []`；`wry/Cargo.toml:206` `features = ["drag_and_drop"]` |
| 问题 | 整个 workspace 中 `drag_and_drop` feature 仅 gate 死代码（`_legacy/webview_mod.rs` + `helper/webview.rs`，均未编译）。wry 启用一个空操作 feature |
| 影响 | 配置噪音，零运行时影响 |
| 建议 | 从 `ability/Cargo.toml` 和 `wry/Cargo.toml` 移除。若计划在 `plugin-webview` 中重新实现 drag-and-drop，则保留但需新写 gate 逻辑 |

### N11. tauri-runtime-wry 绕过 plugin-window facade 直调核心 window API

| 项目 | 详情 |
|------|------|
| 位置 | `tauri/crates/tauri-runtime-wry/src/lib.rs:2527, 2555, 4839` |
| 调用 | `openharmony_ability::window::{focus_window, set_window_focusable, destroy_window}` |
| facade 现状 | `WindowClient` 已提供 async 版 `focus_window`/`set_window_focusable`/`destroy_window` |
| 建议 | 迁到 `WindowClient`；`destroy_window` 与接缝 1 close 队列关联但调用本身独立 |

### N12. tao 绕过 plugin-window facade + facade 覆盖度缺口

| 项目 | 详情 |
|------|------|
| 位置 | `tao/src/platform_impl/ohos/mod.rs:11-13` |
| 调用 | `create_os_window` / `set_window_touchable` / `WindowCreateParams` |
| facade 缺口 | `WindowClient` 有 `create_os_window` 但**缺少 `set_window_touchable`** |
| 建议 | plugin-window 补 `set_window_touchable` action 后，tao 切到 facade |

### N13. tauri core window/mod.rs 绕过 plugin-menu facade + facade 覆盖度缺口

| 项目 | 详情 |
|------|------|
| 位置 | `tauri/crates/tauri/src/window/mod.rs:481,1339,1390,1391,1431,1472,1510`（7 处） |
| 调用 | `set_menubar_visible` / `set_menu_json` / `is_menubar_visible` |
| facade 缺口 | `MenuClient` 有 `set_menubar_visible` 但**缺少 `is_menubar_visible` 和 `set_menu_json`** |
| 建议 | plugin-menu 补 `is_menubar_visible` + `set_menu_json` action 后，tauri core 切到 facade |

### N14. global-shortcut 迁移范围严重低估

| 项目 | 详情 |
|------|------|
| 位置 | `plugins-workspace/plugins/global-shortcut/src/lib.rs` ~20 处 |
| 调用 | `init_forwarder` + `register_shortcut` + `unregister_shortcut` + `unregister_all_shortcuts` + `shortcut_event_receiver` + `ShortcutKey::from_name` + `ShortcutModifier` + `ShortcutState` |
| 问题 | §10 仅列 `init_forwarder`，实际整条注册/注销/事件管线都绕过 facade |
| facade 差异 | `GlobalShortcutClient` 用 `Vec<String>` 修饰键 + `&str` key，旧 API 用 `ShortcutModifier` enum + `ShortcutKey`，需适配 |
| 建议 | 更新 consumer 迁移清单为"全套 API 迁移"；适配 enum→String 转换层 |

### N15. tauri-runtime crate 公开字段暴露 ability 类型

| 项目 | 详情 |
|------|------|
| 位置 | `tauri/crates/tauri-runtime/src/lib.rs:405` `pub app: openharmony_ability::OpenHarmonyApp` |
| 问题 | `RuntimeInitArgs` 的 OHOS 字段直接暴露 ability 类型，使 ability 类型成为 tauri-runtime 公共 API 契约 |
| 建议 | 评估是否用 trait object / 泛型抽象隐藏具体类型，或接受为运行时集成层的合法耦合（标记为已知并降级） |

### N16. tao/tauri blanket re-export 放大耦合面

| 项目 | 详情 |
|------|------|
| 位置 | `tao/src/platform/ohos.rs:136` `pub use openharmony_ability::*;` + `tauri/crates/tauri/src/ohos.rs:4` `pub use openharmony_ability;` |
| 问题 | 全量 re-export 使 ability crate 的全部 pub 项成为 tao/tauri 公共 API，任何 ability 内部 pub 变更都外溢 |
| 建议 | 收敛为按需 `use`，仅 re-export 真正需要对外暴露的类型（`OpenHarmonyApp` 等少数） |

---

## 十、Consumer Repo 迁移清单补充

> 以下为最终扫描发现的"有 facade 但未迁移"的插件清单。

| Consumer 插件 | 当前位置 | 当前调用 | 对应 facade | 迁移成本 |
|---|---|---|---|---|
| global-shortcut | `plugins-workspace/plugins/global-shortcut` ~20 处 | 全套 API（N14） | `GlobalShortcutClient`（需 enum→String 适配） | 中 |
| deep-link | `plugins-workspace/plugins/deep-link:246` | `take_initial_want_uri` | `DeepLinkClient` | 低 |
| single-instance | `plugins-workspace/plugins/single-instance:27` | `take_want_parameters` | `DeepLinkClient` | 低 |
| autostart | `plugins-workspace/plugins/autostart:16` | `AutostartManager` | `AutostartClient` | 低 |
| clipboard-manager | `plugins-workspace/plugins/clipboard-manager` | `clipboard_write_image` | `ClipboardClient` | 低 |
| opener | `plugins-workspace/plugins/opener` | `open_with_system`/`reveal_in_dir` | `OpenerClient`（待确认） | 低 |
| huawei-account | `plugins-workspace/plugins/huawei-account` | `HuaweiAccount`/`AccountInfo` | **无 facade（需新建）** | 中 |
| window-vibrancy | `window-vibrancy/src/ohos.rs` | `set_window_blur`/`set_window_background_color` | `WindowClient` | 低 |
| tauri-runtime-wry | `tauri-runtime-wry/src/lib.rs:2527,2555,4839` | `focus_window`/`set_window_focusable`/`destroy_window`（N11） | `WindowClient` | 低 |
| tao | `tao/src/platform_impl/ohos/mod.rs:11-13` | `create_os_window`/`set_window_touchable`（N12） | `WindowClient`（需补 `set_window_touchable`） | 低 |
| tauri core window | `tauri/src/window/mod.rs` 7 处 | `set_menubar_visible`/`set_menu_json`/`is_menubar_visible`（N13） | `MenuClient`（需补 2 个 action） | 低 |

---

## 十一、审计发现：plugin-menu / plugin-statusbar 无 ArkTS 插件

> **发现时间**：2026-08-12（Phase 1 设计审计期间）
> **严重程度**：⚠️ 阻塞性——需要 menu/statusbar facade 的 consumer 无法迁移

### 问题

`plugin-menu` 和 `plugin-statusbar` 的 **Rust facade 已创建**（`crates/plugin-menu/src/lib.rs` + `crates/plugin-statusbar/src/lib.rs`），但**缺少对应的 ArkTS 插件**：

- `plugins/` 目录下无 `MenuPlugin.ets` / `StatusbarPlugin.ets`
- demo `EntryAbility.ets:32-48` 的 `bridgePlugins` 数组中无 menu/statusbar 注册
- 全局搜索 `ohos.menu` / `ohos.statusbar` 在 `.ets` 文件中零命中

### 影响

- Rust 侧 `MenuClient::set_menubar()` 等方法调用会在 ArkTS 侧失败（`BridgeHost` 报 "no matching ArkTS factory"）
- N13（tauri core window → MenuClient）和 N4（tauri core menu → facade）**无法在 Phase 1 完成迁移**
- plugin-menu 的 channel API（`menu_event_receiver` 等）当前是 muda/tray-icon 的唯一通信路径，不能删除

### 缓解方案

1. **Phase 1**：仅迁移不依赖 menu/statusbar facade 的 consumer（12 个文件，排除 N13/N4）
2. **Phase 4**：创建 `MenuPlugin.ets` + `StatusbarPlugin.ets` ArkTS 插件 → 注册到 EntryAbility → 迁移延迟 consumer → 删除旧 menu/statusbar channel
3. **plugin-menu Rust facade**：保留 `menu_event_receiver()`/`send_menu_event()` 直到 Phase 4

### 对迁移顺序的影响

```
原 Phase 1 (17 文件) → 调整后 Phase 1 (15 文件，排除 N13/N4)
原 Phase 4 (7 文件)  → 调整后 Phase 4 (~12 文件，含 ArkTS 插件 + 延迟 consumer)
```
