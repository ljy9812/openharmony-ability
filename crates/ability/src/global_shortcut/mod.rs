// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! OHOS global shortcut bridge via `inputConsumer` API (API 14+).
//!
//! ## Architecture
//!
//! ```text
//! Rust (register_shortcut)
//!   → crossbeam channel (REQUEST_CHANNEL)
//!   → forwarder thread
//!   → run_on_main_thread (Chrome_IOThread)
//!   → direct helper.registerHotkey / unregisterHotkey NAPI calls
//!   → ArkTS (inputConsumer.on / .off)
//!
//! ArkTS (hotkeyChange callback)
//!   → NAPI emitShortcutEvent(id, state)
//!   → crossbeam channel (SHORTCUT_EVENT_CHANNEL)
//!   → Rust consumer (shortcut_event_receiver)
//! ```

pub mod event;
pub mod types;

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, OnceLock};

use crossbeam_channel::{bounded, Receiver, Sender};

// ─── OHOS key code constants (matching ArkTS MODIFIER_MAP and KEY_MAP) ───

mod ohos_keycodes {
    // Modifier key codes (from OHOS KeyCode enum)
    pub const CTRL_LEFT: u32 = 2072;
    pub const SHIFT_LEFT: u32 = 2047;
    pub const ALT_LEFT: u32 = 2045;
    pub const META_LEFT: u32 = 2076;

    pub fn modifier_to_keycode(m: &super::Modifier) -> u32 {
        match m {
            super::Modifier::Control => CTRL_LEFT,
            super::Modifier::Shift => SHIFT_LEFT,
            super::Modifier::Alt => ALT_LEFT,
            super::Modifier::Super => META_LEFT,
        }
    }

    pub fn key_to_keycode(k: &super::Key) -> u32 {
        match k {
            super::Key::A => 2017, super::Key::B => 2018, super::Key::C => 2019,
            super::Key::D => 2020, super::Key::E => 2021, super::Key::F => 2022,
            super::Key::G => 2023, super::Key::H => 2024, super::Key::I => 2025,
            super::Key::J => 2026, super::Key::K => 2027, super::Key::L => 2028,
            super::Key::M => 2029, super::Key::N => 2030, super::Key::O => 2031,
            super::Key::P => 2032, super::Key::Q => 2033, super::Key::R => 2034,
            super::Key::S => 2035, super::Key::T => 2036, super::Key::U => 2037,
            super::Key::V => 2038, super::Key::W => 2039, super::Key::X => 2040,
            super::Key::Y => 2041, super::Key::Z => 2042,
            super::Key::Digit0 => 2000, super::Key::Digit1 => 2001,
            super::Key::Digit2 => 2002, super::Key::Digit3 => 2003,
            super::Key::Digit4 => 2004, super::Key::Digit5 => 2005,
            super::Key::Digit6 => 2006, super::Key::Digit7 => 2007,
            super::Key::Digit8 => 2008, super::Key::Digit9 => 2009,
            super::Key::F1 => 2090, super::Key::F2 => 2091, super::Key::F3 => 2092,
            super::Key::F4 => 2093, super::Key::F5 => 2094, super::Key::F6 => 2095,
            super::Key::F7 => 2096, super::Key::F8 => 2097, super::Key::F9 => 2098,
            super::Key::F10 => 2099, super::Key::F11 => 2100, super::Key::F12 => 2101,
            super::Key::F13 => 2816, super::Key::F14 => 2817, super::Key::F15 => 2818,
            super::Key::F16 => 2819, super::Key::F17 => 2820, super::Key::F18 => 2821,
            super::Key::F19 => 2822, super::Key::F20 => 2823, super::Key::F21 => 2824,
            super::Key::F22 => 2825, super::Key::F23 => 2826, super::Key::F24 => 2827,
            super::Key::Space => 2050, super::Key::Enter => 2054,
            super::Key::Escape => 2070, super::Key::Tab => 2049,
            super::Key::Backspace => 2055, super::Key::Delete => 2071,
            super::Key::Insert => 2083, // KEYCODE_INSERT
            // KEYCODE_HOME = 1 is the system Home button, not keyboard Home.
            // Keyboard Home (cursor to beginning) has no direct OHOS keycode equivalent.
            super::Key::Home => 1,
            super::Key::End => 2082, super::Key::PageUp => 2068,
            super::Key::PageDown => 2069, super::Key::ArrowUp => 2012,
            super::Key::ArrowDown => 2013, super::Key::ArrowLeft => 2014,
            super::Key::ArrowRight => 2015,
        }
    }
}

use self::types::{Key, Modifier, ShortcutRequest};
use crate::version;

// Re-export public API
pub use self::event::shortcut_event_receiver;
pub use self::types::{
    Key as ShortcutKey, Modifier as ShortcutModifier,
    ShortcutEvent, ShortcutState,
};

// ─── Constants ──────────────────────────────────────────────────────────────

/// Maximum number of modifier keys supported by OHOS `inputConsumer.preKeys`.
const MAX_MODIFIERS: usize = 2;

/// Minimum OHOS SDK API version required for `inputConsumer`.
const MIN_API_VERSION: i32 = 14;

// ─── Registered shortcuts tracking ──────────────────────────────────────────

/// Tracks which shortcut IDs have been successfully registered.
static REGISTERED_SHORTCUTS: LazyLock<Mutex<HashMap<u32, Vec<String>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

// ─── Dispatcher (set by plugin, wraps AppHandle::run_on_main_thread) ────────

type DispatcherFn = Box<dyn Fn(Box<dyn FnOnce() + Send>) + Send + Sync>;
static DISPATCHER: OnceLock<DispatcherFn> = OnceLock::new();

/// Initialize the global shortcut forwarder.
///
/// Must be called once from the plugin's `setup()`.
/// Accepts a dispatcher function that wraps `AppHandle::run_on_main_thread`,
/// so openharmony-ability doesn't need to depend on the tauri crate.
pub fn init_forwarder(dispatcher: impl Fn(Box<dyn FnOnce() + Send>) + Send + Sync + 'static) {
    if DISPATCHER.set(Box::new(dispatcher)).is_err() {
        crate::warn!("init_forwarder called more than once; ignoring duplicate initialization");
    }
}

// ─── Request channel (Rust → ArkTS) ────────────────────────────────────────

type RequestSender = Sender<ShortcutRequest>;

static REQUEST_CHANNEL: LazyLock<RequestSender> = LazyLock::new(|| {
    let (tx, rx) = bounded::<ShortcutRequest>(256);
    spawn_forwarder(rx);
    tx
});

// ─── Forwarder thread ───────────────────────────────────────────────────────

/// Spawns a background thread that receives shortcut requests from any thread
/// and forwards them to ArkTS via `run_on_main_thread` + direct helper calls.
///
/// The returned `JoinHandle` is intentionally dropped: this thread runs for the
/// entire application lifetime and is cleaned up by the OS on process exit.
fn spawn_forwarder(rx: Receiver<ShortcutRequest>) {
    std::thread::spawn(move || {
        while let Ok(request) = rx.recv() {
            match request {
                ShortcutRequest::Register {
                    id,
                    pre_key1,
                    pre_key2,
                    final_key,
                } => {
                    if let Err(e) = dispatch_to_main_thread(move || {
                        dispatch_register(id, pre_key1, pre_key2, final_key);
                    }) {
                        crate::warn!("dispatch_to_main_thread failed for Register id={}: {}", id, e);
                    }
                }
                ShortcutRequest::Unregister { id } => {
                    if let Err(e) = dispatch_to_main_thread(move || {
                        dispatch_unregister(id);
                    }) {
                        crate::warn!("dispatch_to_main_thread failed for Unregister id={}: {}", id, e);
                    }
                }
            }
        }
    });
}

/// Schedule a closure to run on the main thread via the stored dispatcher.
///
/// Returns an error if the dispatcher has not been initialized (i.e.,
/// `init_forwarder` was not called). Previously this silently dropped the
/// closure; now it returns an error so callers can handle the failure.
fn dispatch_to_main_thread(f: impl FnOnce() + Send + 'static) -> std::result::Result<(), String> {
    if let Some(dispatcher) = DISPATCHER.get() {
        dispatcher(Box::new(f));
        Ok(())
    } else {
        Err("Global shortcut dispatcher not initialized (call init_forwarder first)".to_string())
    }
}

/// Called on Chrome_IOThread: directly call `helper.registerHotkey(id, modifiersJson, key)`.
fn dispatch_register(id: u32, pre_key1: u32, pre_key2: u32, final_key: u32) {
    use napi_ohos::bindgen_prelude::{Function, JsObjectValue, Unknown};

    let env_cell = crate::get_main_thread_env();
    let env_opt = env_cell.borrow();
    let Some(env_ref) = env_opt.as_ref() else {
        crate::warn!("dispatch_register: main thread env not available");
        return;
    };
    // SAFETY: get_helper() is called within dispatch_to_main_thread which ensures
    // we're on the correct thread (Chrome_IOThread / main thread).
    let helper = unsafe { crate::get_helper() };
    let helper_borrow = helper.borrow();
    let Some(helper_ref) = helper_borrow.as_ref() else {
        crate::warn!("dispatch_register: helper not available");
        return;
    };
    let Ok(helper_obj) = helper_ref.get_value(env_ref) else {
        crate::warn!("dispatch_register: failed to get helper object value");
        return;
    };
    let Ok(fn_ref) = helper_obj
        .get_named_property::<Function<'_, String, Unknown<'_>>>("registerHotkey")
    else {
        crate::warn!("dispatch_register: registerHotkey not found on helper");
        return;
    };
    // JSON string is used because napi-ohos Function::call with tuple (u32, u32, u32, u32)
    // does not correctly pass multiple arguments to ArkTS. Single String argument works reliably.
    let json = format!(r#"{{"id":{},"preKey1":{},"preKey2":{},"finalKey":{}}}"#, id, pre_key1, pre_key2, final_key);
    if let Err(e) = fn_ref.call(json) {
        crate::warn!("dispatch_register: registerHotkey NAPI call failed: {}", e);
    }
}

/// Called on Chrome_IOThread: directly call `helper.unregisterHotkey(id)`.
fn dispatch_unregister(id: u32) {
    use napi_ohos::bindgen_prelude::{Function, JsObjectValue, Unknown};

    let env_cell = crate::get_main_thread_env();
    let env_opt = env_cell.borrow();
    let Some(env_ref) = env_opt.as_ref() else {
        crate::warn!("dispatch_unregister: main thread env not available");
        return;
    };
    // SAFETY: get_helper() is called within dispatch_to_main_thread which ensures
    // we're on the correct thread (Chrome_IOThread / main thread).
    let helper = unsafe { crate::get_helper() };
    let helper_borrow = helper.borrow();
    let Some(helper_ref) = helper_borrow.as_ref() else {
        crate::warn!("dispatch_unregister: helper not available");
        return;
    };
    let Ok(helper_obj) = helper_ref.get_value(env_ref) else {
        crate::warn!("dispatch_unregister: failed to get helper object value");
        return;
    };
    let Ok(fn_ref) = helper_obj
        .get_named_property::<Function<'_, u32, Unknown<'_>>>("unregisterHotkey")
    else {
        crate::warn!("dispatch_unregister: unregisterHotkey not found on helper");
        return;
    };
    if let Err(e) = fn_ref.call(id) {
        crate::warn!("dispatch_unregister: unregisterHotkey NAPI call failed: {}", e);
    }
}

// ─── Public API ─────────────────────────────────────────────────────────────

/// Register a global shortcut on OHOS.
///
/// - `modifiers`: modifier keys (max 2, OHOS `inputConsumer` limit)
/// - `key`: the main key
/// - `id`: unique identifier for this shortcut
///
/// ## Design notes
///
/// **Fire-and-forget:** This function sends the registration request to a
/// background forwarder thread via a bounded channel and returns `Ok(())`
/// immediately. The actual ArkTS `inputConsumer.on()` call happens
/// asynchronously on the main thread. If the ArkTS side fails, the error is
/// logged via hilog but is **not** propagated back to the caller. Blocking here
/// would risk a deadlock (the main thread may be waiting on the calling thread),
/// so this is an intentional trade-off.
///
/// **Best-effort registration:** OHOS `inputConsumer.on` may fail for reasons
/// such as the hotkey being occupied by the system (error 4200002) or another
/// app (error 4200003). These failures are logged on the ArkTS side but the
/// Rust caller sees `Ok(())` regardless. This matches the fire-and-forget
/// design above.
///
/// **Synthetic Released event:** The OHOS `inputConsumer` API only fires a
/// callback on key-down (hotkey press). It does **not** provide real key-up
/// events. To match the cross-platform `ShortcutEvent` contract, a `Released`
/// event is synthesized immediately after `Pressed` on the ArkTS side.
///
/// Returns `Ok(())` on success. On API < 14, silently returns `Ok(())`
/// without registering (version guard).
pub fn register_shortcut(
    modifiers: &[Modifier],
    key: Key,
    id: u32,
) -> std::result::Result<(), String> {
    // Validate: at least 1 modifier required (inputConsumer requires preKeys to be non-empty)
    if modifiers.is_empty() {
        return Err("At least 1 modifier key is required for OHOS shortcuts".to_string());
    }

    // Validate modifier count: max 2 (OHOS inputConsumer limit)
    if modifiers.len() > MAX_MODIFIERS {
        return Err(format!(
            "OHOS supports at most {} modifier keys, got {}",
            MAX_MODIFIERS,
            modifiers.len()
        ));
    }

    // Version guard: silently skip on API < 14
    if version::sdk_api_version() < MIN_API_VERSION {
        crate::info!(
            "register_shortcut: API version {} < {}, skipping",
            version::sdk_api_version(),
            MIN_API_VERSION
        );
        return Ok(());
    }

    // Remove consecutive duplicate modifiers (e.g. Ctrl+Ctrl+T → Ctrl+T)
    let mut unique_modifiers: Vec<Modifier> = modifiers.to_vec();
    unique_modifiers.dedup();

    // Convert modifiers and key to OHOS key codes
    let pre_key1 = ohos_keycodes::modifier_to_keycode(&unique_modifiers[0]);
    let pre_key2 = if unique_modifiers.len() > 1 {
        ohos_keycodes::modifier_to_keycode(&unique_modifiers[1])
    } else {
        0
    };
    let final_key = ohos_keycodes::key_to_keycode(&key);

    // Track registration (unregister old if re-registering same id)
    let should_unregister = {
        let mut registered = REGISTERED_SHORTCUTS.lock().unwrap_or_else(|e| e.into_inner());
        let existed = registered.remove(&id).is_some();
        registered.insert(id, vec![format!("{}+{}", pre_key1, final_key)]);
        existed
    };
    // Unregister old registration AFTER lock is released (unregister_shortcut acquires same mutex)
    if should_unregister {
        // Bypass unregister_shortcut() since the HashMap entry was already removed.
        // Directly send the unregister request to the forwarder channel.
        let request = ShortcutRequest::Unregister { id };
        if let Err(e) = REQUEST_CHANNEL.try_send(request) {
            crate::warn!("Failed to send unregister for re-registration id={}: {}", id, e);
        }
    }

    // Send request to forwarder thread (try_send is intentional: see fire-and-forget
    // design note above — blocking here would risk deadlock with the main thread).
    let request = ShortcutRequest::Register {
        id,
        pre_key1,
        pre_key2,
        final_key,
    };
    REQUEST_CHANNEL
        .try_send(request)
        .map_err(|e| format!("Failed to send register request: {}", e))?;

    Ok(())
}

/// Unregister a previously registered shortcut.
///
/// Idempotent: calling with an unregistered ID is a no-op.
pub fn unregister_shortcut(id: u32) -> std::result::Result<(), String> {
    // Remove from tracking
    {
        let mut registered = REGISTERED_SHORTCUTS.lock().unwrap_or_else(|e| e.into_inner());
        if registered.remove(&id).is_none() {
            return Ok(());
        }
    }

    let request = ShortcutRequest::Unregister { id };
    REQUEST_CHANNEL
        .try_send(request)
        .map_err(|e| format!("Failed to send unregister request: {}", e))?;

    Ok(())
}

/// Unregister all shortcuts registered by this module.
///
/// Note: The ArkTS side exposes an `unregisterAllHotkeys()` helper that
/// iterates over registered hotkeys internally. This Rust function instead
/// sends individual `Unregister` requests per ID through the forwarder
/// channel, which is functionally equivalent. The ArkTS helper is kept for
/// symmetry and potential future direct use, but is not called from Rust.
pub fn unregister_all_shortcuts() -> std::result::Result<(), String> {
    let ids: Vec<u32> = {
        let mut registered = REGISTERED_SHORTCUTS.lock().unwrap_or_else(|e| e.into_inner());
        let ids: Vec<u32> = registered.keys().copied().collect();
        registered.clear();
        ids
    };

    for id in ids {
        let request = ShortcutRequest::Unregister { id };
        // Use blocking send here: the forwarder thread is always running and
        // will consume from the channel, so this won't deadlock. Blocking send
        // ensures no unregister requests are silently dropped under backpressure.
        if let Err(e) = REQUEST_CHANNEL.send(request) {
            crate::warn!(
                "Failed to send unregister_all request for id={}: {}",
                id,
                e
            );
        }
    }

    Ok(())
}
