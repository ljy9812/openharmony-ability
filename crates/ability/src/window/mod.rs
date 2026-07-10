use napi_ohos::bindgen_prelude::*;
use napi_ohos::threadsafe_function::{ThreadsafeCallContext, ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi_ohos::Env;
use crate::{get_helper, get_main_thread_env};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::OnceLock;

/// Global window ID generator to ensure unique IDs across Rust and ArkTS.
static NEXT_WINDOW_ID: AtomicI64 = AtomicI64::new(1);

/// Parameters for creating a new OS-level window on OpenHarmony.
///
/// `windowId` is not included — it is auto-generated internally by `create_os_window`
/// via `NEXT_WINDOW_ID` to ensure global uniqueness.
pub struct WindowCreateParams {
    /// Window label/name, used as the ArkTS sub-window name.
    pub name: String,
    /// OHOS window type enum value (0=App, 8=Float, etc.)
    pub window_type: i32,
    /// Initial window width in px. Default: 800.
    pub width: i32,
    /// Initial window height in px. Default: 600.
    pub height: i32,
    /// Initial window X position in px. Default: 100.
    pub x: i32,
    /// Initial window Y position in px. Default: 100.
    pub y: i32,
    /// Whether to show window decorations (title bar, drag area, close button).
    /// Phase 2: controls FloatPage conditional rendering via LocalStorage.
    pub decorations: bool,
    /// Whether the window background should be fully transparent.
    /// Phase 3: when true, overrides background_color with 0x00000000.
    pub transparent: bool,
    /// Window background color in 0xAARRGGBB format.
    /// Phase 3: ignored when transparent is true.
    pub background_color: Option<u32>,
}

impl Default for WindowCreateParams {
    fn default() -> Self {
        Self {
            name: String::new(),
            window_type: 0,
            width: 800,
            height: 600,
            x: 100,
            y: 100,
            decorations: true,
            transparent: false,
            background_color: None,
        }
    }
}

/// Generates a unique window ID for use when creating sub-windows
/// outside of `create_os_window` (e.g., from `handleWindowNew` when
/// `window_kind == "window"`). Uses the same `NEXT_WINDOW_ID` counter to
/// ensure no collision with Rust-created windows.
///
/// Currently unused — reserved for future when `OnWindowNewResult` carries
/// a pre-generated window ID for ArkTS-side sub-window creation.
#[allow(dead_code)]
pub fn generate_window_id() -> i64 {
    NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst)
}

/// Creates a new OS-level window on OpenHarmony.
///
/// Uses `WindowCreateParams` to pass all window attributes (geometry, decorations,
/// transparent, background_color) in a single struct, avoiding signature bloat
/// as Phase 2/3 add more parameters.
pub fn create_os_window(params: WindowCreateParams) -> napi_ohos::Result<i64> {
    // 1. Synchronously allocate a unique ID
    let id = NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst);
    crate::info!("Pre-allocated window ID: {}", id);

    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func =
                match obj.get_named_property::<Function<'_, Object, Unknown>>("createOSWindow") {
                    Ok(f) => f,
                    Err(e) => {
                        crate::error!("Property 'createOSWindow' NOT FOUND on helper: {:?}", e);
                        return Err(e);
                    }
                };

            crate::info!("Successfully found createOSWindow, building config object...");

            // 2. Create config object with all parameters
            let mut config = Object::new(env)?;
            config.set("name", params.name)?;
            // Note: "type" field is deprecated and no longer sent (OHOS createSubWindow only uses name)
            config.set("windowId", id)?;
            config.set("width", params.width)?;
            config.set("height", params.height)?;
            config.set("x", params.x)?;
            config.set("y", params.y)?;
            // Phase 2: decorations
            config.set("decorations", params.decorations)?;
            // Phase 3: transparent + backgroundColor
            config.set("transparent", params.transparent)?;
            if let Some(color) = params.background_color {
                config.set("backgroundColor", color)?;
            }

            crate::info!("Calling ArkTS with config object...");

            // 3. Call ArkTS and return the ID on success
            match func.call(config) {
                Ok(_) => {
                    crate::info!("ArkTS call succeeded, returning ID: {}", id);
                    return Ok(id);
                }
                Err(e) => {
                    crate::error!("ArkTS call failed: {:?}", e);
                    return Err(e);
                }
            }
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets window decorations (title bar visibility) at runtime via NAPI.
///
/// Calls ArkTS `setWindowDecorations(windowId, decorations)` handler which
/// updates LocalStorage → FloatPage `@LocalStorageProp` reactive re-render.
///
/// Phase 2 implementation.
pub fn set_window_decorations(window_id: i64, decorations: bool) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func =
                obj.get_named_property::<Function<'_, (i64, bool), ()>>("setWindowDecorations")?;
            func.call((window_id, decorations))?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets window background color at runtime via NAPI.
///
/// Calls ArkTS `setWindowBackgroundColor(windowId, color)` handler which
/// calls OHOS `window.Window.setWindowBackgroundColor('#AARRGGBB')`.
///
/// `color` is in `0xAARRGGBB` format (e.g., `0x00000000` = fully transparent).
///
/// Phase 3 implementation.

// ─── TSFN for cross-thread vibrancy calls (threadsafe, no main-thread Env needed) ───
// Fire-and-forget (NonBlocking, no return value wait): applyWindowBlur queues pendingBlurs
// (build-time inject via registerController) or calls setAllWebviewsBlurRadius (runtime
// modifier refresh), both idempotent, so no synchronous result needed.
type SetWindowBlurTsfn = ThreadsafeFunction<(i64, f64), (), FnArgs<(i64, f64)>, Status, false>;
type SetWindowBgColorTsfn = ThreadsafeFunction<(i64, u32), (), FnArgs<(i64, u32)>, Status, false>;

static TSFN_SET_WINDOW_BLUR: OnceLock<SetWindowBlurTsfn> = OnceLock::new();
static TSFN_SET_WINDOW_BG_COLOR: OnceLock<SetWindowBgColorTsfn> = OnceLock::new();

/// Initialize vibrancy ThreadsafeFunctions. Must be called on ArkTS main thread (during
/// ArkHelper setup, like init_clipboard_tsfn). After init, set_window_blur /
/// set_window_background_color are callable from any thread (TSFN is threadsafe, does not
/// need the thread_local MAIN_THREAD_ENV, so no run_on_main_thread required).
pub fn init_vibrancy_tsfn(env: &Env) -> Result<()> {
    if TSFN_SET_WINDOW_BLUR.get().is_some() {
        return Ok(());
    }
    let helper_obj = {
        let helper_rc = unsafe { get_helper() };
        let helper_guard = helper_rc.borrow();
        let helper_ref = helper_guard
            .as_ref()
            .ok_or_else(|| Error::from_reason("ArkHelper not initialized"))?;
        helper_ref.get_value(env)?
    };

    let blur_fn: Function<'_, FnArgs<(i64, f64)>, ()> = helper_obj
        .get_named_property("setWindowBlur")
        .map_err(|e| Error::from_reason(format!("setWindowBlur not found: {}", e)))?;
    let blur_tsfn = blur_fn
        .build_threadsafe_function::<(i64, f64)>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<(i64, f64)>| {
            Ok(FnArgs { data: ctx.value })
        })?;
    let _ = TSFN_SET_WINDOW_BLUR.set(blur_tsfn);

    let bg_fn: Function<'_, FnArgs<(i64, u32)>, ()> = helper_obj
        .get_named_property("setWindowBackgroundColor")
        .map_err(|e| Error::from_reason(format!("setWindowBackgroundColor not found: {}", e)))?;
    let bg_tsfn = bg_fn
        .build_threadsafe_function::<(i64, u32)>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<(i64, u32)>| {
            Ok(FnArgs { data: ctx.value })
        })?;
    let _ = TSFN_SET_WINDOW_BG_COLOR.set(bg_tsfn);

    Ok(())
}

/// Sets window background color via TSFN (threadsafe, callable from any thread).
pub fn set_window_background_color(window_id: i64, color: u32) -> napi_ohos::Result<()> {
    let tsfn = TSFN_SET_WINDOW_BG_COLOR.get()
        .ok_or_else(|| Error::from_reason("set_window_background_color TSFN not initialized"))?;
    let status = tsfn.call((window_id, color), ThreadsafeFunctionCallMode::NonBlocking);
    if status != Status::Ok {
        return Err(Error::from_reason(format!("TSFN call failed: {:?}", status)));
    }
    Ok(())
}

/// Sets window blur radius via TSFN (threadsafe, callable from any thread).
///
/// Calls ArkTS `setWindowBlur(windowId, radius)` handler which applies
/// `backdropBlur(radius)` to the WebView container component.
///
/// `radius` is the blur radius in pixels (0 = no blur).
pub fn set_window_blur(window_id: i64, radius: f64) -> napi_ohos::Result<()> {
    let tsfn = TSFN_SET_WINDOW_BLUR.get()
        .ok_or_else(|| Error::from_reason("set_window_blur TSFN not initialized"))?;
    let status = tsfn.call((window_id, radius), ThreadsafeFunctionCallMode::NonBlocking);
    if status != Status::Ok {
        return Err(Error::from_reason(format!("TSFN call failed: {:?}", status)));
    }
    Ok(())
}

/// Brings a Float sub-window to the front and focuses it.
///
/// Calls ArkTS `focusWindow(windowId)` which calls OHOS `window.Window.raiseToAppTop()`.
/// Requires OHOS API 14+.
///
/// **Note**: This is a fire-and-forget call — the ArkTS `raiseToAppTop()` is async,
/// but this function returns `Ok(())` synchronously after dispatching the NAPI call.
/// If the ArkTS side fails, the error is logged via `hilog` but not propagated to Rust.
/// For the main window (windowId = 0), this is a no-op (focus is OS-managed).
pub fn focus_window(window_id: i64) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func = obj.get_named_property::<Function<'_, i64, ()>>("focusWindow")?;
            func.call(window_id)?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}

/// Sets whether a Float sub-window can receive focus.
///
/// Calls ArkTS `setWindowFocusable(windowId, focusable)` which calls
/// OHOS `window.Window.setWindowFocusable(isFocusable)`.
pub fn set_window_focusable(window_id: i64, focusable: bool) -> napi_ohos::Result<()> {
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                crate::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func =
                obj.get_named_property::<Function<'_, (i64, bool), ()>>("setWindowFocusable")?;
            func.call((window_id, focusable))?;
            return Ok(());
        } else {
            crate::error!("Main thread env not available");
        }
    } else {
        crate::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}
