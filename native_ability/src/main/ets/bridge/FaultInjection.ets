/**
 * Fault injection registry + built-in bridge plugin for coverage testing.
 *
 * Runtime flag `enabled` defaults to `false`. Only the Rust facade (feature-gated
 * `fault-injection`) calls the "enable" action; production builds never enable →
 * `match()` short-circuits on the first line → zero overhead.
 *
 * Installed as a built-in plugin by BridgeHost (same pattern as NodeSurfacePlugin):
 *   - Not declared in Rust BridgePluginDeclaration / STATIC_PLUGINS
 *   - Not listed in EntryAbility bridgePlugins
 *   - Registered directly via `this.plugins.set(...)` in the constructor
 */

import {
  AsyncBridgePlugin,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeTypedValue,
} from "../ability/type";

const FAULT_PLUGIN_ID = "ohos.fault-injection";

/** Outcome descriptor — mirrors the Rust `FaultOutcomeWire` struct (camelCase via NAPI). */
interface FaultOutcome {
  kind: string; // "error" | "exception" | "delay" | "timeout"
  code?: number;
  message?: string;
  ms?: number;
}

/** Wire shape of a fault rule — mirrors Rust `FaultRuleWire` (camelCase via NAPI). */
interface FaultRuleWire {
  pluginId: string;
  action?: string;
  outcome: FaultOutcome;
  hits?: number;
}

/** Internal rule with bookkeeping fields. */
interface FaultRule {
  pluginId: string;
  action: string; // "" = match all actions of this plugin
  outcome: FaultOutcome;
  hits: number; // remaining hits; -1 = permanent until clear
  consumed: number;
}

class FaultInjectionRegistry {
  private rules: FaultRule[] = [];
  private enabled: boolean = false;

  enable(): void {
    this.enabled = true;
  }

  disable(): void {
    this.enabled = false;
    this.rules = [];
  }

  setRule(rule: FaultRule): void {
    this.rules.unshift(rule);
  }

  clear(): void {
    this.rules = [];
  }

  match(pluginId: string, action: string): FaultOutcome | undefined {
    if (!this.enabled) {
      return undefined;
    }
    for (let i = 0; i < this.rules.length; i++) {
      const r = this.rules[i];
      if (r.pluginId !== pluginId) {
        continue;
      }
      if (r.action !== "" && r.action !== action) {
        continue;
      }
      const outcome = r.outcome;
      r.consumed++;
      if (r.hits !== -1) {
        r.hits--;
        if (r.hits <= 0) {
          this.rules.splice(i, 1);
        }
      }
      return outcome;
    }
    return undefined;
  }
}

/** Module-level singleton — checked at both injection points in BridgeHost. */
const FAULT_REGISTRY = new FaultInjectionRegistry();

/** Acknowledgement response class — mirrors NodeAcknowledgement pattern. */
class FaultInjectionAck {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

/**
 * Built-in bridge plugin that controls the fault injection registry.
 *
 * Actions: "enable", "disable", "clear", "set-rule".
 * `requires: []` — no context dependency, available immediately after construction.
 */
class FaultInjectionPlugin implements AsyncBridgePlugin {
  readonly id = FAULT_PLUGIN_ID;
  readonly requires: BridgeContextRequirement[] = [];
  readonly execution: "async" = "async";

  async invokeAsync(
    action: string,
    request: BridgeTypedValue,
    _ctx: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (action === "enable") {
      FAULT_REGISTRY.enable();
      return { typeName: "ohos.fault-injection.Ack", value: new FaultInjectionAck(true) };
    }
    if (action === "disable") {
      FAULT_REGISTRY.disable();
      return { typeName: "ohos.fault-injection.Ack", value: new FaultInjectionAck(true) };
    }
    if (action === "clear") {
      FAULT_REGISTRY.clear();
      return { typeName: "ohos.fault-injection.Ack", value: new FaultInjectionAck(true) };
    }
    if (action === "set-rule") {
      const r = request.value as FaultRuleWire;
      FAULT_REGISTRY.setRule({
        pluginId: r.pluginId,
        action: r.action ?? "",
        outcome: r.outcome,
        hits: r.hits ?? -1,
        consumed: 0,
      });
      return { typeName: "ohos.fault-injection.Ack", value: new FaultInjectionAck(true) };
    }
    throw new Error(`Unsupported ohos.fault-injection action '${action}'`);
  }
}

export { FAULT_REGISTRY, FaultInjectionPlugin, FAULT_PLUGIN_ID };
