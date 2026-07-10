import { inputConsumer } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from "@kit.BasicServicesKit";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from './constants';

// ─── Key code mapping ───────────────────────────────────────────────────────

/**
 * Maps modifier names (from Rust) to OHOS KeyCode constants.
 * OHOS inputConsumer.preKeys expects numeric key codes.
 */
const MODIFIER_MAP: Map<string, number> = new Map([
  ['Ctrl', 2072],    // KEYCODE_CTRL_LEFT
  ['Shift', 2047],   // KEYCODE_SHIFT_LEFT
  ['Alt', 2045],     // KEYCODE_ALT_LEFT
  ['Meta', 2076],    // KEYCODE_META_LEFT
]);

/**
 * Maps key names (from Rust) to OHOS KeyCode constants.
 * Covers letters A-Z, digits 0-9, function keys F1-F24, and common special keys.
 */
const KEY_MAP: Map<string, number> = new Map([
  // Letters: KEYCODE_A (2017) through KEYCODE_Z (2042)
  ['A', 2017], ['B', 2018], ['C', 2019], ['D', 2020],
  ['E', 2021], ['F', 2022], ['G', 2023], ['H', 2024],
  ['I', 2025], ['J', 2026], ['K', 2027], ['L', 2028],
  ['M', 2029], ['N', 2030], ['O', 2031], ['P', 2032],
  ['Q', 2033], ['R', 2034], ['S', 2035], ['T', 2036],
  ['U', 2037], ['V', 2038], ['W', 2039], ['X', 2040],
  ['Y', 2041], ['Z', 2042],
  // Digits: KEYCODE_0 (2000) through KEYCODE_9 (2009)
  ['0', 2000], ['1', 2001], ['2', 2002], ['3', 2003], ['4', 2004],
  ['5', 2005], ['6', 2006], ['7', 2007], ['8', 2008], ['9', 2009],
  // Function keys (from SDK d.ts)
  ['F1', 2090], ['F2', 2091], ['F3', 2092], ['F4', 2093],
  ['F5', 2094], ['F6', 2095], ['F7', 2096], ['F8', 2097],
  ['F9', 2098], ['F10', 2099], ['F11', 2100], ['F12', 2101],
  // F13-F24
  ['F13', 2816], ['F14', 2817], ['F15', 2818], ['F16', 2819],
  ['F17', 2820], ['F18', 2821], ['F19', 2822], ['F20', 2823],
  ['F21', 2824], ['F22', 2825], ['F23', 2826], ['F24', 2827],
  // Special keys (from SDK d.ts)
  ['Space', 2050],     // KEYCODE_SPACE
  ['Enter', 2054],     // KEYCODE_ENTER
  ['Escape', 2070],    // KEYCODE_ESCAPE
  ['Tab', 2049],       // KEYCODE_TAB
  ['Backspace', 2055], // KEYCODE_DEL
  ['Delete', 2071],    // KEYCODE_FORWARD_DEL
  ['Insert', 2083],    // KEYCODE_INSERT
  ['Home', 1],         // KEYCODE_HOME = 1 per @ohos.multimodalInput.keyCode
  ['End', 2082],       // KEYCODE_MOVE_END
  ['PageUp', 2068],    // KEYCODE_PAGE_UP
  ['PageDown', 2069],  // KEYCODE_PAGE_DOWN
  ['ArrowUp', 2012],   // KEYCODE_DPAD_UP
  ['ArrowDown', 2013], // KEYCODE_DPAD_DOWN
  ['ArrowLeft', 2014], // KEYCODE_DPAD_LEFT
  ['ArrowRight', 2015],// KEYCODE_DPAD_RIGHT
]);

// ─── Registration tracking ──────────────────────────────────────────────────

interface RegisteredHotkey {
  options: inputConsumer.HotkeyOptions;
  callback: (hotkey: inputConsumer.HotkeyOptions) => void;
}

/**
 * All registered hotkeys, keyed by their shortcut ID.
 * Needed to call `inputConsumer.off()` with the exact same options and callback.
 */
const registeredHotkeys: Map<number, RegisteredHotkey> = new Map();

// ─── Get native module from AppStorage ────────────────────────────────────

function getNativeModule(): ESObject {
  return AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY);
}

// ─── Public API ─────────────────────────────────────────────────────────────

/**
 * Register a global shortcut via OHOS `inputConsumer`.
 *
 * @param id - Unique shortcut identifier (matches Rust-side ID)
 * @param modifiersCsv - Comma-separated modifier names, e.g. 'Ctrl,Shift'
 * @param key - Key name, e.g. "A", "F5", "Space"
 */
export const registerHotkey = (jsonStr: string): void => {
  let id: number = 0;
  try {
    const params = JSON.parse(jsonStr) as ESObject;
    id = params.id as number;
    const preKey1: number = params.preKey1 as number;
    const preKey2: number = params.preKey2 as number;
    const finalKey: number = params.finalKey as number;

    // Build preKeys array from individual key codes (0 means unused slot)
    const preKeys: number[] = [];
    if (preKey1 > 0) preKeys.push(preKey1);
    if (preKey2 > 0) preKeys.push(preKey2);

    if (preKeys.length === 0 || finalKey <= 0) {
      hilog.error(DOMAIN, 'GlobalShortcut', 'Invalid key codes in JSON: %{public}s', jsonStr);
      return;
    }

    // Build HotkeyOptions
    const hotkeyOptions: inputConsumer.HotkeyOptions = {
      preKeys: preKeys,
      finalKey: finalKey,
      isRepeat: false,
    };

    // Create callback that emits both Pressed and Released events
    const callback = (hotkey: inputConsumer.HotkeyOptions): void => {
      const nm = getNativeModule();
      if (nm && typeof nm.emitShortcutEvent === 'function') {
        nm.emitShortcutEvent(id, 'Pressed');
        nm.emitShortcutEvent(id, 'Released');
      } else {
        hilog.warn(DOMAIN, 'GlobalShortcut', 'Native module not available, cannot emit shortcut event for id=%{public}d', id);
      }
    };

    // Subscribe via inputConsumer
    inputConsumer.on('hotkeyChange', hotkeyOptions, callback);

    // Track for later unregistration
    registeredHotkeys.set(id, { options: hotkeyOptions, callback });

    hilog.info(DOMAIN, 'GlobalShortcut', 'Registered hotkey id=%{public}d', id);
  } catch (err) {
    const error = err as BusinessError;
    const code = error.code ?? -1;
    const msg = (error.message !== undefined && error.message !== null) ? error.message : String(err);
    if (code === 801) {
      hilog.info(DOMAIN, 'GlobalShortcut',
        'inputConsumer not supported on this device (error 801), skipping registration for id=%{public}d', id);
    } else if (code === 4200002) {
      hilog.warn(DOMAIN, 'GlobalShortcut',
        'Hotkey id=%{public}d is occupied by the system', id);
    } else if (code === 4200003) {
      hilog.warn(DOMAIN, 'GlobalShortcut',
        'Hotkey id=%{public}d is already subscribed by another app', id);
    } else {
      const detail = `Failed to register hotkey id=${id}, code=${code}, msg=${msg}`;
      hilog.error(DOMAIN, 'GlobalShortcut', '%{public}s', detail);
    }
  }
};

/**
 * Unregister a previously registered shortcut.
 *
 * @param id - The shortcut ID to unregister
 */
export const unregisterHotkey = (id: number): void => {
  const entry = registeredHotkeys.get(id);
  if (!entry) {
    hilog.info(DOMAIN, 'GlobalShortcut',
      'unregisterHotkey: id=%{public}d not found, skipping', id);
    return;
  }

  try {
    inputConsumer.off('hotkeyChange', entry.options, entry.callback);
    registeredHotkeys.delete(id);
    hilog.info(DOMAIN, 'GlobalShortcut', 'Unregistered hotkey id=%{public}d', id);
  } catch (err) {
    const error = err as BusinessError;
    hilog.error(DOMAIN, 'GlobalShortcut',
      'Failed to unregister hotkey id=%{public}d: code=%{public}d, message=%{public}s',
      id, error.code, error.message);
  }
};

/**
 * Unregister all shortcuts registered by this module.
 */
export const unregisterAllHotkeys = (): void => {
  const ids = Array.from(registeredHotkeys.keys());
  for (const id of ids) {
    unregisterHotkey(id);
  }
  hilog.info(DOMAIN, 'GlobalShortcut',
    'Unregistered all hotkeys (count=%{public}d)', ids.length);
};
