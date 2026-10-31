# Smart menu-bar avoidance investigation

T1 evidence. Inspected baseline `682527f`. Smart-menu work is separate from the unfinished widget-groups changes in the original checkout. No product code, host preferences, or host bar state changed during this investigation.

## Existing code

| Concern | Code | Finding |
| --- | --- | --- |
| Notch query | `bundles/items/compact/plugin.sh:87-124`, `measure()` | Queries the bar, displays, and item bounds. One JXA invocation reads `NSScreen.frame` and `auxiliaryTopRightArea`. JXA failure produces an empty screen file. |
| Display matching | `bundles/items/compact/plugin.sh:344-365` | Matches frame x, width, and height. Subtracts display x from global notch/item coordinates. Missing screen data leaves `notch = 0`. This is a fitting fallback, not safe evidence for preference restoration. |
| Bottom bars | Same fitter | Uses notch boundary only when bar position is not `bottom`. |
| Subscriptions | `bundles/items/compact/item.toml`, `item.lua:87-96` | Manifest declares `display_change` and `system_woke`. Lua adds `routine` and `forced`, subscribes, and invokes the plugin during initial load. |
| Offset validation | `bin/stm:510-519`, `815-823` | Accepts signed `y_offset` and nonnegative `notch_offset`. Both have existing user meaning. |
| Generated layout | `bin/stm:3847-3923`, `write_layout()` and `write_layout_lua()` | Writes the owned overlay atomically. Does not rewrite user item files or the user's Lua initialization. |
| Apply/reload | `bin/stm:4200-4236`, `cmd_apply()` | Writes layout and owned state before `sketchybar --reload`. Runtime-only bar changes need reconciliation after reload. |

## Documented platform behavior

- [SketchyBar bar properties](https://felixkratz.github.io/SketchyBar/config/bar) defines `y_offset` as a global vertical offset and `notch_offset` as an additional offset exclusively on notched screens. Probe `notch_offset` before choosing a global adjustment. Preserve both existing offsets if either becomes managed.
- [SketchyBar events](https://felixkratz.github.io/SketchyBar/config/events) defines `display_change` as active-display change. This does not establish delivery for every hotplug, rearrangement, or runtime target change. Its custom notification bridge uses `NSDistributedNotificationCenter`.
- Apple's [screen-parameters notification](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification.md) reports display-configuration changes through `NSApplication`. Do not assume that this application notification works through SketchyBar's distributed-notification bridge.
- Apple's [auxiliary top-right area](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytoprightarea-gr2n.md) uses global screen coordinates. It describes extra unobscured space beside the camera housing.
- Apple's [safe-area insets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets.md) describe camera-housing clearance. They do not establish native menu-bar height.
- Apple's [visible frame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe.md) excludes occupied menu/Dock areas and depends on current UI settings. Apple says not to cache it. Probe its fullscreen and multi-display behavior before deriving clearance.
- [Apple's Menu Bar settings](https://support.apple.com/guide/mac-help/change-menu-bar-settings-mchlad96d366/mac) defines four hide modes. `In Full Screen Only` hides the menu bar during fullscreen use.
- Apple's [presentation options](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.property.md) apply while the owning app is active. They are not a documented persistent global-preference setter.

## Preference candidates, not implementation contracts

A [macOS 15.5 administration report](https://www.alansiu.net/2025/06/30/managing-hiding-the-menu-bar-in-macos/) maps fullscreen-only hiding to two false booleans in global preferences, `_HIHideMenuBar` and `AppleMenuBarVisibleInFullscreen`. The report warns that direct writes may require reboot. This secondary source supplies T2 probe candidates, not proof for the guest OS or host.

## Requirements for the next probes

1. Keep three display states, confirmed notch, confirmed no notch, and unknown. Never restore on unknown data. This follows smart-menu V3 and V10.
2. Save exact prior preference presence and type before writes. Test deletion-based restoration for initially absent keys. This follows V5, V6, and I.system.
3. Verify effective desktop and fullscreen behavior, not only stored values or Settings text. This follows V2.
4. Measure actual native-menu clearance and both offset properties. Do not promote the temporary host value of 28 into a default. This follows V8 and I.bar.
5. Prove event delivery, reload ordering, and display targeting before choosing the event owner. This follows V7 and I.events.
6. Resolve the global preference policy for multiple target displays before implementation. This follows V12.

T1 introduces no runtime behavior, so its verification is source inspection and the cited documentation. Product tests remain unchanged.
