//! OHOS Clipboard — legacy module.
//!
//! **Removed (dead code):** the eager `init_clipboard_tsfn` + `clipboard_write_image`
//! TSFN transport depended on `get_helper()` / ArkHelper, which is no longer wired up
//! after the `#[ability]` derive refactor (`set_helper` is never called). It failed at
//! init with "ArkHelper not initialized" — harmless log noise, because clipboard image
//! writes already go through the typed bridge facade.
//!
//! New code must use `ClipboardClient` in the `plugin-clipboard` crate
//! (`openharmony_ability_plugin_clipboard::ClipboardClient`), whose `write_image`
//! (and `write_text` / `read_text`) dispatch via the `ohos.clipboard` bridge plugin.
//! See `plugins-workspace/plugins/clipboard-manager/src/desktop.rs` (cfg `ohos`) for the
//! consumer-side usage and `decoupling-plan-v2.md` phase 1 / N5 for the migration plan.
