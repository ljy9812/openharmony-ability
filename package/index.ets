export { NativeAbility } from "./src/main/ets/ability/NativeAbility";
export {
  AsyncPluginBase,
  LazyPlugin,
  BridgeAbilityCreateLifecyclePayload,
  BridgeEmptyLifecyclePayload,
  BridgeMemoryLevelLifecyclePayload,
  BridgeWindowStageEventLifecyclePayload,
  PluginBase,
  SyncPluginBase,
} from "./src/main/ets/ability/type";
export type {
  AsyncBridgePlugin,
  BridgeBindings,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeLifecycleEvent,
  BridgeLifecycleKind,
  BridgeLifecyclePayload,
  BridgeTypedValue,
  BridgePlugin,
  BridgePluginContext,
  BridgePluginDeclaration,
  BridgePluginExecution,
  BridgePluginFactory,
  BridgePluginHookContext,
  MainThreadSyncBridgePlugin,
} from "./src/main/ets/ability/type";
export { DefaultXComponent } from "./src/main/ets/components/DefaultXComponent";
export { notifyPrimaryWebviewController } from "./src/main/ets/components/DefaultXComponent";
export { invokeNativeBackPressInterceptor } from "./src/main/ets/runtime/BackPress";
export { WindowManager } from "./src/main/ets/window/WindowManager";

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
export type {
  MenuItemData,
  AboutMetadataData,
  PredefinedType,
} from "./src/main/ets/helper/menu_types";

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
export type { StatusBarIconRgba } from "./src/main/ets/ability/type";

// ─── Key synthesis helpers (exported for WebviewPlugin.ets bridge plugin) ────
// ohos-webview-key-synthesis: synthetic DOM KeyboardEvents for the webview
// (ArkWeb's native key events are degenerate — see helper for details).
export {
  notifyKeySynthesisController,
  synthesizeDomKeyEvent,
  KEY_SYNTHESIS_SHIM,
} from "./src/main/ets/helper/key_synthesis";

// === Bridge plugins (aggregated from plugins/ - see pack-plugins.ps1) ===
export { AccessibilityPlugin } from "./src/main/ets/plugins/accessibility/AccessibilityPlugin";
export { AppControlPlugin } from "./src/main/ets/plugins/app-control/AppControlPlugin";
export { AccountPlugin } from "./src/main/ets/plugins/account/AccountPlugin";
export { AutostartPlugin } from "./src/main/ets/plugins/autostart/AutostartPlugin";
export { ClipboardPlugin } from "./src/main/ets/plugins/clipboard/ClipboardPlugin";
export { DeepLinkPlugin } from "./src/main/ets/plugins/deep-link/DeepLinkPlugin";
export { FilesPlugin } from "./src/main/ets/plugins/files/FilesPlugin";
export { GlobalShortcutPlugin } from "./src/main/ets/plugins/global-shortcut/GlobalShortcutPlugin";
export { MenuPlugin } from "./src/main/ets/plugins/menu/MenuPlugin";
export { PermissionPlugin } from "./src/main/ets/plugins/permission/PermissionPlugin";
export { ResourcePlugin } from "./src/main/ets/plugins/resource/ResourcePlugin";
export { StatusbarPlugin } from "./src/main/ets/plugins/statusbar/StatusbarPlugin";
export { UpdaterPlugin } from "./src/main/ets/plugins/updater/UpdaterPlugin";
export { UrlPlugin } from "./src/main/ets/plugins/url/UrlPlugin";
export { WebviewPlugin } from "./src/main/ets/plugins/webview/WebviewPlugin";
export { WindowPlugin } from "./src/main/ets/plugins/window/WindowPlugin";
