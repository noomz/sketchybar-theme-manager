# Smart menu-bar ownership and recovery design

Preliminary T4 design, not an approved implementation contract. T3 physical-click verification remains incomplete. The user approved probe work followed by design, not product implementation. This document does not amend SPEC.md.

## Evidence that constrains the design

- [T1](smart-menu-bar-t1.md): `y_offset` has existing user meaning. Layout generation and reload remain owned by stm; user config files are not automatic write targets.
- [T2](smart-menu-bar-t2.md): two global boolean preferences control the tested guest modes. Absent values need absence-preserving restoration. Successful writes and Settings text do not prove effective behavior.
- [T3](smart-menu-bar-t3.md): display topology and focus changes emit `display_change`; runtime bar retargeting does not. Reload requires initial reconciliation.
- T3 shows unequal per-display automatic clearance. One global offset can clear a secondary while adding excess primary space. `notch_offset` is implemented for built-in displays, not confirmed notches.
- The physical host's old workaround added 28 to an automatic 31, putting selectors at y=59. The user removed that workaround. Current runtime baseline is 0 and selector y=31. Never reuse historical 28 as its current baseline.
- Physical-notch clicks were delivered 7 of 7 once no app window covered the bar. When `topmost=off`, the bar sits at layer -20, so any overlapping app window takes its clicks. Clearance below the native menu is necessary but not sufficient.

## Compare command ownership

| Candidate | What owns reconciliation | Limit |
| --- | --- | --- |
| Event-driven, no daemon | A trusted installed hook calls stm at startup/reload and supported bar events; explicit refresh handles silent retargeting. | Cannot promise immediate detection of arbitrary external runtime target changes. Hook installation and lifecycle still need an approved interface. |
| Dedicated observer | A persistent process observes display configuration and bar state. | Additional lifecycle, cleanup, and recovery. Silent retargeting still needs a demonstrated event or explicit polling policy. Not justified by current evidence. |

Prefer no daemon if an explicit refresh requirement for external retargeting is acceptable. Do not silently add polling to fill the event gap. Do not make the optional compact bundle the system-preference owner: menu-bar protection must not disappear when compact is removed, nor give compact ownership of global settings.

The interface remains proposed `[menu_bar] smart_notch = "on" | "off"`. The command and trusted-hook installation shape must be approved before code. No palette field may enable it.

## State model

Represent observation separately from ownership. A failed display query is `unknown`, not `no notch`.

```text
Observation
  topology: confirmed | unknown
  targets: confirmed target identities and geometry
  notch per target: confirmed-notch | confirmed-no-notch | unknown
  bar: position, actual bounds, base offset, fullscreen behavior
  preference per key: absent | boolean(value) | unsupported | unreadable

Session
  version, generation
  phase: prepared | applying | active | restoring | conflict | recovery-required
  resources:
    each preference key and each managed bar property:
      exact original presence/type/value
      intended value
      last verified applied value, if any
      ownership: unchanged | applied | conflict | uncertain
  last confirmed target identities
```

Keep the schema closed and data-only. Refuse unsupported schema versions, symlinks, invalid types, or unsafe state paths. Do not evaluate state as shell code. The durable state location and schema are design proposals, not new runtime artifacts in this change.

## Reconciliation contract

```text
observe -> decide(observation, session, explicit intent) -> plan
persist recovery journal -> apply owned changes -> verify effective result
persist verified ownership -> report status
```

`decide` should be pure and testable with sandbox fixtures. Plans list exact resource changes, expected current values, originals, and compensation. No write happens during observation or planning.

1. Serialize stm writers for this user's global preference resource. Observe state again after acquiring ownership; do not apply stale pre-lock decisions.
2. Persist original state and write intent before the first external mutation. Retried events must not replace the first original snapshot.
3. Re-read each resource immediately before writing. If its value differs from the plan's expected current value, record conflict and preserve it.
4. Apply only the difference needed. Verify stored preference types and effective native/bar behavior separately.
5. Persist the verified applied value after each resource. A crash between write and verification leaves `uncertain`, not proof of ownership.
6. On failure, compensate only resources whose ownership is established. Retain state and report exact recovery needs when compensation cannot be verified.
7. On disable or confirmed no-notch policy transition, restore only resources still matching the last verified applied value. A conflict blocks automatic reacquisition until explicit user consent.

A local writer lock cannot serialize System Settings or third-party tools. Immediate re-read reduces but does not eliminate that external race. A user setting the same observable value is also indistinguishable from no change. Approval must acknowledge these limits; do not promise perfect attribution from value equality alone.

A stock-macOS locking design still needs crash tests, including partial lock initialization and PID reuse. Do not auto-delete an ambiguous lock or discard recovery state merely because the owning command exited.

## Offset policy must avoid double clearance

Compute additional clearance from actual placement and the user's base offset, not from a fixed 28, 32, or 34. Preserve `topmost`, bar position, fullscreen behavior, and existing layout intent.

For an owned global offset delta, the candidate calculation is:

```text
baseline_top = observed_top - owned_offset_delta
needed_delta = max(0, measured_required_top - baseline_top)
target_offset = original_base_offset + needed_delta
```

This is a hypothesis to validate, not a physical-notch solution already proved. Changes in native automatic placement must trigger a new observation. Never add `needed_delta` repeatedly to the already-managed offset. Never restore on unknown geometry or infer a notch solely from built-in status.

For multiple targets, one global offset cannot guarantee individually minimal spacing. Candidate policies are either maximum required clearance across managed targets, accepting extra space elsewhere, or refusing unsupported mixed geometry. There is no verified per-display offset mechanism in this design. Do not hide that trade-off behind `notch_offset`.

Bottom-position bars need an explicit opt-out policy. The current draft requires preserving their behavior; a top-menu fix must not move them as a side effect.

## Policy decisions

The user approved these on 2026-11-01:

1. Global menu preference: manage "In Full Screen Only" only while at least one confirmed notched target has a top-position bar. When no target needs it, restore the preference, but only if stm still owns it. Bottom-position bars are out of scope: stm never changes the preference or the offset for them.
2. Mixed-target geometry: use the maximum clearance that any managed target needs. Other displays get extra space as a result. Status must report this trade-off.
3. Silent runtime retargeting: no daemon and no polling. stm reconciles at startup and reload, and on `display_change` and `system_woke`. A documented explicit refresh command handles manual retargeting.

## Approval still needed before implementation

1. The public status, refresh, disable and recovery command names; how the trusted hook is installed; and the durable state schema.

The scratch-item probe permission does not authorize any global-preference write on the host.
