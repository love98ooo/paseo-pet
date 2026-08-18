# Paseo Pet — Design

Paseo Pet is a native macOS companion for Paseo. It renders a Codex-compatible pet in a transparent always-on-top window and reflects live agent state from the local Paseo daemon.

## Architecture

```text
AppDelegate
├── PetWindow
│   └── SpriteView
├── MessagePanelWindow
│   └── PetMessagePanelView (SwiftUI hosted in AppKit)
├── QuickChatWindow
├── SpriteEngine
├── LookTracker
└── DaemonConnection ── WebSocket ── Paseo daemon
```

The app uses Apple frameworks only: AppKit, SwiftUI, Foundation, QuartzCore, CoreGraphics, and Security.

## Data flow

`DaemonConnection` connects to `ws://localhost:6767/ws`, performs the Paseo hello handshake, subscribes to active agents, and maps updates into three UI channels:

- Agent lifecycle → aggregate pet animation and per-session message bubble
- Tool timeline → one in-place activity bubble
- Permission requests → actionable waiting bubble

All session RPCs use the Paseo session envelope. The daemon password comes from `PASEO_PASSWORD` or macOS Keychain.

## Pet animation

`PetCatalog` scans `~/.codex/pets/`. Spritesheets use eight columns and either nine rows (v1) or eleven rows (v2). `SpriteEngine` maps idle, running, waiting, failed, review, hover, and drag states to sprite rows.

Non-idle animations play three times before entering slow idle. V2 pets use rows 9–10 for cursor look direction.

## Windows

### PetWindow

A transparent borderless `.statusBar` window containing the sprite. It persists its screen position, supports drag direction animation, and applies release motion after a fast drag.

Clicking the pet activates Paseo. Clicking a session bubble opens the existing Paseo agent deep link:

```text
paseo://h/<serverId>/agent/<agentId>
```

### MessagePanelWindow

A non-activating transparent panel anchored above the pet. Its UI is adapted from OpenPetsKit under the MIT License.

- Four visible messages; older messages remain in the active count
- Stable thread IDs update bubbles in place
- Expanded by default
- 34px toggle collapses without deleting messages
- A new update temporarily reveals a collapsed stack for five seconds
- Session, activity, permission, first-awake, and expiration state share one panel

Permission actions remain visible. Running session actions appear on hover. Transparent panel areas do not intentionally add controls.

### QuickChatWindow

A compact text field below the pet. It sends to the most recently active Paseo agent.

## State mapping

| Paseo state | Pet animation | Bubble indicator |
|---|---|---|
| running | running | working spinner |
| pending permission | waiting | orange clock |
| error | failed | red x |
| requires attention | review | purple eye |
| idle / closed | idle | removed |

Pet animation uses the highest-priority active session: waiting, failed, running, review, idle.

## Persistence

- Pet position, size, and first-awake state: `UserDefaults`
- Daemon password: macOS Keychain

## Security

- The default WebSocket target is localhost.
- Credentials are not written to project files or logs.
- Pet assets are read from `~/.codex/pets/`.
- No telemetry or updater is included.
