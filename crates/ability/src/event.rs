use std::fmt::{self, Debug, Formatter};

use crate::{
    AvoidAreaInfo, Configuration, ContentRect, InputEvent, IntervalInfo, SaveLoader, SaveSaver,
    Size,
};

#[derive(Clone)]
pub enum Event<'a> {
    /// window stage create event
    /// alias onWindowStageCreate
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonwindowstagecreate
    WindowCreate,
    /// window stage destroy event
    /// alias onWindowStageDestroy
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonwindowstagedestroy
    ///
    /// `window_id` is the UIAbility instance whose stage is being torn down
    /// (0 = primary). Phase 4 (design.md D5): every instance's destroy
    /// dispatches with its own id so tao routes CloseRequested/Destroyed to
    /// that window instead of the primary.
    WindowDestroy { window_id: i64 },

    /// Per-frame redraw tick from the XComponent frame callback.
    /// `window_id` is the window owning that render surface (0 = primary —
    /// spawned UIAbility windows mount no XComponent, Phase 4 design.md D5).
    WindowRedraw { window_id: i64, info: IntervalInfo },
    /// window resize event
    /// alias window.on("windowSizeChange")
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowsizechange7
    ///
    /// `window_id` is the OHOS window this resize originated from (0 = main,
    /// >0 = Float sub-window). Populated by the window_resize lifecycle closure
    /// from the `windowId` field ArkTS wraps into the options (design.md D2/D6).
    /// Phase 3: tao's run_loop routes the event by this id.
    WindowResize {
        window_id: i64,
        size: Size,
    },
    /// window rect change event
    /// alias window.on("windowRectChange")
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowrectchange12
    ContentRectChange(ContentRect),
    /// window avoid area change event
    /// alias window.on("avoidAreaChange")
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window-window#onavoidareachange9
    AvoidAreaChange(AvoidAreaInfo),

    /// window configuration changed
    /// alias onWindowConfigurationChanged
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-environmentcallback-V5#environmentcallbackonconfigurationupdated
    ConfigChanged(Configuration),
    /// low memory event
    /// alias onMemoryLevel
    /// it will execute when system memory is low(MEMORY_LEVEL_CRITICAL)
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-environmentcallback-V5#environmentcallbackonmemorylevel
    LowMemory,

    /// WindowStateEventChanged
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowstageevent9
    /// window show
    /// alias WindowStageEventType.SHOWN
    Start,
    /// window stage focus event
    /// alias WindowStageEventType.ACTIVE
    ///
    /// `window_id` is the UIAbility instance that gained focus (0 = primary).
    /// Phase 4 (design.md D5): focus dispatches per-window — when a spawned
    /// instance gains focus the primary receives the matching `LostFocus`
    /// half of the pair.
    GainedFocus { window_id: i64 },
    /// window stage unfocus event
    /// alias WindowStageEventType.INAVTIVE
    /// `window_id` semantics mirror `GainedFocus`.
    LostFocus { window_id: i64 },
    /// window resume
    /// alias WindowStageEventType.RESUMED
    Resume(SaveLoader<'a>),
    /// window pause
    /// alias WindowStageEventType.PAUSED
    Pause,
    /// window stop
    /// alias WindowStageEventType.HIDDEN
    Stop,

    /// ability save state event
    /// alias onAbilitySaveState
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitysavestate12
    SaveState(SaveSaver<'a>),
    /// ability create event
    /// alias onAbilityCreate
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitycreate
    Create,
    /// ability destroy event
    /// alias onAbilityDestroy
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitydestroy
    Destroy,

    /// surface create event
    /// alias onSurfaceCreated for XComponent
    /// We can render EGL/OpenGL in this event
    SurfaceCreate,
    /// surface destroy event
    /// alias onSurfaceDestroyed for XComponent
    SurfaceDestroy,
    /// surface input event
    /// IME
    /// `window_id` is the window whose render surface produced the input
    /// (0 = primary; populated from `render()`'s `window_id` param — Phase 4
    /// design.md D5).
    Input { window_id: i64, input: InputEvent },

    /// keyboard event
    /// alias onKeyboardHeightChange
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window-window#onkeyboardheightchange7
    KeyboardEvent(i32),

    /// ability new want event (deep link / URL scheme)
    /// alias onNewWant
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-uiAbility-V5#uiabilityonnewwant
    NewWant {
        uri: String,
    },

    UserEvent,
}

impl<'a> Event<'a> {
    pub fn as_str(&self) -> &'static str {
        match self {
            Event::WindowCreate => "WindowCreate",
            Event::WindowDestroy { .. } => "WindowDestroy",
            Event::WindowRedraw { .. } => "WindowRedraw",
            Event::WindowResize { .. } => "WindowResize",
            Event::ContentRectChange(_) => "ContentRectChange",
            Event::AvoidAreaChange(_) => "AvoidAreaChange",
            Event::ConfigChanged(_) => "ConfigChanged",
            Event::LowMemory => "LowMemory",
            Event::Start => "Start",
            Event::GainedFocus { .. } => "GainedFocus",
            Event::LostFocus { .. } => "LostFocus",
            Event::Resume(_) => "Resume",
            Event::Pause => "Pause",
            Event::Stop => "Stop",
            Event::SaveState(_) => "SaveState",
            Event::Create => "Create",
            Event::Destroy => "Destroy",
            Event::SurfaceCreate => "SurfaceCreate",
            Event::SurfaceDestroy => "SurfaceDestroy",
            Event::Input { .. } => "Input",
            Event::UserEvent => "UserEvent",
            Event::KeyboardEvent(_) => "KeyboardEvent",
            Event::NewWant { .. } => "NewWant",
        }
    }
}

impl<'a> Debug for Event<'a> {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}
