//! OHOS Menu module
//!
//! This module provides:
//! - NAPI API: notify_menubar_visibility() for ArkTS to sync visibility to Rust
//! - NAPI API: on_menu_request() for ArkTS to register menu callback (stub —
//!   routing now handled by MenuPlugin bridge plugin)
//! - State: MENUBAR_VISIBLE (per-window, updated by notify_menubar_visibility;
//!   the authoritative cache now lives in plugin-menu)
//! - Menu request: MenuRequestData (NAPI type for serialization)
//!
//! The legacy TSFN/channel-based transport (MENU_CHANNEL, MENU_CALLBACK,
//! start_menu_forwarder, set_menu_json, set_menubar_visible, is_menubar_visible,
//! popup_context_menu, menu_request_receiver, popup_request_receiver) has been
//! removed. Menu operations now route through the MenuClient facade
//! (openharmony-ability-plugin-menu crate) which calls the ArkTS MenuPlugin
//! bridge plugin directly.
//!
//! Pruned 2026-08-20 (dead-code cleanup): removed emit_menu_event (dead-sink
//! channel write; ArkTS now forwards menu events via the MenuPlugin bridge —
//! NativeAbility.ets emitMenuEventFn closure), on_popup_request / PopupRequestData
//! (zero callers), MenuRequest struct (zero users), and the state/popup/
//! predefined/types/event submodules (superseded by plugin-menu's own migrated
//! copies; zero importers).

use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use std::collections::HashMap;
use std::sync::LazyLock;
use std::sync::RwLock;

// Per-window menubar visibility state (default true for each window)
static MENUBAR_VISIBLE: LazyLock<RwLock<HashMap<String, bool>>> = LazyLock::new(|| RwLock::new(HashMap::new()));

/// Menu request data for NAPI (unified popup + menubar + visibility)
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[napi(object)]
pub struct MenuRequestData {
    pub json_data: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub visible: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_id: Option<String>,
}

/// NAPI API: Notify menubar visibility from ArkTS (sync per-window state to Rust)
#[napi]
pub fn notify_menubar_visibility(window_id: String, visible: bool) {
    let mut map = MENUBAR_VISIBLE.write().unwrap();
    map.insert(window_id, visible);
}

/// NAPI API: Register unified menu callback from ArkTS
///
/// Stub — menu request routing is now handled by the MenuPlugin bridge plugin
/// (ohos.menu actions: set-menubar, popup, set-menubar-visible, execute-predefined).
/// This function is retained for NAPI ABI compatibility but performs no work.
#[napi(ts_args_type = "callback: (data: MenuRequestData) => void")]
pub fn on_menu_request(callback: Function<'static>) -> Result<()> {
    let _ = callback;
    crate::debug!("[Menu] on_menu_request: stub — routing handled by MenuPlugin bridge");
    Ok(())
}

#[cfg(all(test, target_env = "ohos"))]
mod tests {
    use super::*;

    #[test]
    fn test_menu_request_data_serde() {
        let data = MenuRequestData {
            json_data: "test".to_string(),
            x: Some(50.0),
            y: Some(100.0),
            visible: None,
            window_id: Some("main".to_string()),
        };
        let json = serde_json::to_string(&data).unwrap();
        assert!(json.contains("\"x\":50.0"));
        assert!(json.contains("\"y\":100.0"));
        assert!(json.contains("\"window_id\":\"main\""));
        assert!(!json.contains("\"visible\":"));

        let data_no_coords = MenuRequestData {
            json_data: "test".to_string(),
            x: None,
            y: None,
            visible: None,
            window_id: None,
        };
        let json_no_coords = serde_json::to_string(&data_no_coords).unwrap();
        assert!(!json_no_coords.contains("\"x\":"));
        assert!(!json_no_coords.contains("\"y\":"));
        assert!(!json_no_coords.contains("\"visible\":"));
        assert!(!json_no_coords.contains("\"window_id\":"));
    }

    #[test]
    fn test_menu_request_data_visible_serde() {
        let data_visible = MenuRequestData {
            json_data: "".to_string(),
            x: None,
            y: None,
            visible: Some(true),
            window_id: Some("main".to_string()),
        };
        let json = serde_json::to_string(&data_visible).unwrap();
        assert!(json.contains("\"visible\":true"));
        assert!(json.contains("\"window_id\":\"main\""));

        let data_no_visible = MenuRequestData {
            json_data: "".to_string(),
            x: None,
            y: None,
            visible: None,
            window_id: Some("main".to_string()),
        };
        let json_no_visible = serde_json::to_string(&data_no_visible).unwrap();
        assert!(!json_no_visible.contains("\"visible\":"));
    }

    #[test]
    fn test_menu_request_data_full_roundtrip() {
        let original = MenuRequestData {
            json_data: "[{\"type\":\"submenu\"}]".to_string(),
            x: Some(200.0),
            y: Some(300.0),
            visible: Some(true),
            window_id: Some("main".to_string()),
        };
        let json = serde_json::to_string(&original).unwrap();
        let deserialized: MenuRequestData = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.json_data, original.json_data);
        assert_eq!(deserialized.x, original.x);
        assert_eq!(deserialized.y, original.y);
        assert_eq!(deserialized.visible, original.visible);
        assert_eq!(deserialized.window_id, original.window_id);
    }
}
