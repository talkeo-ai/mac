# Architecture

> Architectural conventions for the Talkeo Mac app. Ecosystem-wide context (Talkeo Cloud backend, GitHub org, provider strategy at the org level) lives in `ECOSYSTEM.md`.

## Overview

Talkeo for Mac is a native AI tutoring app with multiple feature modes (TalkeoSelect popup, Practice with Leo, History, Vocab review). It is implemented in Swift, SwiftUI, and AppKit. The app consumes the Talkeo Cloud backend via HTTPS for managed-provider scenarios; in self-hosted mode, it talks directly to user-configured providers.

## Provider model

The core abstraction is the **provider protocol**. Each capability (LLM, TTS, STT) has an interface. Implementations live behind it.

### Two modes of operation

**BYO providers (self-hosted, code public):**

- Concrete implementations that talk directly to a provider's API using a user-supplied key.
- Each adapter declares its own descriptor (id, label, required fields) at registration time.
- This repo ships one or two reference adapters as examples (educational, contributors can model their own after these).
- Users see and pick the actual provider plus model/voice id. Transparency.

**Talkeo Cloud (managed, routing private):**

- The app implements a `TalkeoCloudProvider` that calls `api.talkeo.cloud` over HTTPS, versioned as `/v1/...`.
- Server-side, Talkeo Cloud routes requests to underlying external providers through a private Gateway. **Which providers are used, in what combination, with what fallback chain, none of this is visible in the app or in the public backend code.** It lives in a private `talkeo-ai/gateway` repository. See `ECOSYSTEM.md`.
- Users see "Talkeo Cloud" as a single provider option. They do not see what underlying providers are used behind the scenes.

### Implications

- UI and action logic talk only to the protocol, never to a concrete provider implementation.
- Swapping providers (BYO vs Talkeo Cloud, or between BYO options) is a runtime decision based on user settings.
- Adding a new BYO provider equals new adapter plus descriptor registration. No changes to UI or action logic.
- `TalkeoCloudProvider` is structurally indistinguishable from BYO adapters from the app's perspective. Just another implementation of the same protocol.
- Users can mix: BYO for LLM, Talkeo Cloud for TTS, or any combination per capability.
- **The app must never expose, log, or signal which underlying providers Talkeo Cloud uses internally.** Even if a contributor adds debug logging in a BYO adapter, that's fine (it's their own provider). But never add code that would leak Talkeo Cloud's internal provider choices.

## Settings

Persistent settings live in `~/.config/talkeo.json` (gitignored, never in code).

The file always carries a `schema_version` field. When the schema changes, a migration runs on load.

```json
{
  "schema_version": 1,
  "providers": {
    "llm": { "type": "<provider_id>", "api_key": "...", "model": "..." },
    "tts": { "type": "<provider_id>", "api_key": "...", "voice_id": "..." }
  },
  "talkeo_cloud": {
    "enabled": false,
    "token": null,
    "waitlist_signed": false
  }
}
```

`<provider_id>` is whichever provider id the user selected (BYO adapters declare their own ids when registered; `talkeo_cloud` is reserved for the Talkeo Cloud client).

API keys never leave the local machine unless explicitly used by a BYO adapter's HTTP call or the Talkeo Cloud auth flow.

## BYO and Talkeo Cloud coexistence (non-negotiable)

1. **BYO is first-class always.** Talkeo Cloud is opt-in convenience, never lock-in.
2. **UI switcher:** dropdown per capability. User picks BYO provider or Talkeo Cloud independently per LLM/TTS/STT.
3. **Talkeo Cloud abstracts internals.** Users see "Talkeo Cloud" as a single option. They do not see (and the code does not reveal) what underlying providers are routed to server-side. Talkeo may swap or recombine these freely.
4. **BYO names providers explicitly.** Users see and pick the actual provider plus model/voice id. Transparency for the BYO mode.
5. **No degradation on switch.** Core functionality works identically regardless of provider choice.

## Versioning of the Talkeo Cloud API

The Talkeo Cloud HTTP API is versioned in the URL: `/v1/llm/complete`, `/v1/tts/synthesize`, etc.

`v1` is preserved once distributed clients exist in the wild. Breaking changes go to `v2`, with `v1` maintained until clients have migrated.

This versioning enables backend migrations (for example, the current fly.io to AWS migration documented in `ECOSYSTEM.md`) without breaking deployed clients.

## Storage

Local storage (SQLite or equivalent) holds:

- User queries (text selected, action invoked, result, timestamp).
- Provider used per query (BYO adapter id or `talkeo_cloud`).

This is the foundation for future personalization features (forced practice on captured weak areas, vocabulary tracking, spaced repetition).

When the user is logged into Talkeo Cloud, captured selections are also synced to the Cloud's `selections` table (server-side) for use in practice session generation. Local SQLite remains the source of truth for offline use.

## App surfaces and activation

Talkeo for Mac is a **foreground app with two persistent surfaces**, both always present from launch:

1. **Dock icon.** The "real" app entry point. Clicking it brings the main window to the front.
2. **Status bar (menubar) icon.** Always visible. Owns its own configuration menu (settings, provider switch, quit), independent of the main window.

This is the Claude desktop / Slack / Discord pattern, not a background-only agent tool.

**Main window:** the user-facing destination opened by the Dock icon.

- v0.1 main window equals **Settings panel** (provider configuration, API keys, BYO vs Talkeo Cloud switch).
- v0.3 and beyond replaces this with the **Practice mode dashboard**, and Settings moves to a secondary window opened via the standard preferences shortcut (`Cmd+,`).

**Why both surfaces:** the TalkeoSelect popup mode (core daily-use) doesn't need a main window. It operates entirely through the floating panel triggered by text selection. But Practice mode (v0.3 and beyond) needs a real destination. Having both surfaces from v0.1 avoids a UX rupture later and matches user expectations for a real desktop app.

**Implementation notes:**

- `NSApp.setActivationPolicy(.regular)` plus status bar item via `NSStatusBar`.
- `Info.plist` must NOT set `LSUIElement`.
- `AppDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)` must show/focus the main window on Dock click.

## Feature modes inside the app

Talkeo is one app with multiple modes. Internal organization reflects this:

- `Sources/Talkeo/Features/Select/`, TalkeoSelect popup feature (current MVP).
- `Sources/Talkeo/Features/Practice/`, Practice mode with Leo (planned, v0.3).
- `Sources/Talkeo/Features/History/`, review past sessions (planned).
- `Sources/Talkeo/Features/Vocab/`, spaced repetition (planned).
- `Sources/Talkeo/Core/`, shared infrastructure (provider protocols, settings, storage, auth).

Each feature is a self-contained module. Cross-feature dependencies go through `Core/`. New features ship as new module folders; old features evolve in place.
