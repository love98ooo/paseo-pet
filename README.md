# paseo-pet

A native macOS desktop companion for [Paseo](https://paseo.sh). It displays Codex pet sprites and mirrors live agent activity, permissions, and session state from a local Paseo daemon.

## Requirements

- macOS 13 or later
- Paseo desktop app or daemon running locally
- A Codex pet installed under `~/.codex/pets/`

## Run

```bash
swift run
```

By default, Paseo Pet connects to `ws://localhost:6767/ws`. Configure a different port with `PASEO_PORT`. The daemon password can be stored from the menu bar or supplied through `PASEO_PASSWORD`.

## Features

- Native AppKit/SwiftUI process with a transparent always-on-top window
- Codex v1/v2 spritesheets and v2 look-direction frames
- Agent-state animation and tool activity
- OpenPets-style stacked notifications with collapse/expand behavior
- Paseo permission actions and session deep links
- Pet selection, sizing, dragging, and position persistence

## Build

```bash
swift build
```

## License

Parts of the message-panel UI are adapted from [OpenPetsKit](https://github.com/alterhq/OpenPetsKit), distributed under the MIT License. See source-file notices for attribution.
