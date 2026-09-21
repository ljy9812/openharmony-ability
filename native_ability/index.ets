// @ohos-rs/ability — bridge contract only.
//
// This index exports the plugin-facing bridge contract (plugin base classes,
// contexts, lifecycle payloads, the Module loading contract) plus the shared
// bridge-plugin utilities. The implementation tree those contracts drive —
// window management, menu/statusbar helpers, key synthesis, the UI components,
// the module-loading runtime — lives in the @ohos-rs/ability-support package
// (PR #82 review 意见②③: ets/ability helpers moved to a har, index kept core).

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
export type { StatusBarIconRgba } from "./src/main/ets/ability/type";

// ─── Shared bridge-plugin utilities (issue #87 minor-6) ──────────────────────
// DOMAIN used to be re-declared in every plugin that logs via hilog; the
// request-type validator and the { accepted: boolean } acknowledgement shape
// were duplicated per plugin with drifting signatures. Plugins import these
// from "@ohos-rs/ability" instead (pack-plugins.ps1 rewrites that specifier
// to the internal path when assembling the published HAR). DOMAIN and the
// storage key live in @ohos-rs/ability-support now; re-exported here so the
// plugin-facing surface is unchanged.
export { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from "@ohos-rs/ability-support";
export {
  expectBridgeRequestType,
  BridgeAcknowledgement,
} from "./src/main/ets/helper/bridge_plugin_utils";
