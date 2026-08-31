// Barrel for helper utilities still consumed via '../helper' imports.
// Pruned 2026-08-20: dead modules removed (autostart, global_shortcut,
// permission, updater, account, os, menu_state, ClipboardHelper,
// predefined — all had zero importers after the pluginize refactor).
// menu / menu_types / StatusBarUtils / accelerator_matcher / loadable /
// constants are imported directly and deliberately not re-exported here.
export * from "./random";
export * from "./object";
