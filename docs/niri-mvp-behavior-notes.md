# Niri Behavior Notes for the Swift MVP

Niri commit inspected: `1f07cffa`

## Source Behavior

- Niri arranges windows in horizontal columns on an infinite strip; new windows
  do not resize existing windows. Workspaces are dynamic vertical rows per
  monitor, with an empty workspace at the bottom.
  [README.md lines 17-24](https://github.com/niri-wm/niri/blob/1f07cffa/README.md#L17-L24)

- Niri's default config binds horizontal focus to `Mod+H/L` and arrow keys.
  [default-config.kdl lines 403-410](https://github.com/niri-wm/niri/blob/1f07cffa/resources/default-config.kdl#L403-L410)

- Niri's workspace-up/down commands operate on the focused monitor's vertical
  workspace list.
  [default-config.kdl lines 459-466](https://github.com/niri-wm/niri/blob/1f07cffa/resources/default-config.kdl#L459-L466)

- Niri binds `Mod+1` through `Mod+9` to `focus-workspace 1..9`, and documents
  that indexes past the current workspace count clamp to the last, empty
  workspace.
  [default-config.kdl lines 509-525](https://github.com/niri-wm/niri/blob/1f07cffa/resources/default-config.kdl#L509-L525)

- Niri's workspace docs clarify that workspace indexes are dynamic positions,
  not stable identities.
  [Workspaces.md lines 32-40](https://github.com/niri-wm/niri/blob/1f07cffa/docs/wiki/Workspaces.md#L32-L40)

- The input action path calls layout focus methods directly for columns and
  workspaces.
  [input/mod.rs lines 1066-1092](https://github.com/niri-wm/niri/blob/1f07cffa/src/input/mod.rs#L1066-L1092)
  [input/mod.rs lines 1451-1474](https://github.com/niri-wm/niri/blob/1f07cffa/src/input/mod.rs#L1451-L1474)

- Column focus is a bounded active-column index change.
  [scrolling.rs lines 1551-1565](https://github.com/niri-wm/niri/blob/1f07cffa/src/layout/scrolling.rs#L1551-L1565)

- Workspace up/down is a bounded active-workspace index change; direct
  workspace index focus also clamps to the last workspace.
  [monitor.rs lines 978-1013](https://github.com/niri-wm/niri/blob/1f07cffa/src/layout/monitor.rs#L978-L1013)

- Adding a window to the bottom empty workspace creates another empty workspace
  below it; empty non-active middle workspaces are cleaned up.
  [monitor.rs lines 537-585](https://github.com/niri-wm/niri/blob/1f07cffa/src/layout/monitor.rs#L537-L585)
  [monitor.rs lines 625-640](https://github.com/niri-wm/niri/blob/1f07cffa/src/layout/monitor.rs#L625-L640)

## Sizing and Gestures

Niri commit inspected: `dd75865`

- A column's proportional width is `(working_width - gaps) * proportion - gaps`,
  so gaps are reserved space rather than a cosmetic inset and two `0.5` columns
  tile the working area exactly.
  [scrolling.rs lines 4532-4541](https://github.com/YaLTeR/niri/blob/dd75865/src/layout/scrolling.rs#L4532-L4541)

- Columns are laid out end to end with one gap between them: `x += width + gaps`.
  [scrolling.rs lines 2333-2346](https://github.com/YaLTeR/niri/blob/dd75865/src/layout/scrolling.rs#L2333-L2346)

- The width used to place columns is the *cached actual column width*, taken
  from each tile's expected-or-current size, not the configured proportion. A
  client that will not take the size it was offered widens its own column and
  the strip stays packed instead of opening a hole.
  [scrolling.rs lines 108-111](https://github.com/YaLTeR/niri/blob/dd75865/src/layout/scrolling.rs#L108-L111)
  [scrolling.rs lines 4843-4852](https://github.com/YaLTeR/niri/blob/dd75865/src/layout/scrolling.rs#L4843-L4852)

- Three-finger swipes are direction-locked. Niri accumulates the swipe until it
  passes a 16px threshold, then begins *either* the view-offset gesture when
  `|dx| > |dy|` *or* the workspace-switch gesture otherwise. Only the chosen
  gesture ever starts, so updates to the other axis are no-ops for the rest of
  the swipe.
  [input/mod.rs lines 3994-4030](https://github.com/YaLTeR/niri/blob/dd75865/src/input/mod.rs#L3994-L4030)

- The two axes are deliberately not equally sensitive: one workspace is 300
  units of touchpad travel, while one screen width of column scrolling is 1200.
  [monitor.rs line 37](https://github.com/YaLTeR/niri/blob/dd75865/src/layout/monitor.rs#L37)
  [scrolling.rs line 32](https://github.com/YaLTeR/niri/blob/dd75865/src/layout/scrolling.rs#L32)

## MVP Mapping

- `Ctrl+Opt+1..9`: focus dynamic workspace index, clamped to the last empty row.
- `Ctrl+Opt+Up/Down`: focus workspace up/down.
- `Ctrl+Opt+Left/Right`: focus column left/right.
- Niri owns the whole keyboard because it is the compositor. scrollini sits above the
  WindowServer instead, so it takes `Ctrl+Opt` rather than Niri's bare `Mod`, which on
  macOS would be Command and would collide with every app menu.
- Every managed window is a single full-screen-sized column.
- Column widths use Niri's proportional formula and gap packing directly.
- macOS cannot force a window to a size its app refuses, so scrollini measures what
  each window was actually granted after a layout settles and packs the strip
  against that, which is the same quantity Niri caches per column.
- An AX resize notification only counts as the user's intent when a mouse button
  is down for it. Everything else — an app clamping to a minimum size, a
  terminal snapping to a character cell — is recorded as a measurement and does
  not rewrite the column's configured width.
- Three-finger swipes take Niri's direction lock, including its asymmetric
  vertical sensitivity.
- The current workspace and column projects to the visible macOS frame.
- Other windows remain physically parked just past a side edge so Cmd-Tab can
  still find them and macOS does not relocate fully offscreen windows.
- On macOS, those parked windows are additionally hidden with
  `SLSSetWindowAlpha(0)` when SkyLight is available. The active window is
  restored to `SLSSetWindowAlpha(1)` before focus/raise, which avoids visible
  parked borders and reduces the brief horizontal flash when switching columns.
- Cmd-Tab is not intercepted. When macOS activates a window, the daemon adopts
  that window's stored row/column and reprojects.
- The daemon writes a restore snapshot and spawns `scrollini --cleanup-watch`.
  Normal signal exits restore every managed window to alpha `1` and the visible
  maximized frame directly. If the main process dies unexpectedly, the watcher
  uses the snapshot to do the same cleanup.
