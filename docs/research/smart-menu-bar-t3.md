# Smart menu-bar geometry and event probes

T3 remains incomplete. This report records source inspection and experiments on 2026-11-01. No product code, host preference, host bar property, or AeroSpace configuration changed.

## Environment and isolation

Tart guest `mac_jr` was already running. It runs macOS 27.0 build 26A428 with SketchyBar 2.24.0 at `/opt/homebrew/bin/sketchybar`. The `/usr/local/bin/sketchybar` symlink points at a missing older build, so probes use the explicit Homebrew path.

The guest initially had one 1276 by 900 display and no running SketchyBar. Each shell probe refuses a non-VirtualMac model or an existing SketchyBar process. It starts a temporary bar with a separate configuration and kills only that process on exit. Temporary configurations and logs remain in the guest for inspection. The guest remains running because it was running before the probes.

The event probe copies the installed DeskPad 1.3.2 application into `/Users/admin/stm-deskpad.NGlula`, not `/Applications`. It refuses an existing DeskPad process and stops its own app after each display test. No screen-recording permission was granted or changed. The virtual display existed without a permission change.

Neither menu preference key was present before the probes. These probes do not write either key. The guest's native menu remained visible with a 30-point menu window at y=0 on the primary display.

## Built-in clearance depends on topmost

The exact tested release explains the initial offset:

- [`bar_get_frame()` in bar.c](https://github.com/FelixKratz/SketchyBar/blob/v2.24.0/src/bar.c) adds menu height for a top bar only when menu autohide is disabled and `topmost` is false. User `y_offset` is additional to that clearance.
- [`display_menu_bar_visible()` in display.c](https://github.com/FelixKratz/SketchyBar/blob/v2.24.0/src/display.c) reads Window Server's autohide-enabled state. This is not equivalent to observing whether a hidden menu is temporarily revealed.
- The ARM menu-height path uses [`display_nsscreen_top_inset()`](https://github.com/FelixKratz/SketchyBar/blob/v2.24.0/src/display_nsscreen.m). It subtracts the top of `visibleFrame` from the top of `frame`, subtracts one point, and rounds. A reserved strip of 30 therefore produces a bar offset of 29.
- `notch_offset` in `bar_get_frame()` is gated by `CGDisplayIsBuiltin`, not a safe-area test. The virtual guest does not demonstrate its behavior on physical built-in displays.

This rules out unconditional addition of the native menu height. It does not establish that built-in clearance works for every target display.

## The topmost transition uses the previous value

[`bar_manager_set_topmost()`](https://github.com/FelixKratz/SketchyBar/blob/v2.24.0/src/bar_manager.c) calls `bar_manager_reset()` before storing the new `topmost` boolean. The reset uses the previous boolean for placement. A later resize uses the new value.

`placement.sh` reproduced that order and compared queried bounds with actual CoreGraphics windows where available:

| Case | Item top y | Result |
| --- | --- | --- |
| Initial `topmost=off`, `y_offset=0` | 29 | One real mouse click delivered. |
| Set `topmost=on`, no resize | 29 | Actual item and bar windows at y=29, layer 25. |
| Force resize with `y_offset=1` then `0` | 0 | Actual item and bar windows at y=0, layer 25. |
| Keep `topmost=on`, set `y_offset=30` | 30 | Actual windows at y=30. One real mouse click delivered. |
| Set offset back to 0, then `topmost=off` | 0 | Placement still reflects the old true value. |
| Force resize with `y_offset=1` then `0` | 29 | One real mouse click delivered. |

The click helper posts real mouse-down and mouse-up events at the queried item's center. The item's `click_script` writes a marker. All three tested below-menu placements produced exactly one marker each. No click was attempted in the menu-overlapping `topmost=on`, y=0 state.

CoreGraphics did not list the default lower-layer SketchyBar windows even with `optionAll`. Successful click delivery shows that this absence cannot be treated as evidence that the bar is invisible.

This is an external SketchyBar behavior, not a shipped stm defect. Existing V2 already requires effective verification. No new stm invariant or product fix was added from this finding.

## Multi-display clearance is not uniform

DeskPad produced a second 1440 by 900 display. Its global CoreGraphics origin was x=960, y=-154. The primary temporarily became 960 by 677. Stopping DeskPad restored the original single 1276 by 900 display.

With `topmost=off`, the primary reserved 30 points in `visibleFrame`. The secondary's `visibleFrame` equaled its full frame even though a visible native menu window occupied 30 points at its top.

| Case | Primary item top | Primary menu bottom | Secondary item top | Secondary menu bottom |
| --- | --- | --- | --- | --- |
| `display=all`, `y_offset=0` | 29 | 30 | -154 | -124 |
| `display=all`, `y_offset=30` | 59 | 30 | -124 | -124 |
| `display=2`, `y_offset=0` | Not targeted | 30 | -154 | -124 |
| `display=2`, `y_offset=30` | Not targeted | 30 | -124 | -124 |

The secondary overlaps the native menu at offset 0 despite `topmost=off`. A global offset of 30 clears the secondary but adds the same extra 30 points to the already-offset primary. This demonstrates the trade-off with one global `y_offset`; it does not yet choose a product policy.

AppKit reported the secondary as `{{960, -69}, {1440, 900}}`. This is not inconsistent with CoreGraphics y=-154. AppKit uses the opposite vertical axis, so with primary height 677, the top converts to `677 - (-69 + 900) = -154`. Compare item and menu bounds in the same coordinate system.

Secondary native-menu click delivery and physical-notch clearance remain unverified. Neither `visibleFrame` alone nor a single global offset is established as a complete solution.

## Display events cover topology and active display

The event item subscribes to `display_change` and `system_woke`, with updates enabled. Its script records the sender and event info.

| Operation | New display_change events in the final run |
| --- | --- |
| Add DeskPad display | 3, all INFO=1 |
| Move a native probe window to secondary and activate it | INFO=2 |
| Move that window to primary and activate it | INFO=1 |
| Change bar target from all to main | 0 |
| Change bar target from main to 2 | 0 |
| Change bar target from 2 to all | 0 |
| Remove DeskPad display | 3, all INFO=1 |
| Reconnect DeskPad display | 3, all INFO=1 |
| Final remove | 3, all INFO=1 |

The target changes were real. The item's bounding-rectangle set changed from both displays to only display-1, then only display-2, then both. A reconciler driven only by `display_change` would miss these runtime target changes.

The native focus helper closes its window and requests activation of the previous application. The final replay verified that the previous process was frontmost again. An earlier replay requested restoration unsuccessfully. The helper originally captured the previous application after its own activation-policy setup. Capture now occurs before that setup, and the helper verifies actual frontmost process identity rather than treating the activation request as success.

Source inspection agrees with the topology experiment. [`display.c`](https://github.com/FelixKratz/SketchyBar/blob/v2.24.0/src/display.c) maps CoreGraphics add, remove, move, and resize flags to internal events. [`event.c`](https://github.com/FelixKratz/SketchyBar/blob/v2.24.0/src/event.c) forwards them to the bar manager. [`bar_manager_display_changed()`](https://github.com/FelixKratz/SketchyBar/blob/v2.24.0/src/bar_manager.c) rebuilds bars and calls the public display-change handler. Source coverage of move flags is not a substitute for a real rearrangement probe.

The earlier geometry probe also confirmed that reload executes the configuration again. It did not observe a subscribed event from reload. Initial reconciliation must not assume reload emits `display_change`.

## Preference transitions with a running bar

A guest-only run on 2026-11-01 tested all four native menu modes with `topmost=off` and `topmost=on`. The user explicitly approved temporary guest preference changes and excluded host changes. The final replay used `/Users/admin/stm-menu-transitions.LGbDgd`.

`menu-transitions.sh` refuses a physical Mac, an existing SketchyBar, or either preference key already present. Before any preference write, it records the original absence of `_HIHideMenuBar` and `AppleMenuBarVisibleInFullscreen`. Its exit trap deletes both keys, verifies the specific missing-key errors, and stops its own bar process. This supports the observed absent baseline only, not arbitrary existing preference values.

Direct preference writes produced the same effective menu-mode table as T2 while SketchyBar was running. The native probe measured each mode on the desktop, in actual AppKit fullscreen, and after return to the desktop.

With `topmost=off` and `y_offset=0`, the item stayed at y=29 in all four modes. This held both before and after an explicit offset resize, even when `NSMenu.menuBarVisible()` was false and `visibleFrame` covered the full screen. Direct preference writes therefore did not make SketchyBar's automatic clearance track effective native-menu visibility in this run. This observation does not establish whether a fresh SketchyBar process, GUI preference changes, or a system restart changes that behavior.

With `topmost=on`, item y was 0 at offset 0 in the transition samples. The fullscreen round trips used an explicit offset of 30. Actual CoreGraphics item and bar windows agreed with the queried y=30 on the desktop.

## Fullscreen placement and desktop restoration

The final replay tested ten cases, followed by a restored-baseline round trip:

| Configuration | Fullscreen result | Desktop return |
| --- | --- | --- |
| `show_in_fullscreen=off`, all four menu modes, both topmost values | Item moved to `[-9999, -9999]`, outside the display. | Exact original item bounds and bar settings restored. |
| `show_in_fullscreen=on`, fullscreen-only menu mode, `topmost=off`, offset 0 | Item remained on the display at y=29. | Original bounds and settings restored. |
| `show_in_fullscreen=on`, fullscreen-only menu mode, `topmost=on`, offset 30 | Item and actual bar windows remained on the display at y=30. | Original bounds and settings restored. |

`bar-fullscreen.swift` asserts actual fullscreen entry, intersection of item bounds with the active display bounds, unchanged bar settings, and exact desktop-bound restoration. It verifies restoration of the previous frontmost application's process identity after every round trip. The shell probe separately asserts native-menu visibility for each phase. All ten case assertions and eleven focus restorations passed.

CoreGraphics reported `onScreen=true` for some SketchyBar windows at `[-9999, -9999]`. Neither that flag nor `bar.hidden=off` proves that a bar is visible on a display. Position must intersect an actual display. No clicks were posted during this fullscreen probe.

After direct deletion of the preference keys, the final round trip verified desktop-visible and fullscreen-hidden native-menu behavior. Cleanup returned 0. Independent post-run reads confirmed both keys absent and no SketchyBar process. The guest remained running. Host preferences, bar properties, and AeroSpace files were untouched.

## Physical-notch read-only observation

The host had one built-in display, 1728 by 1117 points at scale 2. AppKit reported a top safe-area inset of 32 and a top-right auxiliary area of `{{956.5, 1085}, {771.5, 32}}`. Its visible frame ended at y=1085 even though `NSMenu.menuBarVisible()` returned false. CoreGraphics listed a 33-point MenuBarAgent window at y=0.

The live host bar query still reported `y_offset=28`. This probe did not change that workaround or test host click behavior. Safe-area inset, visible-frame difference, menu-window height, and effective click clearance are distinct observations.

## Evidence and replay

Sources and output are in `tools/probes/smart-menu-bar/`:

- `geometry.sh` and `geometry.swift` record the original offset matrix and screen or menu window bounds.
- `placement.sh` and `click.swift` reproduce topmost placement and verify center-click delivery.
- `display-events.sh` and `focus.swift` exercise display lifecycle, actual target changes, active-display changes, and the shared-offset matrix.
- `evidence/geometry.log`, `evidence/placement.log`, and `evidence/display-events.log` contain guest output.
- `evidence/geometry-host.json` contains the read-only physical display observation.
- `menu-transitions.sh` and `bar-fullscreen.swift` test direct guest preference changes, fullscreen placement, and exact desktop-bound and bar-setting restoration.
- `evidence/menu-transitions-verified.log` contains the final ten-case replay. `evidence/menu-transitions.log` retains the initial eight-case observation run before placement assertions were added.

Probes do not collect window titles. `click.swift` refuses a non-VirtualMac model or missing event-posting permission and does not request permission. It only targets the fixed `stm.placement` item and restores the pointer location.

ShellCheck and Bash 3.2 and 5 syntax checks cover the shell probes. Swift programs compiled and ran inside the guest. Real click-marker counts, topology-event assertions, and the final fullscreen placement and restoration assertions passed.

Both full product suites passed, 29 of 29 test files on Bash 3.2 and Bash 5. Project and probe ShellCheck commands were silent. `sh -n install.sh` and `git diff --check` passed. The first combined test command exhausted its 300-second execution limit after Bash 3.2 passed and while Bash 5 was still running. Bash 5 then passed when run alone with a 600-second limit. No test assertion failure or product defect was reported, so no product invariant or SPEC change follows from this execution timeout.

## Remaining T3 gates

1. Exercise display rearrangement and confirm event delivery and coordinate matching. Negative origins are already measured, but no display was explicitly rearranged by the probes.
2. Verify physical-notch placement and clicks only with explicit host-test permission. The current approval excludes host changes. Synthetic geometry cannot establish physical-notch behavior.
3. Multi-display fullscreen placement remains unverified. The completed fullscreen cases use the guest's single display.
4. Decide T4 policy for global native-menu preferences, unequal per-display clearance, and runtime retarget changes. Do not add a watcher or fixed offset before those choices have evidence and approval.

T3 stays `todo` in SPEC.md. No product implementation is approved by these probe results.
