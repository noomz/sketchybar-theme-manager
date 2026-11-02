# Smart menu-bar geometry and event probes

T3 is complete. This report records source inspection and experiments on 2026-11-01. No product code, host preference, or AeroSpace configuration changed. The approved host probes temporarily added a scratch item and changed the runtime offset, then verified that both were restored.

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

## Display rearrangement and restoration

A later T3 replay on 2026-11-01 used `/Users/admin/stm-t3-rearrange.C7fOQV` and recorded its runtime snapshot in `/Users/admin/stm-display-events.0ZTvPt`. The guest was already running, with no SketchyBar or DeskPad process. No menu preferences were changed.

`rearrange.swift` refuses a non-VirtualMac machine. It snapshots the two active displays' IDs and origins before changing either display. Its session-scoped CoreGraphics transaction moves the secondary to the left of the primary. Restoration accepts only the saved original or expected moved topology, so an unexpected external rearrangement is not overwritten.

| Observation | Original | Moved | Restored |
| --- | --- | --- | --- |
| Primary CoreGraphics origin | `(0, 0)` | `(0, 0)` | `(0, 0)` |
| Secondary CoreGraphics origin | `(960, -154)` | `(-1440, 80)` | `(960, -154)` |
| Secondary item origin, offset 30 | `(980, -124)` | `(-1420, 110)` | `(980, -124)` |
| New `display_change` events | Baseline | 3 | 3 |

The helper asserted exact effective origins after move and restoration. The shell asserted positive event deltas for both operations. The moved secondary's item remained 20 points from its display's left edge and 30 points below its top. AppKit reported `{{-1440, -303}, {1440, 900}}`; conversion with primary height 677 gives CoreGraphics top `677 - (-303 + 900) = 80`. The native menu window also moved to `(-1440, 80)` and remained 30 points high. This verifies coordinate matching after an actual negative-origin rearrangement, not a synthetic fixture.

The shell retains an active topology snapshot until restoration succeeds. Its exit trap attempts restoration before removing DeskPad. Unexpected topology causes a nonzero exit and leaves DeskPad running for inspection. Forced process termination can bypass this trap; the snapshot remains in guest scratch storage. The successful run renamed its snapshot to `topology-restored.json` before later disconnect/reconnect tests.

The complete event probe returned exit 0. Its focus helper reported `focus_restore_verified=true`. Independent post-run process checks found no SketchyBar or DeskPad process. The guest stayed running. Evidence is `tools/probes/smart-menu-bar/evidence/display-rearrange.log`. Swift compiled in the guest; the existing focus helper emitted its macOS 14 activation-option deprecation warning. The changed shell probe passed ShellCheck and Bash 3.2 and 5 syntax checks. After this replay, both full product suites passed sequentially, 29 of 29 test files on Bash 3.2 and 29 of 29 on Bash 5. Product and probe ShellCheck commands were silent. `sh -n install.sh` and `git diff --check` passed.

## Multi-display fullscreen placement

`multidisplay-fullscreen.sh` ran on 2026-11-01 in the already-running guest. It starts only its own temporary SketchyBar and disposable DeskPad processes. Both menu preference keys were absent before and after the probe. The script makes no preference writes and refuses an existing SketchyBar or DeskPad process.

The first replay used `/Users/admin/stm-t3-fullscreen.WoLNIw`. The final replay used `/Users/admin/stm-t3-fullscreen.UGQdnE` after adding an explicit assertion that the other display's visibility stays unchanged. Both used `display=all`, `sticky=on`, `y_offset=30`, and `notch_offset=0`. The native fullscreen window was centered on the selected display before entry, and the helper verified the actual fullscreen window's display ID.

| `topmost` | `show_in_fullscreen` | Fullscreen target | Target bar intersects display | Other bar intersects display |
| --- | --- | --- | --- | --- |
| off | off | primary | false | true |
| off | off | secondary | false | true |
| off | on | primary | true | true |
| off | on | secondary | true | true |
| on | off | primary | false | true |
| on | off | secondary | false | true |
| on | on | primary | true | true |
| on | on | secondary | true | true |

The primary fullscreen window occupied AppKit `{{0, 0}, {960, 677}}`. The secondary occupied `{{960, -69}, {1440, 900}}`, matching that display. Native menu visibility was true on desktop and false in fullscreen. The helper matched SketchyBar's display arrangement IDs to CoreGraphics display IDs and tested each item's rectangle against its own display bounds. It did not accept intersection with any other display as evidence of target visibility.

All eight multi-display cases asserted fullscreen entry on the intended screen, target visibility matching `show_in_fullscreen`, unchanged visibility on the other screen, unchanged bar settings, and exact desktop item-bound restoration. The shell checked native-menu visibility and focus restoration. After DeskPad closed, two more cases exercised the helper's original no-argument single-display interface with `show_in_fullscreen` off and on. All ten cases passed, with ten verified focus restorations and `cleanup_result=0`.

Final evidence is `tools/probes/smart-menu-bar/evidence/multidisplay-fullscreen-verified.log`. The initial eight-case observation is retained as `multidisplay-fullscreen.log`. No fullscreen clicks were posted, so these results prove geometry and restoration, not click delivery on either display.

The first compile of the extended helper failed because its class referred to a top-level `guard let` binding. Passing the target screen and ID through `Probe.init` fixed that probe-only Swift scope error. It is not a product defect or a new platform invariant. Both helpers then compiled in the guest. After the final replay, both full product suites passed sequentially, 29 of 29 test files on Bash 3.2 and 29 of 29 on Bash 5. Product and probe ShellCheck commands were silent. The new runner passed Bash 3.2 and 5 syntax checks. `sh -n install.sh` and `git diff --check` passed.

A read-only host capture after these probes still showed `y_offset=28`, `topmost=off`, `position=top`, and `show_in_fullscreen=off`. The sole display remained 1728 by 1117, with top safe inset 32. Its two auxiliary areas ended at x=771.5 and began at x=956.5, respectively, identifying the camera-housing gap. The current visible frame ended at y=1083, not the earlier y=1085. This changed observation reinforces that visible-frame clearance must not be cached or equated with the safe inset. No host item, offset, pointer, preference, or configuration was changed.

## Physical-host click attempt and user offset correction

The user explicitly approved an automated temporary physical-host probe, followed by design only. Scope excluded macOS preference writes, config edits, reload, and grouping changes. The probe was allowed to add one scratch item, temporarily adjust runtime offset if needed, post clicks only on that item using existing permission, and restore cursor and bar offset.

`host-notch-click.swift` compiled on the host. A deliberate mismatched-model invocation refused before mutation. The approved invocation on `Mac16,5` saved `/tmp/stm-host-notch.ogrgAy/snapshot.json` before creating a unique scratch item. It measured clearance 34 and original runtime offset 28. The scratch rectangle was `{{1070, 59}, {100, 34}}`; a synthetic center click at `(1120, 76)` produced zero handler deliveries. The probe failed, restored the cursor, removed its scratch item, and verified `y_offset=28`. Evidence is `tools/probes/smart-menu-bar/evidence/host-notch-click.log`. No offset write was needed or attempted during that failed run.

Subsequent read-only inspection found a full-display, on-screen `Screenshot` overlay. It may explain interception, but causation has not been proved. The probe now refuses that overlay before item, offset, or pointer mutations. The updated helper compiled, but no second host click was attempted. A failed click is not proof that either the notch or the offset caused the failure. T3 click delivery remains unverified.

The user then reported excessive top offset. Read-only queries showed the group's selector at y=59 with runtime `y_offset=28` and `topmost=off`: native placement was already contributing 31 points. The user explicitly chose to remove the old 28-point workaround and pause host click probes. One runtime `sketchybar --bar y_offset=0` was applied. Re-query verified offset 0 and selector origin `(1678, 31)` with size `(44, 34)`. No config file or macOS preference changed.

**Current host baseline is runtime `y_offset=0`, not 28.** Do not replay the earlier probe snapshot to restore 28. That snapshot is historical and has been superseded by the user's explicit correction. The user later resumed host click testing; see the next section.

## Physical-notch click delivery

The user resumed automated host click testing on 2026-11-01. The baseline was runtime `y_offset=0`, `topmost=off`, `position=top`.

The first rerun refused to start: `screencaptureui` held an on-screen window that covered the whole display at layer 24. With the user's approval, the process was quit. The overlay did not come back.

The next run delivered 0 clicks at `(1120, 48)`. The item rectangle was `{{1070, 31}, {100, 34}}`, below the 34-point clearance. A read-only check of the window stack at that point showed an Open Design window at layer 0 above the SketchyBar window at layer -20. The bar is not raised when `topmost=off`, so any app window that overlaps the bar receives the clicks. Both earlier zero-delivery host runs therefore say nothing about the notch.

The probe now refuses to click unless the front-most on-screen window at the click point belongs to SketchyBar, and reports the window that is in the way. The first version of this check passed `.excludeDesktopElements` to CoreGraphics. That option hides the layer -20 bar window, so the check refused every click. It now lists all on-screen windows. The cursor-restoration check now polls for up to 1 second instead of reading once after 0.1 seconds, and every click is logged before the check.

The final run used a temporary empty AeroSpace workspace and returned to the user's workspace afterwards. It delivered 7 of 7 clicks:

| Phase | Offset | Item rectangle | Edges clicked | Deliveries |
| --- | --- | --- | --- | --- |
| Current placement | 0 | `{{1070, 31}, {100, 34}}` | center | 1 of 1 |
| Right of the camera housing | 3 (temporary) | `{{1070, 34}, {100, 34}}` | top, center, bottom | 3 of 3 |
| Left of the camera housing | 3 (temporary) | `{{504, 34}, {100, 34}}` | top, center, bottom | 3 of 3 |

Cleanup verified offset 0, removal of the scratch item, and cursor restoration after every click. Evidence is `tools/probes/smart-menu-bar/evidence/host-notch-click.log`.

This result supports these conclusions:

- With the menu shown on the desktop, SketchyBar's automatic 31-point clearance already keeps the item center clickable on this notched display. The 3 points between y=31 and the measured 34-point clearance were not clicked at offset 0.
- When the item starts at the measured clearance, its top edge, center, and bottom edge are all clickable on both sides of the camera housing.
- When `topmost=off`, app windows that overlap the bar take its clicks. Clearance below the native menu is necessary, but not sufficient. Clicks also depend on window gaps, which C2 keeps out of scope, or on `topmost`.

No click targeted the camera-housing gap itself. No click was tested in fullscreen, or while the native menu was hidden on the desktop.

## Remaining T3 gates

None. T4 policy choices 1 to 3 were approved on 2026-11-01; see [the T4 design](smart-menu-bar-t4-design.md).
