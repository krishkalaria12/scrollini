# macOS Window Management Investigation

Date: 2026-05-03
Machine tested: macOS 26.4.1, Swift 6.3, arm64

## Goal

Explore whether this project can provide a Niri/PaperWM-style sliding or
scrollable tiling window manager on macOS, preferably with public APIs, and
identify where private WindowServer/SkyLight APIs would help.

## Short Answer

It is feasible to build a user-facing Niri-like window manager on macOS, but
not as a real compositor or replacement window manager. The practical approach
is:

1. Keep a virtual layout model of windows, workspaces, columns, and scroll
   offsets.
2. Observe windows with Accessibility and Workspace notifications.
3. Move and resize third-party windows with Accessibility attributes.
4. Emulate the infinite strip by moving windows relative to the viewport.
5. Keep hidden windows as thin edge slivers because macOS constrains or
   relocates fully offscreen windows.
6. Use private SkyLight only for optional improvements, not for the core path.

## Public API Surface

The best public API stack is:

- Accessibility:
  - `AXIsProcessTrustedWithOptions` to request/check permission.
  - `AXUIElementCreateApplication` and `kAXWindowsAttribute` to discover app
    windows.
  - `kAXPositionAttribute` and `kAXSizeAttribute` to read/move/resize windows.
  - `AXUIElementSetAttributeValue` to apply movement and sizing.
  - `AXObserverCreate` plus AX notifications for window lifecycle/focus/move.
  - `kAXRaiseAction` to raise windows.
- Quartz Window Services:
  - `CGWindowListCopyWindowInfo` to enumerate WindowServer windows and read
    bounds/owner/window IDs. This is good for reconciliation and filtering, but
    not enough by itself to manage windows.
- AppKit/Workspace:
  - `NSWorkspace` notifications for app launch/termination/hide/unhide and
    active space changes.
- Input:
  - `CGEventTapCreate` for global keybindings, trackpad scrolling, and
    interceptable gestures.
  - `NSEvent.addGlobalMonitorForEvents` is easier but passive; it cannot block
    or rewrite events.

Apple references:

- `AXUIElementSetAttributeValue`: https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue
- `AXIsProcessTrustedWithOptions`: https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
- `kAXPositionAttribute`: https://developer.apple.com/documentation/applicationservices/kaxpositionattribute
- `kAXSizeAttribute`: https://developer.apple.com/documentation/applicationservices/kaxsizeattribute
- `kAXWindowsAttribute`: https://developer.apple.com/documentation/applicationservices/kaxwindowsattribute
- `AXObserverCreate`: https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate
- `CGWindowListCopyWindowInfo`: https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29
- `CGEventTapCreate`: https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29
- `NSEvent.addGlobalMonitorForEvents`: https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29

## Local Proof

This Terminal process already has Accessibility trust:

```text
AX trusted: true
```

`CGWindowListCopyWindowInfo` can enumerate visible WindowServer windows. A
sample run saw 17 windows, including regular app windows and menu bar/control
center windows.

Accessibility can see and control normal app windows. On this machine,
`kAXPositionAttribute` and `kAXSizeAttribute` were settable for several regular
third-party app windows.

A reversible one-pixel move on a regular terminal window succeeded:

```text
original=(0.0, 29.0)
shiftedObserved=(1.0, 29.0)
setErr=0
restoreErr=0
```

Offscreen behavior is constrained:

```text
original=(0.0, 29.0) size=(1280.0, 803.0)
offRight requested x=1400 -> observed x=1240
offLeft requested x=-900 -> observed x=-900
down requested y=1000 -> observed y=800
up requested y=-500 -> observed y=29
```

Interpretation: public Accessibility movement works, but macOS tries to keep
some part of a window reachable. A scrollable manager cannot rely on arbitrary
fully offscreen placement. It should keep hidden windows as visible slivers,
or hide/minimize them and restore their position when needed.

## Private API Surface

SkyLight/WindowServer private symbols exist on macOS 26.4.1 in the dyld shared
cache. Relevant exported names include:

- `_SLSMainConnectionID`
- `_SLSMoveWindow`
- `_SLSMoveWindowList`
- `_SLSOrderWindow`
- `_SLSSetWindowTransform`
- `_SLSGetWindowTransform`
- `_SLSGetWindowBounds`
- `_SLSCopyWindowsWithOptionsAndTags`
- `_SLSCopySpaces`
- `_SLSCopySpacesForWindows`
- `_SLSManagedDisplayGetCurrentSpace`
- `_SLSManagedDisplaySetCurrentSpace`
- `_SLSAddWindowsToSpaces`
- `_SLSRemoveWindowsFromSpaces`
- `_SLSMoveWindowsToManagedSpace`
- `_SLSSpaceCreate`
- `_SLSSpaceDestroy`
- `_SLSSpaceSetTransform`
- `_SLSSpaceGetTransform`
- `_SLSSpaceSetAlpha`
- `_SLSSpaceSetShape`

There are also Objective-C classes named like
`SLSBridgedSpaceSetTransformOperation`,
`SLSBridgedMoveWindowsToManagedSpaceOperation`, and
`SLSBridgedCopyWindowsWithOptionsAndTagsOperation`.

These are useful evidence, but they are not a stable product foundation. They
can break across macOS releases, can complicate signing/notarization, and are
not App Store-compatible. The best use is an optional feature module, gated by
OS-version checks and runtime symbol lookup.

## Existing Precedents

Niri itself arranges windows in columns on an infinite strip and keeps
monitors independent:

- https://github.com/niri-wm/niri

macOS precedents:

- PaperWM.spoon: Hammerspoon/Lua implementation of tiled scrollable window
  management for macOS.
  https://github.com/mogenson/PaperWM.spoon
- Paneru: Rust implementation of a Niri-like sliding strip for macOS.
  https://github.com/karinushka/paneru
- AeroSpace: Swift/i3-style manager that intentionally emulates its own
  workspaces rather than relying on native Spaces.
  https://github.com/nikitabobko/AeroSpace

Paneru is the closest architectural reference. Its own docs explicitly call out
the same macOS limitation: windows are moved offscreen, but macOS can forcibly
relocate fully offscreen windows, so Paneru keeps a thin visible sliver.

## Recommended Architecture

Use a native Swift or Rust daemon/app. Swift fits macOS APIs naturally; Rust is
also viable with `objc2`, but FFI work is heavier. For a user-facing app, a
Swift core with a menu bar UI is the lowest-friction path unless this project
has strong Rust goals.

Core pieces:

- `WindowIdentity`
  - pid, bundle id, AX element, CG window id if available, title, role/subrole.
- `WindowObserver`
  - `NSWorkspace` app lifecycle notifications.
  - one `AXObserver` per app.
  - reconciliation pass using `CGWindowListCopyWindowInfo`.
- `WindowController`
  - public Accessibility move/resize/focus/raise operations.
  - retry and timeout handling for transient `kAXErrorCannotComplete`.
- `LayoutModel`
  - monitors, workspaces, strips, columns, tabs/stacks, floating exceptions.
  - pure layout math independent from macOS APIs.
- `ViewportProjector`
  - converts virtual coordinates into screen coordinates.
  - applies sliver policy for windows outside the visible viewport.
- `InputController`
  - event tap for keybindings and trackpad scroll gestures.
  - modal command layer similar to tiling WMs.
- `PolicyEngine`
  - app/window rules, ignored roles/subroles, dialogs/floating windows,
    native fullscreen handling.
- `Persistence`
  - restore layout across restarts based on bundle id, pid/session, title, and
    CG window id when available.

Do not start by manipulating native macOS Spaces with private APIs. Treat macOS
Spaces as broad containers and build the Niri-like strip inside the current
Space. Later, an optional SkyLight adapter can add faster space/window-id
queries or inactive-space support.

## Product Constraints

- Requires Accessibility permission.
- Event interception for keybindings/gestures requires Accessibility trust; some
  input monitoring can also involve Input Monitoring depending on packaging and
  event types.
- Screen Recording may be needed if we want window thumbnails/previews, but it
  is not needed for basic tiling.
- Some windows cannot be resized freely or expose incomplete AX metadata.
- Native fullscreen windows are special Spaces and should probably be excluded
  or managed as their own mode.
- Stage Manager, Mission Control, and Display arrangement can fight us.
- Multi-monitor horizontal arrangements are risky for hidden offscreen windows;
  sliver policy and display ownership checks are required.

## Proposed First Build

1. Build a minimal menu bar app/daemon with Accessibility permission flow.
2. Enumerate regular windows and filter out system UI, desktop, panels, sheets,
   menus, and unmanaged roles.
3. Implement a single-display horizontal strip:
   - two or three columns,
   - focus left/right,
   - move focused window left/right,
   - scroll strip left/right,
   - edge slivers for offscreen columns.
4. Add AXObserver updates for new/destroyed/moved/resized windows.
5. Add config and rules after the core loop is stable.

This should be built as public-API-first. Private SkyLight should remain behind
an adapter boundary so the project does not depend on it to boot.
