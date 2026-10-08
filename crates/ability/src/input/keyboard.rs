use std::{
    ffi::c_void,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, OnceLock,
    },
};

use ohos_arkui_binding::arkui_input_binding::ArkUIInputEvent;
use ohos_arkui_sys::{
    OH_ArkUI_KeyEvent_GetKeyCode, OH_ArkUI_KeyEvent_GetKeySource, OH_ArkUI_KeyEvent_GetType,
    OH_ArkUI_KeyEvent_GetUnicode,
};
use ohos_xcomponent_binding::{Action, EventSource, KeyCode};

/// Selects one keyboard stream; the same physical key is never delivered twice.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum KeyboardInputDelivery {
    /// Raw XComponent key codes, available on older systems.
    #[default]
    RawXComponent,
    /// ArkUI keys not consumed by the IME, including Unicode and held-key state (API 14+).
    ArkUi,
}

/// An owned snapshot. Native input pointers never outlive their callback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyboardEventData {
    pub code: KeyCode,
    pub action: Action,
    pub device_id: i64,
    pub source: EventSource,
    pub timestamp: i64,
    /// System character, or zero when the SDK cannot translate this key.
    pub unicode: u32,
    /// `None` means the system query failed, rather than no keys being held.
    pub pressed_keys: Option<Vec<KeyCode>>,
    /// Lock queries are optional on systems before API 19.
    pub caps_lock: Option<bool>,
    pub num_lock: Option<bool>,
    /// Consume a post-IME key synchronously before its native callback returns.
    /// Late changes to this owned reply cannot affect a later native key.
    pub response: KeyboardEventResponse,
}

#[derive(Clone, Debug, Default)]
pub struct KeyboardEventResponse(Arc<AtomicBool>);

impl PartialEq for KeyboardEventResponse {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}
impl Eq for KeyboardEventResponse {}

impl KeyboardEventResponse {
    pub fn consume(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub(crate) fn is_consumed(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

type LockQuery = unsafe extern "C" fn(*const c_void, *mut bool) -> u32;

#[derive(Default)]
struct LockQueries {
    caps: Option<LockQuery>,
    num: Option<LockQuery>,
}

impl LockQueries {
    fn get() -> &'static Self {
        static QUERIES: OnceLock<LockQueries> = OnceLock::new();
        QUERIES.get_or_init(|| {
            // These symbols were added in API 19. Resolve them optionally so the
            // API 14 keyboard stream still works on older systems. libace remains
            // loaded for the lifetime of the node APIs used by this crate.
            let library = libloading::os::unix::Library::this();
            unsafe {
                Self {
                    caps: library
                        .get::<LockQuery>(b"OH_ArkUI_KeyEvent_IsCapsLockOn\0")
                        .ok()
                        .map(|symbol| *symbol),
                    num: library
                        .get::<LockQuery>(b"OH_ArkUI_KeyEvent_IsNumLockOn\0")
                        .ok()
                        .map(|symbol| *symbol),
                }
            }
        })
    }

    fn query(query: Option<LockQuery>, event: *const c_void) -> Option<bool> {
        let mut state = false;
        // SAFETY: called only while a validated key event is alive.
        (unsafe { query?(event, &mut state) } == 0).then_some(state)
    }
}

impl KeyboardEventData {
    // Only called by NODE_ON_KEY_EVENT. The generic event-type enum did not
    // expose Key until API 20, although this node callback exists since API 14.
    pub(crate) fn from_key_callback(event: &ArkUIInputEvent) -> Option<Self> {
        let raw = event.raw().cast();
        // SAFETY: the node's key callback owns this validated key event until it returns.
        let action = match unsafe { OH_ArkUI_KeyEvent_GetType(raw) } {
            0 => Action::Down,
            1 => Action::Up,
            // Long-press/click are semantic events, not additional key transitions.
            _ => return None,
        };
        let mut pressed = [0; 64];
        let mut pressed_keys = event.pressed_keys(&mut pressed).ok().and_then(|length| {
            pressed.get(..length).map(|codes| {
                codes
                    .iter()
                    .map(|code| KeyCode::from(*code as u32))
                    .collect::<Vec<_>>()
            })
        });
        let code = KeyCode::from(unsafe { OH_ArkUI_KeyEvent_GetKeyCode(raw) } as u32);
        if let Some(pressed) = pressed_keys.as_mut() {
            match action {
                Action::Up => pressed.retain(|pressed| *pressed != code),
                Action::Down if !pressed.contains(&code) => pressed.push(code),
                _ => {}
            }
        }
        let locks = LockQueries::get();
        Some(Self {
            code,
            action,
            device_id: event.device_id() as i64,
            source: EventSource::from(unsafe { OH_ArkUI_KeyEvent_GetKeySource(raw) }),
            timestamp: event.event_time(),
            unicode: unsafe { OH_ArkUI_KeyEvent_GetUnicode(raw) },
            pressed_keys,
            caps_lock: LockQueries::query(locks.caps, raw.cast()),
            num_lock: LockQueries::query(locks.num, raw.cast()),
            response: KeyboardEventResponse::default(),
        })
    }
}
