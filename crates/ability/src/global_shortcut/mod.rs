// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! OHOS global shortcut types.
//!
//! The bridge plugin facade (`openharmony-ability-plugin-global-shortcut`)
//! handles register/unregister/event operations through the bridge
//! plugin model; this module retains only the type definitions.
//!
//! Shortcut-triggered events do NOT flow through this module: the facade
//! decodes `on-shortcut-triggered` main-thread events and forwards them
//! through its own crossbeam channel (`openharmony-ability-plugin-global-shortcut`
//! `SHORTCUT_EVENT_CHANNEL`), which consumers poll via its NAPI exports.

pub mod types;

// Re-export public types
pub use self::types::{
    Key as ShortcutKey, Modifier as ShortcutModifier, ShortcutEvent, ShortcutState,
};
