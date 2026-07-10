use std::{cell::RefCell, mem::ManuallyDrop, rc::Rc};

use napi_ohos::{bindgen_prelude::ObjectRef, Env};

mod autostart;
mod permission;
mod restart;
#[cfg(feature = "updater")]
mod updater;
#[cfg(feature = "webview")]
mod webview;
mod window_info;

pub use autostart::*;
pub use permission::*;
pub use restart::*;
#[cfg(feature = "updater")]
pub use updater::*;
#[cfg(feature = "webview")]
pub use webview::*;

thread_local! {
    static MAIN_THREAD_ENV: Rc<RefCell<Option<Env>>> = Rc::new(RefCell::new(None));
}

// Wrappers to make types Send+Sync for static storage
struct SendableHelper(Option<ObjectRef>);
unsafe impl Send for SendableHelper {}
unsafe impl Sync for SendableHelper {}

impl Drop for SendableHelper {
    fn drop(&mut self) {
        // Never drop ObjectRef to avoid napi_reference_unref being called
        // from non-main threads (e.g., during process exit or static cleanup).
        // The ObjectRef is tied to the JS VM lifetime which outlives all Rust code.
        if let Some(helper) = self.0.take() {
            std::mem::forget(helper);
        }
    }
}

static GLOBAL_HELPER: std::sync::Mutex<SendableHelper> =
    std::sync::Mutex::new(SendableHelper(None));

/// Set the HELPER value
pub fn set_helper(helper: ObjectRef) {
    *GLOBAL_HELPER.lock().unwrap() = SendableHelper(Some(helper));
}

/// # Safety
/// Returns a handle to the helper. Uses ptr::read to create a thread-local copy of the
/// ObjectRef (which wraps a raw napi_ref pointer). The copy is wrapped in ManuallyDrop
/// to prevent napi_reference_unref from being called on non-main threads when the
/// thread-local is destroyed (e.g., on tokio worker threads).
pub unsafe fn get_helper() -> Rc<RefCell<Option<ManuallyDrop<ObjectRef>>>> {
    thread_local! {
        static CACHED_HELPER: Rc<RefCell<Option<ManuallyDrop<ObjectRef>>>> = Rc::new(RefCell::new(None));
    }
    CACHED_HELPER.with(|rc| {
        if rc.borrow().is_none() {
            let guard = GLOBAL_HELPER.lock().unwrap();
            if let Some(ref helper) = guard.0 {
                // SAFETY: GLOBAL_HELPER is static-lifetime, the napi_ref is never freed,
                // so the bitwise copy is safe — the original is never dropped.
                // ManuallyDrop prevents Drop::drop (napi_reference_unref) from running
                // on non-main threads when this thread-local is destroyed.
                *rc.borrow_mut() = Some(ManuallyDrop::new(std::ptr::read(
                    helper as *const ObjectRef,
                )));
            }
        }
        Rc::clone(rc)
    })
}

pub fn set_main_thread_env(env: Env) {
    MAIN_THREAD_ENV.with(|rc| {
        *rc.borrow_mut() = Some(env);
    });
}

/// Get a handle to the main thread env.
/// Only returns Some when called from the main thread where set_main_thread_env was called.
pub fn get_main_thread_env() -> Rc<RefCell<Option<Env>>> {
    MAIN_THREAD_ENV.with(Rc::clone)
}
