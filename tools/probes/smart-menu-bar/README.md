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
