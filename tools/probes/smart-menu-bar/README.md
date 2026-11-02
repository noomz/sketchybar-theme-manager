# Guest-only menu-bar probes

These scripts reproduce T2 preference observations. They are not product code or a general recovery tool. They support only a VirtualMac guest whose two tested preference keys are initially absent and whose GUI mode is `In Full Screen Only`.

## Requirements

- Use a disposable Tart macOS guest. Never run a mutating probe against the host.
- Obtain permission before changing guest preferences.
- Enable System Events Accessibility in the guest. The recorded guest already had this permission.
- Install the guest developer tools for the two Swift observation programs. These tools are not stm runtime dependencies.
- Open System Settings at Menu Bar, with the English popup `Automatically hide and show the menu bar` available.

Every shell probe checks `hw.model` for `VirtualMac` before touching preferences. This guard prevents accidental use on a physical Mac. It does not replace explicit VM-target selection.

## Files

| File | Purpose |
| --- | --- |
| `prepare.sh` | Checks the supported baseline and records missing-key evidence. Refuses to replace an existing snapshot. Makes no preference writes. |
| `menu-mode.applescript` | Reads or selects the GUI mode through the named popup. A selection can return the old value before UI refresh, so later samples read it again. |
| `measure.swift` | Reads menu visibility, screen geometry, and menu-window bounds without collecting window titles. |
| `fullscreen.swift` | Creates one native window, measures desktop and actual fullscreen behavior, then closes it. |
| `ui-modes.sh` | Selects all four GUI modes and records desktop behavior. |
| `defaults-modes.sh` | Compares direct writes with effective behavior and stale Settings text. |
| `fullscreen-modes.sh` | Asserts all four mode behaviors and direct fullscreen-only writes using the native window. |
| `restore-absent.sh` | Asserts direct deletion-based restoration without GUI reset. |
| `t7.sh` | T7 end-to-end check of `stm menubar` and `item:menubar` against real preferences, a real SketchyBar, DeskPad hotplug and native fullscreen. Restores the absent baseline on exit. See [the T7 notes](../../../docs/research/smart-menu-bar-t7.md). |
| `t7-osascript.sh` | `STM_OSASCRIPT` stand-in for `t7.sh`: the real screen query plus a synthetic camera housing on the first screen while `$T7_DIR/notch` reads `on`. |
| `evidence/` | Raw output from the final successful replay on macOS 27.0 build 26A428. |

## Prepare a fresh guest directory

Run these commands on the host from this directory. Replace `mac_jr` if the approved disposable guest has another name. Do not point the commands at the host.

```sh
VM=mac_jr
D=$(tart exec "$VM" /usr/bin/mktemp -d /Users/admin/stm-smart-menu-probe.XXXXXX)
printf 'Guest snapshot directory: %s\n' "$D"

for f in prepare.sh menu-mode.applescript measure.swift fullscreen.swift \
  ui-modes.sh defaults-modes.sh fullscreen-modes.sh restore-absent.sh; do
  tart exec -i "$VM" /usr/bin/tee "$D/$f" < "$f" >/dev/null || exit 1
done

tart exec "$VM" /usr/bin/open \
  'x-apple.systempreferences:com.apple.ControlCenter-Settings.extension'
tart exec "$VM" /bin/sh "$D/prepare.sh" "$D" || exit 1
tart exec "$VM" /usr/bin/swiftc "$D/measure.swift" -o "$D/measure" || exit 1
tart exec "$VM" /usr/bin/swiftc "$D/fullscreen.swift" -o "$D/fullscreen" || exit 1
```

If preparation refuses the baseline, stop. Do not delete existing preferences to make the probe run. The snapshot files describe original absence and remain available after each probe.

## Run one probe at a time

Continue in the same host shell. Each script restores the original absence on exit. A cleanup failure returns a nonzero status.

```sh
tart exec "$VM" /bin/sh "$D/ui-modes.sh" "$D" || exit 1
tart exec "$VM" /bin/sh "$D/defaults-modes.sh" "$D" || exit 1
tart exec "$VM" /bin/sh "$D/fullscreen-modes.sh" "$D" || exit 1
tart exec "$VM" /bin/sh "$D/restore-absent.sh" "$D" || exit 1
```

Expected final markers are `restore_result=0` for the first three scripts and `restore_absence_pass=1` for the last. The fullscreen script also prints five `case_pass` records.

For a disconnected session or forced process termination, inspect the retained snapshot before any recovery. For this specific absent baseline, recovery consists of deleting each of the two tested keys in the guest and verifying effective desktop/fullscreen behavior. Never delete keys belonging to an unknown baseline or reuse these scripts for a present-value snapshot.

The recorded final replay used `/Users/admin/stm-smart-menu-probe.8MvYHg`. It left both keys absent. See [`docs/research/smart-menu-bar-t2.md`](../../../docs/research/smart-menu-bar-t2.md) for results and unsupported cases.

## Run geometry and display-event probes

These T3 probes do not change menu preferences. They start a temporary guest SketchyBar and stop it on exit. They refuse a physical Mac or an existing SketchyBar process. Coordinate use of an already-running guest before changing its display topology.

Use SketchyBar 2.24.0 at `/opt/homebrew/bin/sketchybar` in the guest. These development probes also require the guest Swift compiler. Swift and DeskPad are not product dependencies.

From this directory on the host, copy and compile the helpers:

```sh
VM=mac_jr
D=$(tart exec "$VM" /usr/bin/mktemp -d /Users/admin/stm-t3.XXXXXX)
for f in geometry.swift click.swift focus.swift rearrange.swift geometry.sh placement.sh display-events.sh; do
  tart exec -i "$VM" /usr/bin/tee "$D/$f" < "$f" >/dev/null || exit 1
done
for f in geometry click focus rearrange; do
  tart exec "$VM" /usr/bin/swiftc "$D/$f.swift" -o "$D/$f" || exit 1
done

tart exec "$VM" /bin/sh "$D/geometry.sh" "$D/geometry" || exit 1
tart exec "$VM" /bin/sh "$D/placement.sh" "$D/geometry" "$D/click" || exit 1
```

`placement.sh` posts real center clicks to its own `stm.placement` item. If event-posting permission is missing, the helper refuses without requesting permission. Expect three `click_deliveries=1` markers.

For display events, copy the installed DeskPad application to the guest scratch directory. The recorded probe uses DeskPad 1.3.2. Do not replace a guest application or grant screen-recording permission for this probe.

```sh
/usr/bin/tar -C /Applications -cf - DeskPad.app |
  tart exec -i "$VM" /usr/bin/tar -C "$D" -xf - || exit 1

tart exec "$VM" /bin/sh "$D/display-events.sh" \
  "$D/geometry" "$D/DeskPad.app/Contents/MacOS/DeskPad" "$D/focus" "$D/rearrange" || exit 1
```

The script adds the DeskPad display, snapshots both display origins, moves the secondary display to the left of the primary, and restores the exact saved origins. The move uses a session-scoped CoreGraphics display transaction, not a permanent display preference. The helper verifies effective origins after both operations, and the shell asserts that each operation delivers `display_change`.

An exit trap restores the topology before stopping DeskPad if the snapshot is still active. Recovery refuses a topology that matches neither the original nor the probe's expected moved state. On recovery failure, the probe returns nonzero and leaves DeskPad running so the saved display still exists. Inspect the printed snapshot path before any manual recovery. A forced kill can bypass the shell trap.

The script then removes, reconnects, and removes the DeskPad display. It also changes its temporary bar's target and offset. The native focus helper briefly activates its window on each display, then closes it and checks restoration of the previous application's focus. The script refuses an existing DeskPad process.

Expected evidence includes two displays after add and reconnect, one after each removal, and `display_change` events for those topology changes. Rearrangement adds `move_verified=true`, `restore_verified=true`, and positive `rearrange_events` and `restore_events` counts. Active-display transitions produce INFO=2 then INFO=1. Actual bar retargeting produces no display-change event in the recorded run.

The guest stays running if it was already running. Scratch files remain for inspection. See [`smart-menu-bar-t3.md`](../../../docs/research/smart-menu-bar-t3.md) for findings and remaining gates.

## Test preference transitions and fullscreen placement

Obtain explicit approval before this probe changes guest preferences. Do not run it on the host. Use a guest with one display, no running SketchyBar, and both tested preference keys absent. The probe refuses other preference baselines. Do not delete an existing key to make the probe run.

From this directory on the host, create a fresh guest scratch directory:

```sh
VM=mac_jr
D=$(tart exec "$VM" /usr/bin/mktemp -d /Users/admin/stm-menu-transitions.XXXXXX)
for f in geometry.swift bar-fullscreen.swift menu-transitions.sh; do
  tart exec -i "$VM" /usr/bin/tee "$D/$f" < "$f" >/dev/null || exit 1
done
for f in geometry bar-fullscreen; do
  tart exec "$VM" /usr/bin/swiftc "$D/$f.swift" -o "$D/$f" || exit 1
done
tart exec "$VM" /bin/sh "$D/menu-transitions.sh" "$D" || exit 1
```

Expect ten `case_pass` records, eleven `focus_restore_verified=true` records, `restore_behavior_pass=1`, and `cleanup_result=0`. The first eight cases cover all four menu modes with both `topmost` values. Two more cover fullscreen-only mode with `show_in_fullscreen=on`. Every fullscreen round trip asserts display intersection, exact desktop-bound restoration, and preservation of `topmost`, `y_offset`, `sticky`, `show_in_fullscreen`, and `position`.

The script snapshots both keys before changing them. Its exit trap restores their absence and stops its own bar. The final native fullscreen round trip verifies effective restoration before exit. If cleanup fails, retain the scratch directory and inspect both `*.type` snapshots and `*.restore-error` files. Do not apply absent-key recovery to a different baseline.

The final replay used `/Users/admin/stm-menu-transitions.LGbDgd`. Output is in `evidence/menu-transitions-verified.log`. The earlier `evidence/menu-transitions.log` records eight observation cases before explicit bar-placement assertions were added. No host settings or live-bar properties changed.

## Test fullscreen on two displays without preference writes

Use an already-running disposable VirtualMac guest, no running SketchyBar or DeskPad, and both tested menu keys absent. This probe refuses a different preference baseline and never writes preferences. Coordinate guest use before adding its temporary display.

```sh
VM=mac_jr
D=$(tart exec "$VM" /usr/bin/mktemp -d /Users/admin/stm-t3-fullscreen.XXXXXX)
for f in geometry.swift bar-fullscreen.swift multidisplay-fullscreen.sh; do
  tart exec -i "$VM" /usr/bin/tee "$D/$f" < "$f" >/dev/null || exit 1
done
for f in geometry bar-fullscreen; do
  tart exec "$VM" /usr/bin/swiftc "$D/$f.swift" -o "$D/$f" || exit 1
done
/usr/bin/tar -C /Applications -cf - DeskPad.app |
  tart exec -i "$VM" /usr/bin/tar -C "$D" -xf - || exit 1
tart exec "$VM" /bin/sh "$D/multidisplay-fullscreen.sh" \
  "$D" "$D/DeskPad.app/Contents/MacOS/DeskPad" || exit 1
```

The runner tests primary and secondary fullscreen entry with both `topmost` values and both `show_in_fullscreen` values. It then closes DeskPad and checks the helper's original single-display interface with fullscreen visibility off and on. Expect ten `case_pass` records, ten `focus_restore_verified=true` records, and `cleanup_result=0`.

`bar-fullscreen primary` and `bar-fullscreen secondary` require exactly two guest displays. Without an argument, the helper requires one. It matches each SketchyBar arrangement ID to a CoreGraphics display ID before testing item intersection with that display. During fullscreen, it checks the target window's screen and requires other displays' item visibility to remain unchanged. Every round trip checks exact desktop bounds and unchanged bar settings. It does not post clicks or prove physical-notch clearance.

The exit trap stops only the runner's own SketchyBar and DeskPad processes and verifies that the two preference keys remain absent. It reports an unexpected external preference change without overwriting it. Guest scratch files remain for inspection. Forced termination can bypass cleanup.

The final replay used `/Users/admin/stm-t3-fullscreen.UGQdnE`. Evidence is `evidence/multidisplay-fullscreen-verified.log`; the initial eight-case observation is `evidence/multidisplay-fullscreen.log`.

## Physical-host click probe status

`host-notch-click.swift` is a separately approved host-only experiment, not an installable feature. It requires an exact approved machine model, existing event-posting permission, one confirmed notched built-in screen, and a fresh snapshot directory. It snapshots before mutation, refuses a full-screen Screenshot overlay, adds only a unique scratch item, and posts clicks only below measured clearance. It refuses to click unless the front-most on-screen window at the click point belongs to SketchyBar. It removes its item and verifies restoration of any owned offset; unexpected external offset changes are not overwritten. A process kill can bypass cleanup, so retain the snapshot.

When `topmost=off`, the bar window is at layer -20, below app windows. Run the probe on an empty workspace, for example `aerospace workspace stm-probe`, and return to the original workspace afterwards.

The 2026-11-01 run delivered 7 of 7 clicks on a notched `Mac16,5`. Two earlier zero-delivery runs had an app window covering the click point. Evidence is `evidence/host-notch-click.log`, and the T3 report has the details. Run the helper again only with explicit user approval. Never replay `/tmp/stm-host-notch.ogrgAy/snapshot.json`: its offset of 28 is obsolete, and the host baseline is 0.
