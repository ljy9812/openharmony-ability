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

// ─── UI components (re-exported by the core index for app consumers) ────────
export {
  DefaultXComponent,
  notifyPrimaryWebviewController,
} from "./src/main/ets/components/DefaultXComponent";
// Consumed directly by the core package's NativeAbility (webview callback
// wiring and the Entry route name); not part of the app-facing surface.
export { setPrimaryWebviewControllerCallback } from "./src/main/ets/components/DefaultXComponent";
// The @Entry struct itself is not exportable; NativeAbility reaches the route
// through `import * as Entry` + RouteName, exactly as before the move.
export { RouteName } from "./src/main/ets/components/MainPage";
export { WindowManager } from "./src/main/ets/window/WindowManager";
// Window event payload types re-exported by WindowManager; BridgeHost imports
// them from this package alongside the manager itself.
export { WindowSizeEventWrap, WindowRectEventWrap } from "./src/main/ets/window/WindowManager";

// ─── Menu helpers (exported for MenuPlugin.ets bridge plugin) ───────────────
export {
  setMenuClickHandler,
  getMenuClickHandler,
  unregisterMenuClickHandler,
  setMenuBarRecoverFn,
  getMenuBarRecoverFn,
  unregisterMenuBarRecoverFn,
  getMenuDataCallback,
  registerMenuDataCallback,
  unregisterMenuDataCallback,
  windowKeyForId,
  isMenubarVisible,
} from "./src/main/ets/components/MenuBarComponent";
export type { MenuDataCallback } from "./src/main/ets/components/MenuBarComponent";
export {
  setPredefinedActionExecutor,
  getPredefinedActionExecutor,
  PredefinedActionExecutor,
  MenuManager,
} from "./src/main/ets/helper/menu";

// ─── StatusBar helpers (exported for StatusbarPlugin.ets bridge plugin) ─────
export {
  getAbilityContext,
  createPixelMapFromRgba,
  createPixelMapFromRgbaWH,
  fillMenuItemAbilityName,
  processMenuItemIcons,
  reRegisterStatusBarClickHandlers,
  setCurrentAbilityName,
  setAbilityContext,
} from "./src/main/ets/helper/StatusBarUtils";

// ─── Reverse-direction bridge port ───────────────────────────────────────────
// The core package's BridgeHostRegistry.prepare() installs the host-backed
// implementation; StatusBarUtils and DefaultXComponent consume it instead of
// importing the core package (PR #82 har split).
export { getNativeBridgePort, installNativeBridgePort } from "./src/main/ets/helper/native_bridge";
export type { NativeBridgePort } from "./src/main/ets/helper/native_bridge";
