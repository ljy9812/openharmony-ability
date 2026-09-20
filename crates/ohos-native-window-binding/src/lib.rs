//! OpenHarmony native window NDK bindings — `OH_WindowManager_LockCursor` /
//! `OH_WindowManager_UnlockCursor`.
//!
//! Pure FFI against `libnative_window_manager.so` (oh_window.h, @since 22,
//! permission `ohos.permission.LOCK_WINDOW_CURSOR` / normal / system_grant) —
//! no ArkTS bridge involvement. No ArkTS API exists for cursor locking.
//!
//! The library is resolved lazily via dlopen+dlsym instead of a static
//! `#[link]`: compatibleSdkVersion is API 12 and system images below API 22
//! do not export these symbols, so a load-time link would prevent the app
//! from starting on older devices. Symbol presence doubles as the version
//! guard (dlsym null ⇒ device below API 22 ⇒ `NotSupported`).
//!
//! This crate is intentionally dependency-free (std only) so it can be
//! contributed upstream to the `ohos-rs/ohos-native-bindings` collection;
//! `openharmony-ability` consumes it via the `window` feature and re-exports
//! `set_cursor_grab` from its `window` module, so
//! `openharmony_ability::window::set_cursor_grab` keeps resolving.
//!
//! On non-OHOS hosts the resolver always reports unsupported; callers get
//! `CursorGrabError::NotSupported`, which keeps the crate compilable and
//! unit-testable on host toolchains.

// Ported from upstream PR#45 (50d3f00). Unlike upstream, this port takes the
// REAL OHOS window id directly. Upstream resolved the tao window id → real id
// internally via the old ArkHelper channel (deleted in the pluginize refactor).
// The ability crate cannot call the plugin-window facade itself (dependency
// direction: plugin-window → ability), so tao resolves the real id via the
// bridge (`get-real-window-id` action) before calling `set_cursor_grab`
// (design D3.7, openspec upstream-ohdev-rebase-window-ops).

use std::sync::OnceLock;

type LockCursorFn = unsafe extern "C" fn(window_id: i32, is_cursor_follow_movement: bool) -> i32;
type UnlockCursorFn = unsafe extern "C" fn(window_id: i32) -> i32;

struct CursorLockApi {
    lock_cursor: LockCursorFn,
    unlock_cursor: UnlockCursorFn,
}

/// WindowManager C API error code for "capability not supported" (oh_window_comm.h).
const WM_ERRORCODE_DEVICE_NOT_SUPPORTED: i32 = 801;
/// WindowManager C API error code for "window state abnormal" (oh_window_comm.h).
const WM_ERRORCODE_STATE_ABNORMAL: i32 = 1300002;

/// First reason the cursor lock API could not be resolved (dlopen/dlsym
/// failure). Only set on OHOS; folded into `CursorGrabError::NotSupported`'s
/// `Display` so the crate stays dependency-free while keeping diagnosability.
static CURSOR_LOCK_UNSUPPORTED_REASON: OnceLock<&'static str> = OnceLock::new();

#[cfg(target_env = "ohos")]
static CURSOR_LOCK_API: OnceLock<Option<CursorLockApi>> = OnceLock::new();

#[cfg(target_env = "ohos")]
extern "C" {
    fn dlopen(filename: *const std::ffi::c_char, flags: std::ffi::c_int) -> *mut std::ffi::c_void;
    fn dlsym(
        handle: *mut std::ffi::c_void,
        symbol: *const std::ffi::c_char,
    ) -> *mut std::ffi::c_void;
}

/// Resolves the cursor lock C API once per process; `None` when the system
/// does not provide it (API < 22). The handle is intentionally never closed —
/// the library stays loaded for the process lifetime.
#[cfg(target_env = "ohos")]
fn cursor_lock_api() -> Option<&'static CursorLockApi> {
    CURSOR_LOCK_API
        .get_or_init(|| unsafe {
            // RTLD_NOW | RTLD_LOCAL = 2 on OHOS musl.
            let handle = dlopen(c"libnative_window_manager.so".as_ptr(), 2);
            if handle.is_null() {
                let _ = CURSOR_LOCK_UNSUPPORTED_REASON
                    .set("dlopen libnative_window_manager.so failed (library missing/broken)");
                return None;
            }
            let lock = dlsym(handle, c"OH_WindowManager_LockCursor".as_ptr());
            let unlock = dlsym(handle, c"OH_WindowManager_UnlockCursor".as_ptr());
            if lock.is_null() || unlock.is_null() {
                let _ = CURSOR_LOCK_UNSUPPORTED_REASON
                    .set("OH_WindowManager_LockCursor/UnlockCursor not exported");
                return None;
            }
            Some(CursorLockApi {
                lock_cursor: std::mem::transmute::<*mut std::ffi::c_void, LockCursorFn>(lock),
                unlock_cursor: std::mem::transmute::<*mut std::ffi::c_void, UnlockCursorFn>(unlock),
            })
        })
        .as_ref()
}

/// Host stub: the NDK library only exists on OHOS devices.
#[cfg(not(target_env = "ohos"))]
fn cursor_lock_api() -> Option<&'static CursorLockApi> {
    None
}

/// Typed error for `set_cursor_grab` — tao maps `NotSupported` to
/// `ExternalError::NotSupported` (pre-change behavior on unsupported devices)
/// and the other variants to `ExternalError::Os`.
#[derive(Debug)]
pub enum CursorGrabError {
    /// System does not support cursor lock: dlsym failed (API < 22) or the
    /// FFI call returned 801 (DEVICE_NOT_SUPPORTED).
    NotSupported,
    /// FFI error code: 201 (no permission), 1300002 (window state abnormal),
    /// 1300003 (window manager service abnormal), or any other nonzero code.
    OsCode(i32),
    /// Caller-provided real window id is invalid (≤ 0), or the bridge lookup
    /// upstream failed before reaching this function.
    Bridge(String),
}

impl std::fmt::Display for CursorGrabError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CursorGrabError::NotSupported => {
                let base = "cursor lock not supported on this device";
                match CURSOR_LOCK_UNSUPPORTED_REASON.get() {
                    Some(reason) => write!(f, "{base} ({reason})"),
                    None => write!(f, "{base}"),
                }
            }
            CursorGrabError::OsCode(code) => write!(f, "window manager error code {code}"),
            CursorGrabError::Bridge(reason) => write!(f, "cursor grab bridge failure: {reason}"),
        }
    }
}

/// Locks/unlocks the mouse cursor to a window (tao `set_cursor_grab`).
///
/// `real_window_id` is the REAL OHOS window instance id (from
/// `win.getWindowProperties().id`), resolved by tao via the plugin-window
/// bridge before calling — see the crate-level comment above.
///
/// Lock uses confined-follow mode (`isCursorFollowMovement=true`, cursor keeps
/// moving within the window area — matches Windows ClipCursor semantics). The
/// lock only takes effect while the window is focused; the system releases it
/// automatically on focus loss. Unlock restores free cursor movement.
///
/// Pure FFI — safe from any thread (no NAPI env access). Returns a typed error
/// (explicit `std::result::Result`) so tao can map `NotSupported` vs OS errors
/// without string matching.
pub fn set_cursor_grab(
    real_window_id: i32,
    grab: bool,
) -> std::result::Result<(), CursorGrabError> {
    if real_window_id <= 0 {
        return Err(CursorGrabError::Bridge(format!(
            "invalid real window id {real_window_id}"
        )));
    }
    let api = cursor_lock_api().ok_or(CursorGrabError::NotSupported)?;
    let code = if grab {
        unsafe { (api.lock_cursor)(real_window_id, true) }
    } else {
        unsafe { (api.unlock_cursor)(real_window_id) }
    };
    match code {
        0 => Ok(()),
        // Unlock is idempotent: the system auto-releases the lock on focus
        // loss, so unlocking an already-unlocked window returns STATE_ABNORMAL
        // (1300002). Treat that as success — matches Windows, where clearing
        // the ClipCursor flag when not grabbed succeeds silently.
        WM_ERRORCODE_STATE_ABNORMAL if !grab => Ok(()),
        WM_ERRORCODE_DEVICE_NOT_SUPPORTED => Err(CursorGrabError::NotSupported),
        other => Err(CursorGrabError::OsCode(other)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_covers_all_variants() {
        assert_eq!(
            CursorGrabError::OsCode(1300002).to_string(),
            "window manager error code 1300002"
        );
        assert_eq!(
            CursorGrabError::Bridge("lookup failed".into()).to_string(),
            "cursor grab bridge failure: lookup failed"
        );
        // On OHOS this may carry a resolver reason suffix; on host it is the
        // bare message.
        let not_supported = CursorGrabError::NotSupported.to_string();
        assert!(
            not_supported.starts_with("cursor lock not supported on this device"),
            "unexpected NotSupported message: {not_supported}"
        );
    }

    #[test]
    fn invalid_window_id_is_a_bridge_error() {
        assert!(matches!(
            set_cursor_grab(0, true),
            Err(CursorGrabError::Bridge(_))
        ));
        assert!(matches!(
            set_cursor_grab(-3, false),
            Err(CursorGrabError::Bridge(_))
        ));
    }

    #[cfg(not(target_env = "ohos"))]
    #[test]
    fn host_reports_not_supported() {
        assert!(matches!(
            set_cursor_grab(1, true),
            Err(CursorGrabError::NotSupported)
        ));
    }
}
