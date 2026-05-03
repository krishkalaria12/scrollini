# scrollini

A small macOS MVP for a Niri-like, keyboard-first window layout.

This is not a compositor. It uses macOS Accessibility APIs to resize and move
normal app windows into a virtual grid:

- Workspaces are rows.
- Windows are columns inside a workspace. By default each column is `0.8` of
  the screen width, so the next column can peek in while you scroll sideways.
- App rules can override column width ratios. A `1.0` ratio occupies the whole
  screen width; larger ratios are allowed and grow beyond the screen.
- App rules can also mark windows as `ignore` or `float`. Ignored windows are
  left alone. Floating windows are kept visible but are not tiled, resized,
  centered, parked, hidden, or moved between workspaces.
- Column navigation is animated by projecting the old and new virtual plane
  views and interpolating the managed window frames. Workspace up/down jumps
  immediately without vertical animation.
- Manually resizing a tiled window updates that window's live width ratio for
  the current session, then immediately reflows the rest of the row so columns
  remain adjacent. Resizing from the left preserves the dragged left edge on
  screen, so windows on the left can become visible too. Resize events are
  tracked as a short live session so fast drags do not lose the final width.
- `hover_to_focus` can focus a visible neighboring tiled column after the
  pointer rests on it, using the same animated projection as keyboard focus.
- Neighboring/off-workspace windows are parked just past the side edge so macOS
  does not forcibly relocate them, then hidden with SkyLight window alpha when
  available.

## Shortcuts

- `Cmd+1` ... `Cmd+9`: focus workspace by dynamic index. Indexes past the
  current count clamp to the bottom empty workspace, matching Niri's behavior.
- `Cmd+J`: workspace down.
- `Cmd+K`: workspace up.
- `Cmd+H`: column left.
- `Cmd+L`: column right.
- `Cmd+Shift+1` ... `Cmd+Shift+9`: move active column to workspace by
  dynamic index. Indexes past the current count clamp to the bottom empty
  workspace.
- `Cmd+Shift+J`: move active column to workspace down.
- `Cmd+Shift+K`: move active column to workspace up.
- `Cmd+Shift+H`: move active column left.
- `Cmd+Shift+L`: move active column right.

Everything else passes through. In particular, `Cmd+Tab` remains macOS app
switching; after macOS focuses a managed window, scrollini adopts that window's
stored workspace and column and reprojects the layout.

The alpha hiding path uses private SkyLight symbols. If those symbols are not
available on a macOS build, scrollini falls back to the side-edge parked placement.

On exit, scrollini restores tiled windows to alpha `1` and moves them to the visible
maximized frame. Floating windows are left in place with alpha `1`. It also
starts a small watcher process with a restore snapshot; if the main process
crashes or is killed, the watcher restores tiled windows to the same maximized
visible state.

## Config

scrollini loads the first config file it can read from:

- `SCROLLINI_CONFIG`
- `./scrollini.config.json`
- `$XDG_CONFIG_HOME/scrollini/config.json`, or `~/.config/scrollini/config.json`

The repo includes this default:

```json
{
  "default_width_ratio": 0.8,
  "animation_duration_ms": 180,
  "hover_to_focus": true,
  "hover_focus_delay_ms": 120,
  "rules": [
    {
      "bundle_id": "com.apple.finder",
      "behavior": "ignore"
    },
    {
      "bundle_id": "com.t3tools.t3code",
      "width_ratio": 1.0
    },
    {
      "app_name": "T3 Code (Nightly)",
      "width_ratio": 1.0
    },
    {
      "title_contains": "T3 Code",
      "width_ratio": 1.0
    }
  ]
}
```

The current T3 Code identifiers observed from running apps are:

- `T3 Code (Nightly)`: bundle id `com.t3tools.t3code`, title `T3 Code (Nightly)`
- `Electron`: bundle id `com.github.Electron`, title `T3 Code (Dev)`

## Run

```sh
swift run Scrollini
```

The process needs Accessibility permission. If launched from a terminal, macOS
may require the terminal app itself to have Accessibility access.
