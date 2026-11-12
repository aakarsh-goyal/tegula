# Tegula

Automatic window tiling for macOS 15+. A native menu-bar app with a deliberately tiny footprint:
it is fully event-driven — no timers, no polling, nothing running while your windows sit still.

*Tegula* is the Latin word for a roof tile: pieces cut to fit, overlapping where they need to.

## Features

- **Four layouts** — Grid, Columns, Rows, Side — chosen per display. 1–4 windows per screen (5 on ultrawide);
  extra windows stack in a tile, with an optional tab strip to switch between them.
- **Glides, not jumps** — windows animate to their tiles (every frame applied, off the main thread).
- **Swap** windows with ⌘-drag, or ⌃⌥ + arrow; push past the screen edge to send a window to the next display.
- **Small monitor mode** (Settings, off by default): Columns and Rows hold two windows. A third window takes the tile of the least recently used one, which stacks behind it. In Rows, ⌃⌥← / ⌃⌥→ swap the two windows (up/down).
- **Maximize** the active window with ⌃⌥↩ (works even when tiling is paused); the other windows stay arranged in the active layout behind it. Press again, or ⌃⌥← / ⌃⌥→, to return to the layout.
- **Focus** — *Dim Others* (darken everything but the active window) or *No Peek* (blur and darken), both faded in softly. Switching windows crossfades; the dim steps aside for Mission Control, App Exposé, Show Desktop and native full screen, and returns gently afterwards.
- **Clean Space** hides apps that have no tiled window; **Setups (beta)** saves and restores app arrangements across displays.
- **Pause** with ⌃⌥T, exclude individual apps, floating for windows that can't shrink to fit (minimum sizes are learned).
- Window borders (active / all / glow), hover-to-activate, quick actions, configurable gaps and screen-edge space.
- Every shortcut is rebindable, with conflict detection against macOS and other apps.
- English, Spanish, Japanese, Korean, Simplified Chinese; light / dark / system theme; two app icons (Slate, Clay).

## Install

```sh
brew install --cask aakarsh-goyal/tegula/tegula
```

Apple silicon, macOS 15+. The app is ad-hoc signed (not notarized); the cask clears the download quarantine
flag so it opens normally. Grant Accessibility on first launch.

## Build from source

```sh
Scripts/build.sh            # → build/Tegula.app
Scripts/build.sh --install  # also copies it to /Applications
.build/release/Tegula --selftest-layout
```

Needs Swift 6 / the Xcode Command Line Tools only (no Xcode, no SwiftUI). On first launch grant **Accessibility**
access (System Settings › Privacy & Security › Accessibility); tiling starts immediately.

Diagnostics: `defaults write com.aakarsh.tegula debugLog -bool true` → `~/Library/Logs/Tegula.log`.

## How it stays light

| Mechanism | When it runs |
|---|---|
| Accessibility observers + workspace notifications | only when a window/app event actually happens |
| Global shortcuts (Carbon hotkeys) | OS delivers an event only for your exact key combos — no key logging, no Input Monitoring |
| Display link for the glide | created per animation, destroyed after; nothing per-frame when idle |
| Mouse-up / mouse-move / click-outside monitors | installed only during a drag / while hover-activate is on / while the panel is open |

## Privacy

Works offline. No screenshots, no keystroke logging, no window contents or titles stored.
Accessibility access is used only to move and resize windows.

## License

MIT
