use std::cell::RefCell;
use std::os::raw::c_void;
use std::rc::Rc;

use napi_ohos::Result;
use ohos_xcomponent_binding::{MouseButton, WindowRaw, XComponentRaw};
use ohos_xcomponent_sys::{
    OH_NativeXComponent, OH_NativeXComponent_GetMouseEvent, OH_NativeXComponent_MouseEvent,
    OH_NativeXComponent_MouseEvent_Callback, OH_NativeXComponent_RegisterMouseEventCallback,
    OH_NativeXComponent_RegisterUIInputEventCallback,
    OH_ArkUI_AxisEvent_GetVerticalAxisValue, OH_ArkUI_AxisEvent_GetHorizontalAxisValue,
    OH_ArkUI_AxisEvent_GetPinchAxisScaleValue, OH_ArkUI_UIInputEvent_GetSourceType,
};

/// ArkUI input event type for axis (scroll) events.
const ARKUI_UIINPUTEVENT_TYPE_AXIS: u32 = 2;

/// Input source types from OHOS NDK.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputSourceType {
    Unknown,
    Mouse,
    TouchScreen,
    Touchpad,
    Joystick,
    Keyboard,
}

impl From<i32> for InputSourceType {
    fn from(value: i32) -> Self {
        match value {
            1 => InputSourceType::Mouse,
            2 => InputSourceType::TouchScreen,
            3 => InputSourceType::Touchpad,
            4 => InputSourceType::Joystick,
            5 => InputSourceType::Keyboard,
            _ => InputSourceType::Unknown,
        }
    }
}

/// Mouse action types for OHOS mouse events.
///
/// Maps to `OH_NativeXComponent_MouseEventAction` from the NDK, with additional
/// hover variants synthesized from `DispatchHoverEvent` callbacks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseAction {
    None,
    Press,
    Release,
    Move,
    /// Synthesized from DispatchHoverEvent(isHover=true)
    HoverEnter,
    /// Synthesized from DispatchHoverEvent(isHover=false)
    HoverLeave,
}

impl From<u32> for MouseAction {
    fn from(value: u32) -> Self {
        match value {
            0 => MouseAction::None,
            1 => MouseAction::Press,
            2 => MouseAction::Release,
            3 => MouseAction::Move,
            _ => MouseAction::None,
        }
    }
}

/// Safe Rust wrapper around `OH_NativeXComponent_MouseEvent` FFI struct.
///
/// Also carries hover events synthesized from `DispatchHoverEvent`.
#[derive(Debug, Clone)]
pub struct MouseEventData {
    pub x: f32,
    pub y: f32,
    pub screen_x: f32,
    pub screen_y: f32,
    pub timestamp: i64,
    pub action: MouseAction,
    pub button: MouseButton,
}

impl Default for MouseEventData {
    fn default() -> Self {
        Self {
            x: 0.0,
            y: 0.0,
            screen_x: 0.0,
            screen_y: 0.0,
            timestamp: 0,
            action: MouseAction::None,
            button: MouseButton::NoneButton,
        }
    }
}

impl From<OH_NativeXComponent_MouseEvent> for MouseEventData {
    fn from(raw: OH_NativeXComponent_MouseEvent) -> Self {
        Self {
            x: raw.x,
            y: raw.y,
            screen_x: raw.screenX,
            screen_y: raw.screenY,
            timestamp: raw.timestamp,
            action: MouseAction::from(raw.action),
            button: MouseButton::from(raw.button),
        }
    }
}

impl MouseEventData {
    /// Create a hover event (enter or leave) from DispatchHoverEvent callback.
    ///
    /// Hover events from the NDK don't carry position data, so x/y are zeroed.
    pub fn hover(is_hover: bool) -> Self {
        Self {
            action: if is_hover {
                MouseAction::HoverEnter
            } else {
                MouseAction::HoverLeave
            },
            ..Default::default()
        }
    }
}

// ─── Callback storage & registration ─────────────────────────────────────────

pub type OnMouseEvent =
    Option<Rc<dyn Fn(XComponentRaw, WindowRaw, MouseEventData) -> Result<()>>>;

thread_local! {
    static MOUSE_EVENT_CALLBACK: RefCell<OnMouseEvent> = const { RefCell::new(None) };
}

/// Register a mouse event callback. The closure will be invoked whenever the
/// NDK fires `DispatchMouseEvent` or `DispatchHoverEvent`.
pub fn set_mouse_event_callback<F>(cb: F)
where
    F: Fn(XComponentRaw, WindowRaw, MouseEventData) -> Result<()> + 'static,
{
    MOUSE_EVENT_CALLBACK.with_borrow_mut(|f| {
        *f = Some(Rc::new(cb));
    });
}

/// Native callback invoked by the OHOS NDK for mouse events.
///
/// # Safety
/// Called by the OHOS runtime. `component` and `window` must be valid pointers.
pub unsafe extern "C" fn dispatch_mouse_event(
    component: *mut OH_NativeXComponent,
    window: *mut c_void,
) {
    let mut raw_event = std::mem::MaybeUninit::<OH_NativeXComponent_MouseEvent>::uninit();
    let ret = OH_NativeXComponent_GetMouseEvent(component, window, raw_event.as_mut_ptr());
    if ret != 0 {
        return;
    }

    let data = MouseEventData::from(raw_event.assume_init());
    let xcomponent = XComponentRaw(component);
    let win = WindowRaw(window);

    MOUSE_EVENT_CALLBACK.with_borrow(|f| {
        if let Some(cb) = f {
            let _ = cb(xcomponent, win, data);
        }
    });
}

/// Native callback invoked by the OHOS NDK for hover (mouse enter/leave) events.
///
/// # Safety
/// Called by the OHOS runtime. `component` must be a valid pointer.
pub unsafe extern "C" fn dispatch_hover_event(
    component: *mut OH_NativeXComponent,
    is_hover: bool,
) {
    let data = MouseEventData::hover(is_hover);
    let xcomponent = XComponentRaw(component);
    // DispatchHoverEvent has no window param; pass null.
    let win = WindowRaw(std::ptr::null_mut());

    MOUSE_EVENT_CALLBACK.with_borrow(|f| {
        if let Some(cb) = f {
            let _ = cb(xcomponent, win, data);
        }
    });
}

/// Register the mouse + hover + axis callbacks with the OHOS NDK.
///
/// # Safety
/// `xcomponent_raw` must be a valid `*mut OH_NativeXComponent`.
pub unsafe fn register_mouse_callbacks(xcomponent_raw: *mut OH_NativeXComponent) -> Result<()> {
    let mut cbs = Box::new(OH_NativeXComponent_MouseEvent_Callback {
        DispatchMouseEvent: Some(dispatch_mouse_event),
        DispatchHoverEvent: Some(dispatch_hover_event),
    });
    let ret = OH_NativeXComponent_RegisterMouseEventCallback(
        xcomponent_raw,
        &mut *cbs as *mut _,
    );
    // Leak the box so the function pointers remain valid for the lifetime of the app.
    std::mem::forget(cbs);
    if ret != 0 {
        return Err(napi_ohos::Error::from_reason(
            "XComponent register mouse event callback failed",
        ));
    }

    // Register axis (scroll wheel) callback via ArkUI UIInputEvent API.
    let ret = OH_NativeXComponent_RegisterUIInputEventCallback(
        xcomponent_raw,
        Some(dispatch_axis_event),
        ARKUI_UIINPUTEVENT_TYPE_AXIS,
    );
    if ret != 0 {
        // Axis callback registration failure is non-fatal (older devices may not support it).
        #[cfg(feature = "log")]
        log::warn!("Failed to register axis event callback (ret={}), scroll wheel may not work", ret);
    }

    Ok(())
}

// ─── Axis (scroll wheel) event support ────────────────────────────────────────

/// Scroll axis event data extracted from ArkUI axis events.
///
/// Carries scroll deltas, pinch scale, and the input source type
/// (mouse vs touchpad) so that consumers can differentiate behavior.
#[derive(Debug, Clone)]
pub struct AxisEventData {
    /// Horizontal scroll delta (positive = scroll right).
    pub delta_x: f32,
    /// Vertical scroll delta (positive = scroll down).
    pub delta_y: f32,
    /// Pinch scale factor from two-finger pinch on touchpad.
    /// 1.0 = no change, >1.0 = zoom in, <1.0 = zoom out.
    /// 0.0 = no pinch data in this event.
    pub pinch_scale: f32,
    /// Source of the input event (mouse, touchpad, touchscreen, etc.).
    pub source_type: InputSourceType,
    /// Event timestamp in nanoseconds.
    pub timestamp: i64,
}

impl Default for AxisEventData {
    fn default() -> Self {
        Self {
            delta_x: 0.0,
            delta_y: 0.0,
            pinch_scale: 0.0,
            source_type: InputSourceType::Unknown,
            timestamp: 0,
        }
    }
}

pub type OnAxisEvent = Option<Rc<dyn Fn(AxisEventData) -> Result<()>>>;

thread_local! {
    static AXIS_EVENT_CALLBACK: RefCell<OnAxisEvent> = const { RefCell::new(None) };
}

/// Register a callback for axis (scroll wheel) events.
pub fn set_axis_event_callback<F>(cb: F)
where
    F: Fn(AxisEventData) -> Result<()> + 'static,
{
    AXIS_EVENT_CALLBACK.with_borrow_mut(|f| {
        *f = Some(Rc::new(cb));
    });
}

/// Native callback invoked by the OHOS ArkUI runtime for axis (scroll) events.
///
/// Extracts scroll deltas, pinch scale, and input source type from the event.
///
/// # Safety
/// Called by the OHOS runtime. `component` and `event` must be valid pointers.
pub unsafe extern "C" fn dispatch_axis_event(
    _component: *mut OH_NativeXComponent,
    event: *mut ohos_arkui_sys::ArkUI_UIInputEvent,
    _type: u32,
) {
    if event.is_null() {
        return;
    }

    let delta_y = OH_ArkUI_AxisEvent_GetVerticalAxisValue(event as *const _) as f32;
    let delta_x = OH_ArkUI_AxisEvent_GetHorizontalAxisValue(event as *const _) as f32;
    let pinch_scale = OH_ArkUI_AxisEvent_GetPinchAxisScaleValue(event as *const _) as f32;
    let source_type = InputSourceType::from(OH_ArkUI_UIInputEvent_GetSourceType(event as *const _));

    // Skip events with no scroll delta and no pinch data.
    if delta_x == 0.0 && delta_y == 0.0 && pinch_scale == 0.0 {
        return;
    }

    let data = AxisEventData {
        delta_x,
        delta_y,
        pinch_scale,
        source_type,
        timestamp: 0,
    };

    AXIS_EVENT_CALLBACK.with_borrow(|f| {
        if let Some(cb) = f {
            let _ = cb(data);
        }
    });
}
