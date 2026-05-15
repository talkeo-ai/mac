# Talkeo — Windows

Native Windows 11 implementation of Talkeo. Mirrors the macOS MVP behavior:
detect text selection in any app, pop a floating tooltip with action buttons.

## Stack

- **WinUI 3** on the Windows App SDK (1.5)
- **C# / .NET 8** (`net8.0-windows10.0.19041.0`)
- **UI Automation API** for reading selected text from the focused element
- **`SetWindowsHookEx` (WH_MOUSE_LL)** for the global mouse-up gesture
- **H.NotifyIcon.WinUI** for the system tray icon

The project is **unpackaged** (`WindowsPackageType=None`), so it builds and
runs straight from `dotnet` without MSIX provisioning.

## Layout

```
apps/windows/
├── Talkeo.sln
└── Talkeo/
    ├── Talkeo.csproj
    ├── app.manifest                  # per-monitor DPI + asInvoker
    ├── Program.cs                    # WinUI XAML application entrypoint
    ├── App.xaml(.cs)                 # wires hook → reader → tooltip + tray
    ├── Interop/NativeMethods.cs      # P/Invoke for hook + DPI helpers
    ├── Selection/MouseHook.cs        # low-level mouse hook on its own thread
    ├── Selection/SelectionReader.cs  # UIA TextPattern.GetSelection
    ├── Tray/TrayIconService.cs       # H.NotifyIcon tray + Exit
    └── UI/TooltipWindow.xaml(.cs)    # borderless topmost tooltip
```

## Prerequisites

- Windows 10 1809 (10.0.17763) or newer — Windows 11 recommended
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- The **Windows App SDK** runtime is restored automatically via NuGet
- Visual Studio 2022 is optional; the command-line workflow below is enough

## Build

From the repo root:

```powershell
cd apps\windows\Talkeo
dotnet restore
dotnet build -c Debug -p:Platform=x64
```

## Run

```powershell
cd apps\windows\Talkeo
dotnet run -c Debug -p:Platform=x64
```

You should see:

1. A Talkeo icon appear in the system tray (right-click → **Exit Talkeo**).
2. Select text in any app (Notepad, Edge, Word, Code, …). When you release
   the mouse, a borderless tooltip pops near the cursor showing the captured
   text and four buttons: **Translate**, **Improve**, **Define**,
   **Pronounce**. The buttons currently log to the debug output — wiring to
   real providers is intentionally out of scope for this milestone.

If no tooltip appears, the focused control likely doesn't expose
`TextPattern` via UI Automation. A clipboard fallback (matching the macOS
implementation) is a planned follow-up.

## Notes for contributors

- The mouse hook runs on a dedicated STA thread with its own message pump
  so a slow UIA call cannot stall global input. Selection reads are
  dispatched off the hook thread via `ThreadPool.QueueUserWorkItem` and
  marshaled back to the UI dispatcher before showing the window.
- Cursor coordinates from `WH_MOUSE_LL` are physical pixels. The tooltip
  placement converts to logical units using `GetDpiForMonitor` so it lands
  correctly on per-monitor DPI setups.
- This milestone explicitly does **not** cover: auto-hide on outside click,
  real LLM/TTS providers, settings persistence, replace-in-place via UIA
  writes, or accessibility/onboarding prompts. Each has a follow-up issue.

## Shared with macOS

- API contracts for providers (LLM / TTS / STT) — see [`shared/api-contract/`](../../shared/api-contract/).
- System prompts — see [`shared/prompts/`](../../shared/prompts/).
- Design tokens / UX conventions — see [`shared/design/`](../../shared/design/).

**No code is shared across platforms.** Each platform implements the same UX natively.
