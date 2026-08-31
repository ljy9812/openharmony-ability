use std::{cell::RefCell, rc::Rc};

use napi_ohos::{bindgen_prelude::ObjectRef, Env};

thread_local! {
    static MAIN_THREAD_ENV: Rc<RefCell<Option<Env>>> = Rc::new(RefCell::new(None));
}

/// Wrapper for storing the helper `ObjectRef` in a static `Mutex`.
///
/// `ObjectRef` is `Send` (but not `Clone` or `Sync`). `ObjectRef::drop` does
/// not free the underlying `napi_ref` — it only prints a leak-check warning.
/// The reference is intentionally never unref'd, as it lives for the duration
/// of the JS VM which outlives all Rust code.
///
/// `SendableHelper` is automatically `Send` (via `ObjectRef: Send`).
/// `Mutex<SendableHelper>` is `Sync` when `SendableHelper: Send` — no manual
/// `unsafe impl` required.
pub struct SendableHelper(Option<ObjectRef>);

impl SendableHelper {
    pub fn helper(&self) -> Option<&ObjectRef> {
        self.0.as_ref()
    }
}

static GLOBAL_HELPER: std::sync::Mutex<SendableHelper> =
    std::sync::Mutex::new(SendableHelper(None));

/// Set the HELPER value
pub fn set_helper(helper: ObjectRef) {
    *GLOBAL_HELPER.lock().unwrap() = SendableHelper(Some(helper));
}

/// Returns a guard providing access to the helper `ObjectRef`.
///
/// The guard holds the `GLOBAL_HELPER` lock, ensuring exclusive access.
/// All callers run on the main thread (NAPI callbacks), so contention is nil.
pub fn get_helper() -> std::sync::MutexGuard<'static, SendableHelper> {
    GLOBAL_HELPER.lock().unwrap()
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
