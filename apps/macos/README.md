# Talkeo for macOS

Native popup AI assistant on macOS — text selection detection + floating tooltip + AI actions.

> Swift target/module is still named `TalkeoSelect` pending rename to `Talkeo`. Build artifact below reflects current state.

## Requirements

- macOS 13+
- Xcode CLI tools (`swift --version` must work)

## Build & run

```bash
./scripts/build-app.sh
open ./TalkeoSelect.app   # rename to Talkeo.app pending
```

First launch:

1. Menu bar icon appears (`text.viewfinder`).
2. macOS prompts for **Accessibility** permission (needed for global CGEventTap + reading selected text via AX API).
3. Approve, quit, relaunch (CGEventTap caches state per process).

Test by selecting text in Safari, Notes, TextEdit. Tooltip appears on mouse-up.

## Architecture (Swift module)

```
Sources/TalkeoSelect/
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

- Electron/Chrome apps sometimes don't expose `kAXSelectedTextAttribute` → falls back to clipboard. Fallback restores previous pasteboard, but there's a ~120ms window where it briefly contains the selected text.
- Tooltip doesn't auto-hide on outside click yet.
- API keys are not persisted yet (planned: `~/.config/talkeo.json`).

## Permissions

- **Accessibility** (required) — event tap + AX read/write of selection.
- **Apple Events** (future, if needed).
- **Screen Recording** (future, for capture + OCR features).

## Roadmap

Platform-specific items are in the [top-level ROADMAP.md](../../ROADMAP.md). Tag them with `area: macos`.
