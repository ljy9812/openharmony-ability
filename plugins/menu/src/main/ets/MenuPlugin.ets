import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  getMenuDataCallback,
  getPredefinedActionExecutor,
  WindowManager,
  type PredefinedType,
} from "@ohos-rs/ability";

const DOMAIN: number = 0x1999;

const SET_MENUBAR_REQUEST_TYPE = "ohos.menu.SetMenubarRequest";
const POPUP_REQUEST_TYPE = "ohos.menu.PopupRequest";
const SET_VISIBLE_REQUEST_TYPE = "ohos.menu.SetVisibleRequest";
const PREDEFINED_REQUEST_TYPE = "ohos.menu.PredefinedRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.menu.Acknowledgement";

interface SetMenubarRequest {
  jsonData: string;
  windowId: string;
}

interface PopupRequest {
  jsonData: string;
  x?: number;
  y?: number;
  windowId: string;
}

interface SetVisibleRequest {
  visible: boolean;
  windowId: string;
}

interface PredefinedRequest {
  action: string;
  windowId?: string;
}

class MenuAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function expectRequestType(
  payload: BridgeTypedValue,
  action: string,
  typeName: string,
): ESObject {
  if (payload.typeName !== typeName || payload.value === null || typeof payload.value !== "object") {
    throw new Error(`ohos.menu.${action} requires bridge type ${typeName}`);
  }
  return payload.value as ESObject;
}

/**
 * Menu bridge plugin for ArkTS.
 *
 * Routes menu bar and popup operations from the Rust `MenuClient` facade to
 * the existing MenuBarComponent callback registry and PredefinedActionExecutor
 * singleton. Replaces the legacy `onMenuRequest` callback path in
 * NativeAbility.setupMenuPopup.
 *
 * Plugin ID: `ohos.menu`
 * Required contexts: ui-context (for popup positioning within the window)
 */
export class MenuPlugin extends AsyncPluginBase {
  readonly id = "ohos.menu";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Menu bridge session is no longer active");
    }

    if (action === "set-menubar") {
      const request = expectRequestType(payload, action, SET_MENUBAR_REQUEST_TYPE) as SetMenubarRequest;
      if (typeof request.jsonData !== "string") {
        throw new Error("set-menubar.jsonData must be a string");
      }
      if (typeof request.windowId !== "string") {
        throw new Error("set-menubar.windowId must be a string");
      }
      const cb = getMenuDataCallback(request.windowId);
      if (cb) {
        cb.onMenubarJson?.(request.jsonData);
      } else {
        hilog.warn(DOMAIN, "MenuPlugin", "set-menubar: no callback for window '%{public}s'", request.windowId);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new MenuAcknowledgement(true) };
    }

    if (action === "popup") {
      const request = expectRequestType(payload, action, POPUP_REQUEST_TYPE) as PopupRequest;
      hilog.info(DOMAIN, "MenuPlugin", "popup windowId=%{public}s x=%{public}d y=%{public}d jsonLen=%{public}d",
        request.windowId, request.x ?? 0, request.y ?? 0, request.jsonData.length);
      if (typeof request.jsonData !== "string") {
        throw new Error("popup.jsonData must be a string");
      }
      if (typeof request.windowId !== "string") {
        throw new Error("popup.windowId must be a string");
      }
      const x = request.x ?? 0;
      const y = request.y ?? 0;
      const cb = getMenuDataCallback(request.windowId);
      if (cb) {
        cb.onMenuPopup?.(request.jsonData, x, y);
      } else {
        hilog.warn(DOMAIN, "MenuPlugin", "popup: no callback for window '%{public}s'", request.windowId);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new MenuAcknowledgement(true) };
    }

    if (action === "set-menubar-visible") {
      const request = expectRequestType(payload, action, SET_VISIBLE_REQUEST_TYPE) as SetVisibleRequest;
      if (typeof request.visible !== "boolean") {
        throw new Error("set-menubar-visible.visible must be a boolean");
      }
      if (typeof request.windowId !== "string") {
        throw new Error("set-menubar-visible.windowId must be a string");
      }
      const cb = getMenuDataCallback(request.windowId);
      if (cb) {
        cb.onMenubarVisible?.(request.visible);
      } else {
        hilog.warn(DOMAIN, "MenuPlugin", "set-menubar-visible: no callback for window '%{public}s'", request.windowId);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new MenuAcknowledgement(true) };
    }

    if (action === "execute-predefined") {
      const request = expectRequestType(payload, action, PREDEFINED_REQUEST_TYPE) as PredefinedRequest;
      if (typeof request.action !== "string" || !request.action) {
        throw new Error("execute-predefined.action must be a non-empty string");
      }
      const executor = getPredefinedActionExecutor();
      if (!executor) {
        hilog.warn(DOMAIN, "MenuPlugin", "execute-predefined: PredefinedActionExecutor not initialized, action: %{public}s", request.action);
        throw new Error("PredefinedActionExecutor not initialized");
      }
      const actionType = request.action as PredefinedType;
      // Window operations (minimize/hide/close) are deferred via WindowManager to
      // avoid racing with system foreground transitions, matching the legacy
      // ArkHelper.executePredefinedAction behavior.
      const WINDOW_OPERATIONS: PredefinedType[] = ["minimize", "hide", "close"];
      if (WINDOW_OPERATIONS.includes(actionType)) {
        hilog.info(DOMAIN, "MenuPlugin", "Deferring window operation '%{public}s'", request.action);
        const wm = WindowManager.getInstance();
        wm.setPendingAction(() => {
          executor.execute(actionType);
        });
      } else {
        executor.execute(actionType);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new MenuAcknowledgement(true) };
    }

    throw new Error(`Unsupported ohos.menu action '${action}'`);
  }
}
