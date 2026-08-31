//! Fault injection wire types for coverage testing.
//!
//! Feature-gated behind `fault-injection`. When the feature is off, none of
//! these types are compiled, and the ArkTS `FAULT_REGISTRY.enabled` flag stays
//! `false` (never called from Rust) — zero overhead in production.
//!
//! The ArkTS side (`FaultInjection.ets`) is always compiled but short-circuits
//! at `match()` when disabled. Only the Rust facade (`OpenHarmonyApp::set_fault_rule`
//! / `clear_fault_rules`) calls the "enable" action to turn on injection.

use napi_derive_ohos::napi;
use serde::{Deserialize, Serialize};

use crate::impl_bridge_napi_type;

/// Empty request marker for the "enable" / "disable" / "clear" actions.
/// The ArkTS plugin ignores the request value for these actions.
#[napi(object)]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct FaultNoopRequest {}

impl_bridge_napi_type!(FaultNoopRequest, "ohos.fault-injection.NoopRequest");

/// Outcome descriptor — napi-derive emits camelCase keys (`kind`, `code`,
/// `message`, `ms`) matching the ArkTS `FaultOutcome` interface.
///
/// `kind` is one of: `"error"`, `"exception"`, `"delay"`, `"timeout"`.
/// `code`/`message` are used by error/exception; `ms` by delay; timeout uses none.
#[napi(object)]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FaultOutcomeWire {
    pub kind: String,
    pub code: Option<i32>,
    pub message: Option<String>,
    pub ms: Option<u32>,
}

/// Wire format for a fault rule — sent via the "set-rule" action.
/// napi-derive emits camelCase keys (`pluginId`, `action`, `outcome`, `hits`).
#[napi(object)]
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FaultRuleWire {
    pub plugin_id: String,
    pub action: Option<String>,
    pub outcome: FaultOutcomeWire,
    pub hits: Option<i32>,
}

impl_bridge_napi_type!(FaultRuleWire, "ohos.fault-injection.SetRuleRequest");

/// Acknowledgement response — mirrors the ArkTS `FaultInjectionAck` class.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct FaultInjectionAck {
    pub accepted: bool,
}

impl_bridge_napi_type!(FaultInjectionAck, "ohos.fault-injection.Ack");
