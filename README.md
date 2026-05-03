<div align="center">

# scrollini

[![License](https://img.shields.io/badge/license-MIT-111111?style=flat-square)](./LICENSE)
[![GitHub](https://img.shields.io/badge/github-krishkalaria12%2Fscrollini-111111?style=flat-square&logo=github)](https://github.com/krishkalaria12/scrollini)
[![Ko-fi](https://img.shields.io/badge/ko--fi-krishkalaria12-111111?style=flat-square&logo=kofi)](https://ko-fi.com/krishkalaria12)

<img src="./assets/repo/scrollini-demo.gif" alt="scrollini macOS window layout preview" width="1000" />

_Niri-ish, keyboard-first window manager for macOS._

</div>

## Install

Build and run from source:

```bash
git clone https://github.com/krishkalaria12/scrollini.git
cd scrollini/apps/macos
swift run Scrollini
```

For a release build:

```bash
swift build -c release
.build/release/Scrollini
```

scrollini needs Accessibility permission, and the event tap may also need Input
Monitoring permission. If you run it from a terminal, macOS may ask for the
terminal app itself to get those permissions.

## What it does

- Keeps a Niri-like virtual layout of workspaces and columns on macOS.
- Tiles normal app windows with Accessibility APIs instead of acting as a
  compositor.
- Makes each column `0.8` screen widths by default, so the next column can peek
  in while you move sideways.
- Centers the focused column when possible, while keeping the first column
  pinned to the left edge.
- Tracks `Cmd+Tab`, app launches, app exits, manual window resizes, and focused
  windows so the model follows macOS instead of fighting it.
- Supports app rules for tiled, floating, and ignored windows.
- Parks off-workspace windows near the side edge, with optional SkyLight alpha
  hiding when those private symbols are available.
- Restores tiled windows on normal exit and starts a small cleanup watcher for
  crash or kill recovery.

## Shortcuts

| Shortcut | Action |
| :------- | :----- |
| `Cmd+1`..`Cmd+9` | Focus workspace by dynamic index |
| `Cmd+0` | Focus the previous workspace |
| `Cmd+J` / `Cmd+K` | Focus workspace down / up |
| `Cmd+H` / `Cmd+L` | Focus column left / right |
| `Cmd+[` / `Cmd+]` | Focus first / last column |
| `Cmd+Home` / `Cmd+End` | Focus first / last column |
| `Cmd+Shift+1`..`Cmd+Shift+9` | Move column to workspace |
| `Cmd+Shift+J` / `Cmd+Shift+K` | Move column workspace down / up |
| `Cmd+Shift+H` / `Cmd+Shift+L` | Move column left / right |
| `Cmd+Shift+[` / `Cmd+Shift+]` | Move column to first / last |
| `Cmd+Ctrl+H` / `Cmd+Ctrl+L` | Cycle active column width preset |
| `Cmd+Ctrl+-` / `Cmd+Ctrl+=` | Nudge active column width |
| `Cmd+Ctrl+Shift+H` / `Cmd+Ctrl+Shift+L` | Cycle every tiled window width preset |
| `Cmd+Ctrl+Shift+-` / `Cmd+Ctrl+Shift+=` | Nudge every tiled window width |
| three-finger trackpad swipe | Navigate columns / workspaces |

Everything else passes through. The default config excludes `Cmd+Shift+5`, so
macOS screen recording keeps working.

Trackpad navigation uses Apple's private MultitouchSupport framework so Scrollini can
see raw three-finger movement without stealing normal two-finger scrolling. It
moves a continuous camera with momentum, then focuses the workspace and column
nearest the camera when the motion settles.

## Config

scrollini loads the first config file it can read:

- `SCROLLINI_CONFIG`
- `./scrollini.config.json`
- `$XDG_CONFIG_HOME/scrollini/config.json`
- `~/.config/scrollini/config.json`

The repo includes this default:

```json
{
  "default_width_ratio": 0.8,
  "preset_width_ratios": [0.5, 0.67, 0.8, 1.0],
  "animation_duration_ms": 240,
  "hover_to_focus": true,
  "hover_focus_delay_ms": 120,
  "hover_focus_max_scroll_ratio": 0.15,
  "workspace_auto_back_and_forth": true,
  "center_focused_column": true,
  "excluded_keybindings": ["cmd+shift+5"],
  "trackpad_navigation": true,
  "trackpad_navigation_fingers": 3,
  "trackpad_navigation_sensitivity": 1.6,
  "trackpad_navigation_deceleration": 5.5,
  "trackpad_navigation_invert_x": false,
  "trackpad_navigation_invert_y": false,
  "rules": [
    {
      "bundle_id": "com.apple.finder",
      "behavior": "ignore"
    }
  ]
}
```

Rules can match on `bundle_id`, `app_name`, or `title_contains`. Use
`behavior: "ignore"` for windows scrollini should leave alone, `behavior: "float"`
for visible untiled windows, and `width_ratio` to override an app's default
column width.

## Development

```bash
swift build
swift run Scrollini
```

## Notes

- scrollini targets macOS 13+ and Swift 6.
- It uses public Accessibility APIs for the core window control path.
- The SkyLight path is private and optional; if it is unavailable, hidden
  windows stay parked as side-edge slivers.
- This does not use native macOS Spaces.

## Links

- Repository: https://github.com/krishkalaria12/scrollini
- Research notes: [docs/macos-window-management-investigation.md](docs/macos-window-management-investigation.md)
- Niri behavior notes: [docs/niri-mvp-behavior-notes.md](docs/niri-mvp-behavior-notes.md)
