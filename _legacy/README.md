# Legacy Code Archive (Phase A0)

Files preserved from the pre-bridge-merge codebase before upstream deleted them.
These are **reference copies only** — not compiled or imported by active code.

## Rust (`crates/ability/src/_legacy/`)

| File | Original Path | Purpose |
|------|--------------|---------|
| `helper_mod.rs` | `src/helper/mod.rs` | Old helper module (get_helper, set_main_thread_env, TSFN creators) |
| `helper_webview.rs` | `src/helper/webview.rs` | WebView helper (webview_create, load_url, etc.) |
| `webview_mod.rs` | `src/webview/mod.rs` | WebView module (webview NAPI bindings) |
| `webview_drag.rs` | `src/webview/drag.rs` | WebView drag-and-drop support |

## ArkTS (`native_ability/src/main/ets/_legacy/`)

| File | Original Path | Purpose |
|------|--------------|---------|
| `DefaultWebview.ets` | `webview/DefaultWebview.ets` | Old embedded WebView component |
| `Utils.ets` | `helper/Utils.ets` | General ArkTS utilities |
| `helper_index.ets` | `helper/index.ets` | Helper module entry point |
| `helper_object.ts` | `helper/helper_object.ts` | Helper object type definitions |
| `helper_os.ets` | `helper/helper_os.ets` | OS-specific helper functions |

## Migration Plan

- **Phase B3**: Remove Rust legacy files after webview/window/menu/clipboard plugins are complete
- **Phase B3**: Remove ArkTS legacy files after corresponding plugins replace them
- **Phase B5**: Clean up this directory entirely
