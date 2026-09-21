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
  Module,
} from "./src/main/ets/ability/type";
export { DefaultXComponent } from "@ohos-rs/ability-support";
export { notifyPrimaryWebviewController } from "@ohos-rs/ability-support";
export { invokeNativeBackPressInterceptor } from "@ohos-rs/ability-support";
export { WindowManager } from "@ohos-rs/ability-support";

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
} from "@ohos-rs/ability-support";
export type { MenuDataCallback } from "@ohos-rs/ability-support";
export {
  setPredefinedActionExecutor,
  getPredefinedActionExecutor,
  PredefinedActionExecutor,
  MenuManager,
} from "@ohos-rs/ability-support";
export type { MenuItemData, AboutMetadataData, PredefinedType } from "@ohos-rs/ability-support";

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
} from "@ohos-rs/ability-support";
export type { StatusBarIconRgba } from "./src/main/ets/ability/type";

// ─── Key synthesis helpers (exported for WebviewPlugin.ets bridge plugin) ────
// ohos-webview-key-synthesis: synthetic DOM KeyboardEvents for the webview
// (ArkWeb's native key events are degenerate — see helper for details).
export {
  notifyKeySynthesisController,
  synthesizeDomKeyEvent,
  KEY_SYNTHESIS_SHIM,
} from "@ohos-rs/ability-support";

// ─── Shared bridge-plugin utilities (issue #87 minor-6) ──────────────────────
// DOMAIN used to be re-declared in every plugin that logs via hilog; the
// request-type validator and the { accepted: boolean } acknowledgement shape
// were duplicated per plugin with drifting signatures. Plugins import these
// from "@ohos-rs/ability" instead (pack-plugins.ps1 rewrites that specifier
// to the internal path when assembling the published HAR).
export { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from "@ohos-rs/ability-support";
export {
  expectBridgeRequestType,
  BridgeAcknowledgement,
} from "./src/main/ets/helper/bridge_plugin_utils";
