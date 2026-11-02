# Smart menu-bar preference probe

T2 evidence from Tart VM `mac_jr`, macOS 27.0 build 26A428, model `VirtualMac2,1`, user `admin`. Probe ran on 2026-10-31 UTC. These results apply to this guest build, not every macOS release.

The host's macOS preferences and SketchyBar were untouched. No product code changed. Swift helpers are disposable probe tools, not a new runtime dependency.

## Initial state and recovery

Both `_HIHideMenuBar` and `AppleMenuBarVisibleInFullscreen` were absent from `NSGlobalDomain`. Settings showed `In Full Screen Only`. The guest had two virtual screens, 1024 by 768 and 3360 by 2100. Both had zero top safe-area inset. Neither is physical-notch evidence.

Initial snapshot directory was `/Users/admin/stm-smart-menu-probe.Ve1gKA`. Final scripts were replayed from a fresh snapshot at `/Users/admin/stm-smart-menu-probe.8MvYHg` after adding the VirtualMac guard and checked cleanup. Both snapshots remain in the guest for recovery inspection.

Each mutating script uses an exit trap. Cleanup failure produces a nonzero exit. The final restoration test deletes both keys directly without a preceding GUI reset, then verifies desktop and fullscreen behavior. Its assertions passed.

Final checks found both keys absent and Settings showing the original mode. No logout, reboot, `sudo`, or system-service restart was used during the preference probes. After verification, Tart stopped the guest, returning it to its original stopped state.

## Observed mode table

The popup was changed through Accessibility. A temporary native AppKit window then entered actual system fullscreen, checked its fullscreen style mask, measured visibility, and returned to desktop. The window closed after each run.

| GUI mode | `_HIHideMenuBar` | `AppleMenuBarVisibleInFullscreen` | Desktop menu | Fullscreen menu |
| --- | --- | --- | --- | --- |
| Always | true | absent, effective false | hidden | hidden |
| On Desktop Only | true | true | hidden | visible |
| Never | false | true | visible | visible |
| In Full Screen Only | false | false | visible | hidden |

The absent fullscreen key in the first row reflects this particular sequence from the original absent baseline. It is not a requirement that Always use an absent key.

Native fullscreen window height provided a second observation. With a visible fullscreen menu it was 738 points on the 768-point primary display. With a hidden fullscreen menu it was 768 points. This measured 30-point menu area does not establish the correct offset for a physical notched screen.

All four mode assertions passed in `fullscreen-modes.sh`. The test inspected `NSMenu.menuBarVisible()` and the window's actual fullscreen state. It did not infer effective behavior from preference values alone.

## Direct writes and propagation

The tested fullscreen-only writes were:

```sh
/usr/bin/defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool false
/usr/bin/defaults write NSGlobalDomain _HIHideMenuBar -bool false
```

After switching the GUI to Always, these writes changed effective desktop behavior by the first sample in `defaults-modes.log`. The primary visible frame changed from height 768 to 738. No reboot or explicit notification was needed in this guest. Sampling was coarse and included process-launch and UI-query time, so this is not a latency bound.

After switching the GUI to Never, the same writes produced desktop-visible and fullscreen-hidden behavior in the native fullscreen probe. All direct-write assertions passed.

`defaults read-type` reported boolean for both keys after explicit writes. Commands ran as the logged-in user without elevation. The guest already allowed System Events Accessibility, so this does not prove operation with denied Accessibility permission or managed preferences.

## Failure and ambiguity found

Stored values, effective behavior, and Settings text can disagree. After direct writes, the Settings dropdown continued to show Always or Never even though the native probe showed fullscreen-only behavior. Quitting and reopening Settings did not refresh that text in the tested sequence.

Therefore, neither a successful `defaults write` nor the dropdown text is sufficient verification. This observation fits existing smart-menu V2 and V6. It is platform-probe evidence, not a shipped-code defect or a reason to rewrite the spec during build.

An initially absent key makes `defaults read` fail. The final preparation script checks the specific missing-key error and refuses an unexpected baseline. It does not treat every preference-read failure as an absent/default value.

The `visibleFrame` value for a secondary display also varied with active application/Space state during the probes. Do not treat one sample as a permanent menu-bar clearance measurement. T3 must explain that geometry before implementation uses it.

## Restoration without GUI help

`restore-absent.sh` writes true/true, verifies desktop-hidden/fullscreen-visible behavior, deletes both keys, and verifies desktop-visible/fullscreen-hidden behavior. Every assertion passed. This demonstrates deletion-based restoration of the observed absent baseline, not restoration of arbitrary types, per-host overrides, or MDM-enforced values.

## Evidence and replay

Source probes and raw final-run logs are in [`tools/probes/smart-menu-bar/`](../../tools/probes/smart-menu-bar/). Its README describes the guest-only setup and execution. The final replay returned exit 0 for all four mutating scripts. ShellCheck was silent.

The final logs contain five `case_pass` records, three successful `restore_result` records, and `restore_absence_pass=1`. They preserve observation order and geometry. No host window titles or credential data were collected.

## Repository verification

Both full suites passed sequentially, 29 of 29 test files on Bash 3.2 and 29 of 29 on Bash 5. Both project ShellCheck commands were silent, and `sh -n install.sh` passed. The five probe shell scripts also passed ShellCheck and syntax checks with both Bash versions.

The first full-suite attempt ran the Bash versions concurrently. Both failed only the existing Tailscale hang test. `tests/test_item_tailscale.sh:57,388-390` uses a shared sleep duration and global process matching. Sequential targeted runs passed 40 of 40 assertions on each Bash version, followed by the successful sequential full suites. This is the same test-isolation class recorded for the AI test in item-bundles B14. No unrelated test fix or smart-menu spec change was made. A separate backprop change could require process matching to identify only the current test invocation.

## Remaining gates

- T3 must probe actual SketchyBar offsets, event delivery, target-display changes, and physical-notch geometry. SketchyBar was not installed in this guest, so no SketchyBar result is claimed here.
- Multi-display fullscreen behavior beyond the primary test window remains unverified.
- Other macOS releases, standard non-admin users, denied permissions, managed preferences, per-host overrides, interrupted writes, and reboot persistence remain unverified. Do not advertise support based on this one guest.
- T4 still requires an approved ownership and recovery design. These probes do not authorize product implementation or host preference changes.
