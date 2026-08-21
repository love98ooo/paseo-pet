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

The app uses Apple frameworks only: AppKit, SwiftUI, Foundation, QuartzCore, and CoreGraphics.

## Data flow

`DaemonConnection` connects to `ws://localhost:6767/ws`, performs the Paseo hello handshake, subscribes to active agents, and maps updates into three UI channels:

- Agent lifecycle → aggregate pet animation and per-session message bubble
- Tool timeline → one in-place activity bubble
- Permission requests → actionable waiting bubble

All session RPCs use the Paseo session envelope. The daemon password comes from non-empty `PASEO_PASSWORD` or the private local credential file.

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
- Three explicit states: collapsed (1), stacked (2), and expanded (3)
- The interaction button moves 1 → 2, 2 → 1, and 3 → 2; clicking a stacked message moves 2 → 3
- Hover only reveals in-card actions and never changes the stack state
- A collapsed stack stays hidden across updates while its badge and count continue to refresh
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
| requires attention | review | green check |
| idle / closed | idle | removed |

Pet animation uses the highest-priority active session: waiting, failed, running, review, idle.

## Persistence

- Pet position, size, and first-awake state: `UserDefaults`
- Daemon password: `~/Library/Application Support/PaseoPet/daemon-password` (`0700` parent directory, `0600` file)

## Security

- The default WebSocket target is localhost.
- Credentials are not written to project files or logs.
- The local credential file is readable only by the current macOS user account.
- Pet assets are read from `~/.codex/pets/`.
- No telemetry or updater is included.
