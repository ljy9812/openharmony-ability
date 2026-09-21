// @ohos-rs/ability-support — support HAR for @ohos-rs/ability.
//
// Home of the plugin-facing implementation tree that used to live inside the
// @ohos-rs/ability package: window management (WindowManager, sub-window
// registry), menu/statusbar helpers, key synthesis, and the UI components
// (DefaultXComponent, MainPage, FloatPage, MenuBarComponent). The bridge
// contract (plugin base classes, contexts, lifecycle payloads, Module) stays
// in @ohos-rs/ability; this package holds only the implementation code those
// contracts drive, and it never imports back into the core package (the two
// callbacks the support tree used to make into BridgeHost go through the
// NativeBridgePort installed by the core at startup).
