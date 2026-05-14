# Talkeo — Windows

Native Windows 11 implementation of Talkeo. **Not started yet.**

## Planned stack

- **WinUI 3** (modern native Windows UI framework)
- **C# / .NET 8+**
- **UI Automation API** for text selection (Windows equivalent of macOS Accessibility API)
- **`SetWindowsHookEx`** via P/Invoke for global keyboard/mouse hooks
- **NotifyIcon** for system tray

## Why this stack

- Native (matches the macOS Swift+AppKit approach in spirit).
- Modern, actively maintained by Microsoft (unlike WPF / Win32).
- Friendly enough not to shoot ourselves in the foot (unlike raw Win32 / C++).
- Good interop with the rest of the .NET ecosystem (HTTP, JSON, SQLite, etc.).

## Status

See [ROADMAP.md](../../ROADMAP.md) v0.3.

First milestone: skeleton WinUI 3 project + text selection detection via UI Automation. Pick up the issue if you want to contribute.

## Shared with macOS

- API contracts for providers (LLM / TTS / STT) — see [`shared/api-contract/`](../../shared/api-contract/).
- System prompts — see [`shared/prompts/`](../../shared/prompts/).
- Design tokens / UX conventions — see [`shared/design/`](../../shared/design/).

**No code is shared across platforms.** Each platform implements the same UX natively.
