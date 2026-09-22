/**
 * Core-side extension seam for the menu plugin.
 *
 * rs<->ets correspondence: `crates/plugin-menu` (Rust facade) ↔ `plugins/menu`
 * (ArkTS har). The menu UI cluster (MenuBarComponent / MenuPopup / menu.ets /
 * menu_types / accelerator matcher) lives in the menu package; core pages never
 * import it. Instead they compose the menubar through a registered builder
 * slot, and forward pre-IME key events plus fullscreen-driven visibility
 * notifications to a registered port:
 *
 *   - MainPage / FloatPage render `getMenuBarSlotBuilder()` above their
 *     content (FloatPage keeps its desktop+decorations gating).
 *   - Their onKeyPreIme menu branches (clipboard / zoom flag blocking,
 *     accelerator dispatch, ESC fullscreen recover) delegate to
 *     `getMenuBarPort().onKeyPreIme`.
 *   - WindowManager.setFullscreen and NativeAbility's windowRectChange(RECOVER)
 *     notify the port instead of pulling MenuDataCallback from the menu package.
 *
 * The menu plugin registers both at `onInstall`, which runs during bridge
 * session setup — before any page content loads — so every page sees a live
 * slot. When no menu plugin is installed the slot is empty and every port
 * lookup returns null: core degrades to a menu-less window with native
 * clipboard / zoom behavior intact.
 *
 * `wrapBuilder` / `WrappedBuilder` are ambient ArkUI declarations (global UI
 * functions), so no kit import is needed here.
 */

/** Props passed to the registered menubar builder. */
export interface MenuBarSlotProps {
  windowId: number;
}

/** Menubar builder slot. Registered by the menu plugin at install time. */
export type MenuBarSlotBuilder = WrappedBuilder<[MenuBarSlotProps]>;

/**
 * Core → menu-plugin notification port. The menu plugin registers one
 * implementation; core calls it on key and fullscreen-visibility events.
 */
export interface MenuBarPort {
  /**
   * Pre-IME key handling (KeyDown only): clipboard / zoom shortcut blocking per
   * window flags, accelerator dispatch, ESC fullscreen recover. Returns true
   * when the event was consumed and must not reach the webview.
   */
  onKeyPreIme: (event: KeyEvent, windowId: number) => boolean;
  /** Menubar visibility changed for this window (fullscreen toggle, RECOVER). */
  onMenubarVisibility: (windowId: number, visible: boolean) => void;
  /** Popup open state changed for this window (close popups on fullscreen entry). */
  onMenuShown: (windowId: number, shown: boolean) => void;
}

let menuBarSlotBuilder: MenuBarSlotBuilder | null = null;
let menuBarPort: MenuBarPort | null = null;

export function setMenuBarSlotBuilder(builder: MenuBarSlotBuilder): void {
  menuBarSlotBuilder = builder;
}

export function getMenuBarSlotBuilder(): MenuBarSlotBuilder | null {
  return menuBarSlotBuilder;
}

export function setMenuBarPort(port: MenuBarPort): void {
  menuBarPort = port;
}

export function getMenuBarPort(): MenuBarPort | null {
  return menuBarPort;
}
