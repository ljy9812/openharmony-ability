import { NodeContent } from "@kit.ArkUI";
import resourceManager from "@ohos.resourceManager";

// ─── Native-module loading contract ──────────────────────────────────────────
// The `Module` interface and its type closure, moved here from
// @ohos-rs/ability's ability/type.ets (PR #82 review 意见②③). They describe how
// a Rust-generated NAPI module plugs into the platform: which bindings the
// module receives, which lifecycle callbacks it hands back, and how its render
// tree mounts. They live in the support package because their consumers are
// the module-loading machinery (NativeModuleLoader, ProcessInitializer,
// MainPage, FloatPage, DefaultXComponent) that also lives here; the core
// package re-exports them so existing "@ohos-rs/ability" imports keep
// resolving unchanged.

export interface ApplicationLifecycle {
  bridgePlugins: BridgePluginDeclaration[];
  environmentCallback: EnvironmentCallback;
  windowStageEventCallback: WindowStageEventCallback;
  keyboardEventCallback: KeyboardCallback;
}

export interface EnvironmentCallback {
  onConfigurationUpdated: (arg: object) => void;
  onMemoryLevel: (arg: number) => void;
}

export interface KeyboardCallback {
  onKeyboardHeightChange: (height: number) => void;
}

// NewWantData payload for onNewWant. Optional continuation fields are read with
// unwrap_or fallbacks on the Rust side (lifecycle.rs), so older payloads without
// them stay valid. isContinuation is the symbolic result of comparing
// launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION.
export interface NewWantData {
  uri: string;
  parametersJson: string;
  isContinuation?: boolean;
}

export interface CreateWithWantData {
  uri: string;
  isContinuation?: boolean;
  parametersJson?: string;
}

export interface WindowStageEventCallback {
  onWindowStageCreate: () => void;
  onWindowStageDestroy: () => void;
  onAbilityCreate: (arg: string) => void;
  onAbilityCreateWithWant: (data: CreateWithWantData) => void;
  onAbilityDestroy: () => void;
  onAbilitySaveState: () => string;
  onWindowStageEvent: (arg: number) => void;
  onWindowSizeChange: (arg: object) => void;
  onWindowRectChange: (arg: object) => void;
  onAvoidAreaChange: (arg: object) => void;
  onNewWant: (data: NewWantData) => void;
}

export interface AbilityInitContext {
  basePath?: string;
  prefPath?: string;
  preferredLocales?: string;
  moduleName?: string;
  resourceManager?: resourceManager.ResourceManager;
  sdkApiVersion?: number;
  distributionOSApiVersion?: number;
}

export interface BridgeBindings {
  bridgeInvoke: (
    pluginId: string,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
    timeoutMs: number,
  ) => Promise<ESObject>;
  bridgeInvokeSync: (
    pluginId: string,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ) => ESObject;
  bridgeDispatch: () => void;
}

export interface Module {
  /**
   * Opens this native module's Ability-session bridge before any component is rendered. The
   * owner is unique per Ability session and guards a later session from stale cleanup.
   */
  init: (
    bindings: BridgeBindings,
    bridgeOwner: string,
    context?: AbilityInitContext,
  ) => ApplicationLifecycle;
  /** Releases only the matching Ability-session bridge; stale owners are ignored. */
  disposeBridge: (bridgeOwner: string) => void;
  /**
   * Mounts this native module's one Rust render tree into `slot`. `renderOwner` is unique per
   * appearance and protects a later render from stale cleanup; another concurrently active
   * DefaultXComponent must use a different native module.
   */
  render: (slot: NodeContent, renderOwner: string) => void;
  /** Releases only the render tree owned by `renderOwner`. */
  disposeRender: (renderOwner: string) => void;
  /** Releases the remaining render tree when the WindowStage is torn down. */
  disposeAllRenders: () => void;
  /** Synchronous page-back decision exported by the native module, when it has one. */
  onBackPressIntercept?: () => boolean;
  /** Legacy N-API spelling retained for modules built before camel-case code generation. */
  on_back_press_intercept?: () => boolean;
  // ─── Optional NAPI free-function exports (issue #87 minor-4) ───
  // Crate-level `#[napi]` fns that the platform layer calls directly. Declared
  // optional: pre-pluginize legacy modules lack them, so callers keep their
  // typeof-probes before invoking. These used to be duck-typed via `as ESObject`.
  /** `is_desktop_device` — desktop form-factor probe (setupMenuPopup guard,
   *  FloatPage `__openharmony_ability_is_desktop__`). */
  isDesktopDevice?: () => boolean;
  /** `notify_window_close` — Float close-button / FloatPage aboutToDisappear. */
  notifyWindowClose?: (windowId: number) => void;
  /** `notify_window_status` — NativeAbility windowStatusChange fan-in. */
  notifyWindowStatus?: (windowId: number, status: number) => void;
  /** `read_continue_snapshot` — onContinue source-side snapshot read. */
  readContinueSnapshot?: () => string;
  /** `update_cursor_position` — MainPage onMouse cursor tracking. */
  updateCursorPosition?: (x: number, y: number) => void;
  /** `register_create_sub_window_tsfn` — legacy create_os_window path hookup. */
  registerCreateSubWindowTsfn?: (createSubWindow: (config: ESObject) => Promise<number>) => void;
  /**
   * Synchronous ArkTS platform callback -> Rust plugin decision. The value is a named N-API
   * object and must be returned before the platform callback resumes.
   */
  onBridgeSyncEvent?: (
    pluginId: string,
    event: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ) => ESObject;
  onBridgeLifecycle?: (kind: string) => void;
  /**
   * Legacy opt-in for native modules that register a custom `webview` URL scheme. Retained so
   * ProcessInitializer can probe for web-engine requirements on pre-pluginize modules. New
   * modules register schemes through their bridge plugin instead.
   */
  registerCustomProtocol?: () => void;
}

export type BridgePluginExecution = "async" | "sync-main-thread";
export type BridgeContextRequirement = "ability" | "window-stage" | "ui-context";

/** Rust-side scheduling contract exported after one native module configures its registry. */
export interface BridgePluginDeclaration {
  id: string;
  execution: BridgePluginExecution;
  requires: BridgeContextRequirement[];
}
