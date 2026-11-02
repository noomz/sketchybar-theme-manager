# Smart menu-bar end-to-end check in Tart

T7 evidence from Tart guest `mac_jr`, macOS 27.0 build 26A428, `VirtualMac2,1`, SketchyBar 2.24.0. The final run was on 2026-11-02. These results apply to this guest build.

The host's preferences and bar were not changed. On the host, the only commands were read-only: `stm menubar status` and one JXA screen and window query.

## What was real and what was synthetic

The guest has no camera housing. The runner points `STM_OSASCRIPT` at [`t7-osascript.sh`](../../tools/probes/smart-menu-bar/t7-osascript.sh). It runs the real screen query. While the scenario asks for a notch, it then reports a top safe-area inset of 32 and a 185-point camera gap on the first screen, the values T3 measured on the physical `Mac16,5`.

Everything else was real:

- the two global menu preferences, written and read with `defaults`
- the SketchyBar process, its `--reload`, its item geometry and its events
- the `item:menubar` hook, installed with `stm install item:menubar`
- the per-user state file and lock in `~/.local/state/stm`
- a second display from DeskPad, native fullscreen, and the native menu visibility that `NSMenu.menuBarVisible()` reports

The runner is [`t7.sh`](../../tools/probes/smart-menu-bar/t7.sh). It refuses to start unless both preferences are absent, no state directory exists, and no SketchyBar or DeskPad process is running. Its exit trap stops its own processes, deletes both keys, removes the state directory and checks all three. It keeps the item ledger inside the probe directory through `XDG_CONFIG_HOME`.

## Result

The final run passed 69 of 69 assertions, and the exit trap reported `restore_result=0`. The raw output is [`evidence/t7.log`](../../tools/probes/smart-menu-bar/evidence/t7.log).

| Case | Observed |
| --- | --- |
| Config absent (V1) | The hook ran on `forced`. No preference write, no state, `y_offset` 0. |
| On, real geometry, no notch (V3) | `confirmed-no-notch`, nothing to do, no state. |
| On, synthetic notch (V2) | Both preferences `bool:false`, originals `absent`. `y_offset` 0 to 3, so the bar starts at 32, the clearance. The desktop menu stayed visible. |
| Repeated refreshes, triggered `system_woke` and `display_change`, and 5 hook runs at once (V5, V7) | `y_offset` stayed 3 and the originals stayed `absent`. No lock or dirty mark was left. |
| `--dry-run` for refresh and restore (V11) | State file byte-identical, preferences and offset unchanged. |
| Bar restart (V5) | The new process starts at `y_offset` 0. The `forced` hook set 3 again, with the same originals. |
| Native fullscreen | Menu hidden in fullscreen, visible on the desktop before and after. No hook run, no change. |
| DeskPad display added (V12, V14) | Three `display_change` hook runs. The secondary needs 30, so `y_offset` became 30 and both displays are clear. The notched primary then starts at 59, which is the trade-off T4 approved. Removing the display brought `y_offset` back to 3. |
| User sets `_HIHideMenuBar` true after stm (V4) | `refresh` warns of the conflict and keeps the user's value. A reload does not overwrite it. Turning the config off restores only the other key and the offset. |
| Disable through the hook (V9) | `smart_notch = "off"` and a reload restored the absent baseline and offset 0. The state file was removed. |
| `stm menubar restore` with the config on (V9) | The absent baseline was restored, and stm warned that the next refresh applies the values again. |
| Stale lock | `refresh` exits nonzero and names the lock. The lock is kept, `status` names it, and nothing is written. |
| Baseline Always (`_HIHideMenuBar` true) | Applied `false/false` and the menu became visible. SketchyBar had started without menu clearance, so `y_offset` became 32. A reload kept 32, still clear. Disabling restored `bool:true` and the absent key, and the menu was hidden again. |
| Bottom bar | Nothing to do. No write, no state. |

## Defects found and fixed

The first full run exposed two problems. A read-only `stm menubar status` on the host then exposed a third. All three were fixed before the final run. They are recorded in the spec as B7 and B8, with V14 and V15.

- **B7, V14.** With DeskPad attached, stm measured the secondary display's clearance as 0, and the bar overlapped that display's native menu. The secondary's `visibleFrame` equals its full frame even while a 30-point menu window is on screen at its top, as T3 had recorded. stm now also reads the on-screen layer-24 menu windows with `CGWindowListCopyWindowInfo`, which needs bounds only and no permission, and takes the deepest of the safe inset, the visible-frame gap and the window. The same query on the host returned gap 31 and window 30 for the external display, and inset 32, gap 32 and window 33 for the notched built-in display.
- **B8, V15.** The host status reported `bar_top -9999`. Hidden popup rows such as `stm.ai.claude.0.row.head` are parked at (-9999, -9999) with the bar's height of 34, and stm took the highest bar-height item window. On a notched target, that would have set an offset near 10030. stm now counts a window only when its origin lies inside its display's frame. Host status then read 30.
- **Restore warning.** `stm menubar restore` with the config still on did not warn that the next refresh applies the values again, as the T4 design requires. It does now.

The sandbox suite has a test for each fix, and the parked-window case has its own stub item.

## Harness problems, not product results

Four runs failed or stopped for reasons in the runner, not in stm. They are listed so that nobody reads those logs as product evidence:

1. `grep -c` printed a second `0` when nothing matched. The run stopped before any write.
2. The item ledger lives at `$XDG_CONFIG_HOME/stm/items`, so the first install added `menubar` to the guest's own ledger, and later installs reported it as already installed. That one line was removed from the guest ledger, and the runner now uses its own `XDG_CONFIG_HOME`. The same run hung on a bare `wait`, which also waits for the bar. It was stopped with TERM, and its exit trap restored the guest.
3. The guest's `tart exec` PATH has no `/opt/homebrew/bin`, and its `/usr/local/bin/sketchybar` points at a missing build. stm could not query the bar, so it warned and wrote nothing, as V10 requires. The brew service PATH starts with the Homebrew prefix. The runner now does the same.
4. After the V14 change the screen query has eight fields, and the notch wrapper still matched seven, so no notch was injected. The wrapper now matches eight.

## Host test

The user approved this test on 2026-11-02. It ran on the user's `Mac16,5` on macOS 27.2, with the built-in notched display and an external 2560-point display. SketchyBar ran as the brew service. The real config was backed up first, then `display` was set to `"all"` and `smart_notch` to `"on"`, because the host bar normally sits only on the external display.

The stm under test was a throwaway merge of this branch with `feat/widget-groups`, because the live config uses groups. A dry run on a copy of the config showed that the install only added the `stm.menubar` block and one ledger row.

| Check | Observed |
|---|---|
| Notch detection | Built-in `confirmed-notch`, external `confirmed-no-notch`. |
| Clearance | Built-in clearance 33, bar top 33. External clearance 31, bar top 32. |
| Offset | `y_offset` went from 0 to 2 through the real hook on reload, and stayed 2 after a second reload. |
| Preferences | Both already `bool:false` before the test. stm recorded `owner` as `unchanged` and wrote nothing. |
| Placement and clicks | The user confirmed the bar below the native menu on both displays, and clicks on native menus and bar items. |
| Undo | `stm menubar restore` set `y_offset` to 0 and warned that the config was still on. After `stm uninstall item:menubar` and restoring the two edited files, all 97 config and ledger files matched their backup checksums. |

The host preferences did not change, so the write path ran only in Tart. The hook used a temporary `STM_BIN` line in its installed plugin copy, because the host's installed stm predates `menubar`. The plugin's own stm lookup therefore did not run on the host.

## Not covered here

- Preference writes on physical hardware. The host already had both values set to false.
- The plugin's stm lookup under the brew service PATH. The host test set `STM_BIN`.
- Sleep and wake. `system_woke` was triggered with `--trigger`, not by a real wake.
- Settings changes through the GUI. The user change was simulated with `defaults write`, which T2 showed has the same effect.
- Other macOS releases, standard users, managed preferences, and a reboot.
