import { FrameNode } from "@ohos.arkui.node";
import { UIContext } from "@ohos.arkui.UIContext";

/**
 * Reverse-direction bridge port (PR #82 review 意见②③, har split).
 *
 * StatusBarUtils and DefaultXComponent used to import BridgeHostRegistry
 * directly — support-tree -> core-package edges the har split forbids
 * (@ohos-rs/ability depends on @ohos-rs/ability-support, never the reverse).
 * The core package inverts the edge at startup: BridgeHostRegistry.prepare()
 * installs its host-backed implementation via installNativeBridgePort() before
 * any component renders.
 *
 * Before the first install the port serves stub semantics identical to the
 * old no-host paths: process-wide fan-out returns no responses, attaching
 * throws the no-host error, detaching resolves. The stub is never restored
 * after a session ends — a stale port fails exactly like the stale host
 * lookup did before the split.
 */
export interface NativeBridgePort {
  invokeNativeSyncProcessWide(
    pluginId: string,
    event: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ): ESObject[];
  attachComponent(
    sessionId: string,
    moduleName: string,
    componentOwner: string,
    uiContext: UIContext,
    root: FrameNode,
  ): Promise<void>;
  detachComponent(sessionId: string, moduleName: string, componentOwner: string): Promise<void>;
}

class StubBridgePort implements NativeBridgePort {
  invokeNativeSyncProcessWide(
    _pluginId: string,
    _event: string,
    _requestTypeName: string,
    _responseTypeName: string,
    _value: ESObject,
  ): ESObject[] {
    return [];
  }

  attachComponent(_sessionId: string, moduleName: string): Promise<void> {
    throw new Error(
      `No bridge host for module '${moduleName}'. NativeAbility may have been destroyed or is not hosting this XComponent.`,
    );
  }

  detachComponent(_sessionId: string, _moduleName: string, _componentOwner: string): Promise<void> {
    return Promise.resolve();
  }
}

let port: NativeBridgePort = new StubBridgePort();

/** Called by the core package's BridgeHostRegistry.prepare() — see class doc. */
export function installNativeBridgePort(implementation: NativeBridgePort): void {
  port = implementation;
}

export function getNativeBridgePort(): NativeBridgePort {
  return port;
}
