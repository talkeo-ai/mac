# Talkeo for Mac

Native macOS app for Talkeo. Includes the TalkeoSelect popup mode (AI on selected text in any app). More modes planned (practice with Leo, history, vocab review).

Part of the [Talkeo ecosystem](https://github.com/talkeo-ai).

## Status

**v0.1 MVP.** Text selection detection + floating tooltip working. AI actions in progress.

## Requirements

- macOS 13+
- Xcode CLI tools (`swift --version` must work)

## Build and run

```bash
./scripts/build-app.sh
open ./Talkeo.app
```

First launch:

1. Menu bar icon appears (`text.viewfinder`).
2. macOS prompts for **Accessibility** permission (needed for global CGEventTap and reading selected text via the AX API).
3. Approve, quit, relaunch (CGEventTap caches state per process).

Test by selecting text in Safari, Notes, TextEdit. Tooltip appears on mouse-up.

## How it works

1. Select text in any app.
2. A floating tooltip appears near the selection.
3. Choose an action: translate, improve, define, pronounce.
4. Result shown in place. Optionally written back where you selected (replace-in-place).

## Providers

Providers (LLM, TTS, STT) are pluggable through protocols. Two ways to use them:

- **Self-hosted (default, free):** configure your own API keys in `~/.config/talkeo.json`. Always first-class.
- **Talkeo Cloud (managed, paid):** Talkeo is your provider for everything (database, LLMs, voice, hosting). Zero config.

Switch between them anytime in the UI dropdown.

## Architecture (Swift module)

```
Sources/Talkeo/
├── main.swift                          # NSApplication entry
├── App/
│   ├── AppDelegate.swift               # permissions + monitor + tooltip orchestration
│   └── StatusBarController.swift       # menubar icon + menu
├── Permissions/
│   └── AccessibilityPermission.swift   # AXIsProcessTrustedWithOptions
├── Selection/
│   ├── MouseUpMonitor.swift            # CGEventTap (down/drag/up)
│   └── SelectionReader.swift           # AX path + clipboard fallback
└── UI/
    └── TooltipPanel.swift              # NSPanel + SwiftUI
```

**Flow:**

```
mouseDown → drag tracked → mouseUp (drag or double-click) →
NSEvent.mouseLocation + SelectionReader →
  ├─ AX: kAXSelectedTextAttribute of focused element
  └─ fallback: snapshot pasteboard → Cmd+C → read → restore pasteboard
→ TooltipPanel.show(text, near: anchor)
```

## Known limitations

- Electron/Chrome apps sometimes don't expose `kAXSelectedTextAttribute`, so the app falls back to clipboard. Fallback restores the previous pasteboard, but there's a ~120ms window where it briefly contains the selected text.
- Tooltip doesn't auto-hide on outside click yet.
- API keys are not persisted yet (planned: `~/.config/talkeo.json`).

## Permissions

- **Accessibility** (required) for event tap and AX read/write of selection.
- **Apple Events** (future, if needed).
- **Screen Recording** (future, for capture and OCR features).

## Roadmap

See [ROADMAP.md](./ROADMAP.md). For ecosystem-wide context (backend, GitHub org, sprint state), see [`docs/ECOSYSTEM.md`](./docs/ECOSYSTEM.md).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

MIT. See [LICENSE](./LICENSE).
