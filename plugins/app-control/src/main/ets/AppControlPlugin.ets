import common from "@ohos.app.ability.common";
import { ConfigurationConstant } from "@kit.AbilityKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { Want } from "@kit.AbilityKit";
import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  SyncPluginBase,
} from "@ohos-rs/ability";

const TERMINATE_REQUEST_TYPE = "ohos.app_control.TerminateRequest";
const TERMINATE_RESPONSE_TYPE = "ohos.app_control.TerminateResponse";
const SET_COLOR_MODE_REQUEST_TYPE = "ohos.app_control.SetColorModeRequest";
const SET_COLOR_MODE_RESPONSE_TYPE = "ohos.app_control.SetColorModeResponse";
const HIDE_ABILITY_REQUEST_TYPE = "ohos.app_control.HideAbilityRequest";
const HIDE_ABILITY_RESPONSE_TYPE = "ohos.app_control.HideAbilityResponse";
const SHOW_ABILITY_REQUEST_TYPE = "ohos.app_control.ShowAbilityRequest";
const SHOW_ABILITY_RESPONSE_TYPE = "ohos.app_control.ShowAbilityResponse";
const RESTART_REQUEST_TYPE = "ohos.app_control.RestartRequest";
const RESTART_RESPONSE_TYPE = "ohos.app_control.RestartResponse";
const START_UI_ABILITY_REQUEST_TYPE = "ohos.app_control.StartUiAbilityRequest";
const START_UI_ABILITY_RESPONSE_TYPE = "ohos.app_control.StartUiAbilityResponse";

interface TerminateRequest {
  code: number;
}

interface SetColorModeRequest {
  colorMode: number;
}

interface RestartRequest {
}

interface StartUiAbilityRequest {
  windowId: number;
  label: string;
  url: string;
  transparent: boolean;
}


class TerminateResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class SetColorModeResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class HideAbilityResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class ShowAbilityResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class RestartResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class StartUiAbilityResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseTerminateRequest(payload: BridgeTypedValue): TerminateRequest {
  if (payload.typeName !== TERMINATE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.app-control.terminate requires bridge type ${TERMINATE_REQUEST_TYPE}`);
  }
  const request = payload.value as TerminateRequest;
  if (!Number.isInteger(request?.code)) {
    throw new Error("terminate.code must be an integer");
  }
  return request;
}

function parseSetColorModeRequest(payload: BridgeTypedValue): SetColorModeRequest {
  if (payload.typeName !== SET_COLOR_MODE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.app-control.set-color-mode requires bridge type ${SET_COLOR_MODE_REQUEST_TYPE}`);
  }
  const request = payload.value as SetColorModeRequest;
  if (!Number.isInteger(request?.colorMode)) {
    throw new Error("set-color-mode.colorMode must be an integer");
  }
  return request;
}

function parseRestartRequest(payload: BridgeTypedValue): RestartRequest {
  if (payload.typeName !== RESTART_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.app-control.restart requires bridge type ${RESTART_REQUEST_TYPE}`);
  }
  return payload.value as RestartRequest;
}

function parseStartUiAbilityRequest(payload: BridgeTypedValue): StartUiAbilityRequest {
  if (payload.typeName !== START_UI_ABILITY_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.app-control.start-ui-ability requires bridge type ${START_UI_ABILITY_REQUEST_TYPE}`);
  }
  const request = payload.value as StartUiAbilityRequest;
  // windowId must be a positive integer: 0 is the process's original
  // UIAbility instance, which never goes through start-ui-ability. A 0 here
  // would make the new instance overwrite the primary registry entry (R4).
  if (!Number.isInteger(request?.windowId) || request.windowId <= 0) {
    throw new Error("start-ui-ability.windowId must be a positive integer");
  }
  if (typeof request?.label !== "string" || request.label.length === 0) {
    throw new Error("start-ui-ability.label must be a non-empty string");
  }
  if (typeof request?.url !== "string") {
    throw new Error("start-ui-ability.url must be a string (may be empty)");
  }
  if (typeof request?.transparent !== "boolean") {
    throw new Error("start-ui-ability.transparent must be a boolean");
  }
  return request;
}

export class AppControlPlugin extends SyncPluginBase {
  readonly id = "ohos.app-control";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  invokeSync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): BridgeTypedValue {
    if (action === "terminate") {
      const request = parseTerminateRequest(payload);
      // Graceful termination via terminateSelf. The exit code is advisory only
      // (logged): OHOS ability termination has no process exit-code channel.
      // The previous implementation called process.ProcessManager.exit(code),
      // which appspawn intercepts and converts to SIGABRT — every terminate
      // left a cppcrash record (same family as the old tray Quit workaround).
      // Deferred to the next event-loop tick so the bridge response unwinds
      // before ability teardown begins (same pattern as set-color-mode).
      const ctx = context.abilityContext;
      console.info(`[AppControl] terminateSelf requested (exit code ${request.code} is advisory)`);
      setTimeout(() => {
        ctx.terminateSelf().catch((e: BusinessError) => {
          console.error(`[AppControl] terminateSelf failed: ${e.code} ${e.message}`);
        });
      }, 0);
      return { typeName: TERMINATE_RESPONSE_TYPE, value: new TerminateResponse(true) };
    }

    if (action === "restart") {
      parseRestartRequest(payload);
      // restartApp (API 12+) asks the OS to relaunch this ability: the window
      // closes, the process is torn down and relaunched by the system. Unlike
      // the desktop model (spawn a fresh process + exit), self-spawning is not
      // possible for third-party OHOS apps — the appspawn supervisor owns the
      // process lifecycle, and a direct exit() is converted to SIGABRT.
      // restartApp must be called while the app is in the foreground with
      // focus; from the background the system rejects the request.
      const ctx = context.abilityContext;
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name,
      };
      const appCtx = ctx.getApplicationContext();
      if (typeof appCtx.restartApp !== "function") {
        throw new Error("restart requires API level 12+ on OpenHarmony (restartApp is unavailable)");
      }
      setTimeout(() => {
        try {
          appCtx.restartApp(want);
        } catch (err) {
          console.error(`[AppControl] restartApp failed: ${String(err)}`);
        }
      }, 0);
      return { typeName: RESTART_RESPONSE_TYPE, value: new RestartResponse(true) };
    }

    if (action === "set-color-mode") {
      const request = parseSetColorModeRequest(payload);
      this.setAppColorMode(request.colorMode, context);
      return { typeName: SET_COLOR_MODE_RESPONSE_TYPE, value: new SetColorModeResponse(true) };
    }

    if (action === "hide-ability") {
      const ctx = context.abilityContext;
      // hideAbility() takes no arguments in the current SDK (fire-and-forget).
      ctx.hideAbility();
      return { typeName: HIDE_ABILITY_RESPONSE_TYPE, value: new HideAbilityResponse(true) };
    }

    if (action === "show-ability") {
      // D4 specified amendment (openspec multi-uiability-windows): under
      // launchType "specified" + AbilityStage.onAcceptWant, a bare
      // self-targeting startAbility routes to the live primary instance —
      // AMS pulls it back to the top of the stack. This is the only
      // mechanism that also covers a context.hideAbility()-hidden ability
      // (window-level showWindow cannot — device-proven regression under
      // the interim "standard" + showWindowMethod variant, 2026-09-15).
      // (Multi-window spawn has its own action: "start-ui-ability" below.)
      const ctx = context.abilityContext;
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name,
      };
      // startAbility(want) supports Promise (unlike hideAbility which is callback-only).
      // Fire-and-forget: initiate the call and immediately return accepted=true.
      ctx.startAbility(want).catch((e: BusinessError) => {
        console.error(`[AppControl] showAbility failed: ${e.code} ${e.message}`);
      });
      return { typeName: SHOW_ABILITY_RESPONSE_TYPE, value: new ShowAbilityResponse(true) };
    }

    if (action === "start-ui-ability") {
      const request = parseStartUiAbilityRequest(payload);
      const ctx = context.abilityContext;
      // All parameters must be strings: AMS re-parses scalar values when the
      // Want crosses the binder boundary, and non-string values silently lose
      // their type. Stringifying keeps tauri_window_id intact for the new
      // instance's onCreate (Number(...) read on the other side).
      const params: Record<string, Object> = {
        "tauri_window_id": String(request.windowId),
        "tauri_window_label": request.label,
        "tauri_window_url": request.url,
        "tauri_transparent": String(request.transparent),
      };
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name,
        parameters: params,
      };
      console.info(`[AppControl] start-ui-ability: id=${request.windowId} label=${request.label} url='${request.url}' transparent=${request.transparent}`);
      // Escape the NAPI re-entrancy context before calling AMS: startAbility
      // invoked synchronously inside a bridge (MainThreadSync) callback drops
      // want.parameters (multi-uiability-windows design D1). Fire-and-forget —
      // the Rust caller already returned with its pre-allocated window id and
      // observes the handshake via register_ui_ability_stage, not this
      // response (accepted = "dispatched", not "instance created").
      setTimeout(() => {
        ctx.startAbility(want).catch((e: BusinessError) => {
          console.error(`[AppControl] start-ui-ability id=${request.windowId} failed: ${e.code} ${e.message}`);
        });
      }, 0);
      return { typeName: START_UI_ABILITY_RESPONSE_TYPE, value: new StartUiAbilityResponse(true) };
    }

    throw new Error(`Unsupported ohos.app-control action '${action}'`);
  }

  private setAppColorMode(code: number, context: BridgeCallContext): void {
    // Map the bridge integer to ConfigurationConstant.ColorMode.
    // 0 → COLOR_MODE_DARK, 1 → COLOR_MODE_LIGHT, default → COLOR_MODE_NOT_SET.
    // Do NOT pass the raw integer to setColorMode — OHOS expects the enum value,
    // and 2 is not a legal ColorMode value (NOT_SET is a distinct constant).
    let colorMode: ConfigurationConstant.ColorMode;
    switch (code) {
      case 0:
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
        break;
      case 1:
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
        break;
      default:
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
        break;
    }

    // Capture only the application context (survives the callback) — the
    // BridgeCallContext itself is only valid during the current N-API callback.
    const applicationContext = context.abilityContext.getApplicationContext();

    // Defer setColorMode to the next event-loop tick to avoid deadlock:
    // setColorMode synchronously triggers onConfigurationUpdate, which calls
    // back into Rust on the main thread. If we are already inside a NAPI
    // callback from Rust (MainThreadSync), this deadlocks the main thread.
    // See ohos-constraints 4.3 and ArkHelper.ets L893-927 for the same pattern.
    setTimeout(() => {
      try {
        applicationContext.setColorMode(colorMode);
      } catch (err) {
        // The ability may have been destroyed between scheduling and execution.
        // Silently swallow — the response was already accepted.
      }
    }, 0);
  }
}
