// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! Shortcut event channel and NAPI callback.
//!
//! - Crossbeam channel for ArkTS → Rust shortcut events
//! - `#[napi]` function `emit_shortcut_event(id, state)` called by ArkTS
//!   when a registered shortcut is triggered

use crossbeam_channel::{bounded, Receiver, Sender};
use std::sync::LazyLock;

use super::types::{ShortcutEvent, ShortcutState};

// ─── Event channel ──────────────────────────────────────────────────────────

type ShortcutEventChannel = (Sender<ShortcutEvent>, Receiver<ShortcutEvent>);

static SHORTCUT_EVENT_CHANNEL: LazyLock<ShortcutEventChannel> =
    LazyLock::new(|| bounded::<ShortcutEvent>(256));

/// Internal: push a shortcut event onto the channel.
/// Called from the NAPI callback below.
pub(crate) fn emit_event(event: ShortcutEvent) {
    if let Err(e) = SHORTCUT_EVENT_CHANNEL.0.try_send(event) {
        crate::warn!("Failed to send shortcut event: {}", e);
    }
}

// ─── NAPI callback ──────────────────────────────────────────────────────────

/// Called by ArkTS when a registered shortcut is triggered.
///
/// ArkTS calls this as `emitShortcutEvent(id, state)` (camelCase auto-convert).
/// The `state` parameter is `"Pressed"` or `"Released"`.
///
/// OHOS `inputConsumer` only fires on key-down, so the ArkTS bridge emits
/// both Pressed and Released events sequentially to match the desktop
/// hotkey crate behavior on desktop platforms.
#[napi_derive_ohos::napi]
pub fn emit_shortcut_event(id: u32, state: String) {
    let parsed_state = match state.as_str() {
        "Pressed" => ShortcutState::Pressed,
        "Released" => ShortcutState::Released,
        _ => {
            crate::warn!("Unknown shortcut state: '{}', defaulting to Pressed", state);
            ShortcutState::Pressed
        }
    };
    emit_event(ShortcutEvent {
        id,
        state: parsed_state,
    });
}
