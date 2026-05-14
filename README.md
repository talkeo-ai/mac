# Talkeo

Native popup AI assistant for selected text. Translate, improve, define, pronounce — without leaving the app you're in.

Open source (MIT). Free with your own API keys, or opt in to **Talkeo Cloud** for zero-config.

## Status

**v0.1 MVP** — text selection detection + tooltip working on macOS. AI actions in progress.

## Platforms

| Platform   | Status      | Stack                    | Path            |
| ---------- | ----------- | ------------------------ | --------------- |
| macOS 13+  | MVP working | Swift + SwiftUI + AppKit | `apps/macos/`   |
| Windows 11 | Planned     | WinUI 3 + C#             | `apps/windows/` |
| Linux      | Future      | TBD                      | —               |

## Quick start (macOS)

```bash
cd apps/macos
./scripts/build-app.sh
open ./Talkeo.app
```

macOS will request **Accessibility permission** on first launch. Approve it and restart the app (CGEventTap caches state per process).

See [`apps/macos/README.md`](./apps/macos/README.md) for details.

## How it works

1. Select text in any app.
2. A floating tooltip appears near the selection.
3. Choose an action: translate, improve, define, pronounce.
4. Result shown in-place. Optionally written back where you selected (replace-in-place).

Providers (LLM/TTS/STT) are pluggable. Bring your own keys (Groq, OpenAI, ElevenLabs, etc.) — or use Talkeo Cloud for zero-config (paid, optional).

## Providers

- **BYO (default, free):** configure your own API keys in `~/.config/talkeo.json`. Always first-class.
- **Talkeo Cloud (optional, paid):** login → free credits, paid tier for more. Zero-config, curated.

Switch between them anytime in the UI dropdown. No lock-in.

## Roadmap

See [ROADMAP.md](./ROADMAP.md). Issues with `good first issue` / `help wanted` labels welcome contributors.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Vibecoding welcome. Rigorous review required.

## License

MIT — see [LICENSE](./LICENSE).
