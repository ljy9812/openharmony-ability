// @ohos-rs/ability-support — support HAR for @ohos-rs/ability.
//
// Home of the plugin-facing implementation tree that used to live inside the
// @ohos-rs/ability package: window management (WindowManager, sub-window
// registry), menu/statusbar helpers, key synthesis, and the UI components
// (DefaultXComponent, MainPage, FloatPage, MenuBarComponent). The bridge
// contract (plugin base classes, contexts, lifecycle payloads) stays in
// @ohos-rs/ability; the native-module loading contract (`Module` and its type
// closure) lives here next to the loading machinery, and is re-exported by
// the core package. This package never imports back into the core package
// (the two callbacks the support tree used to make into BridgeHost go through
// the NativeBridgePort installed by the core at startup).

// ─── Shared constants ────────────────────────────────────────────────────────
export { DOMAIN, NATIVE_MODULE_STORAGE_KEY, MAIN_WINDOW_ID } from "./src/main/ets/helper/constants";

// ─── Menu type definitions (shared by menu helpers and menu bar component) ──
export type {
  MenuItemData,
  AboutMetadataData,
  PredefinedType,
  MenuCreateOptions,
  MenuItemCreateOptions,
  SubmenuCreateOptions,
  ContextMenuHandle,
  MenuEventCallback,
} from "./src/main/ets/helper/menu_types";

// ─── Keyboard accelerator matching / per-window toggle registries ────────────
export {
  AcceleratorMatcher,
  setClipboardEnabled,
  isClipboardEnabled,
  clearClipboardEnabled,
  setZoomHotkeysEnabled,
  isZoomHotkeysEnabled,
  clearZoomHotkeysEnabled,
} from "./src/main/ets/helper/accelerator_matcher";

// ─── Key synthesis helpers (exported for WebviewPlugin.ets bridge plugin) ────
// ohos-webview-key-synthesis: synthetic DOM KeyboardEvents for the webview
// (ArkWeb's native key events are degenerate — see helper for details).
export {
  notifyKeySynthesisController,
  synthesizeDomKeyEvent,
  KEY_SYNTHESIS_SHIM,
} from "./src/main/ets/helper/key_synthesis";

// ─── Native-module loading contract ──────────────────────────────────────────
// `Module` and its type closure; re-exported by @ohos-rs/ability so existing
// imports of the core package keep resolving unchanged (PR #82 review 意见②③).
export type {
  ApplicationLifecycle,
  EnvironmentCallback,
  KeyboardCallback,
  NewWantData,
  CreateWithWantData,
  WindowStageEventCallback,
  AbilityInitContext,
  BridgeBindings,
  Module,
  BridgePluginExecution,
  BridgeContextRequirement,
  BridgePluginDeclaration,
} from "./src/main/ets/helper/native_module";

// ─── Module-loading runtime ──────────────────────────────────────────────────
// Consumed by the core package's NativeAbility (loader) and @Entry pages
// (back-press interceptor); also re-exported by the core index.
export { NativeModuleLoader } from "./src/main/ets/runtime/NativeModuleLoader";
export { invokeNativeBackPressInterceptor } from "./src/main/ets/runtime/BackPress";
