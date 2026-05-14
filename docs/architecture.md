# Architecture

> Cross-platform architectural conventions. Platform-specific details live in `apps/<platform>/`.

## Overview

Talkeo is a native popup AI assistant. Each platform implements the same UX in its native stack — no shared application code across platforms. What's shared:

- **API contracts** for providers (LLM / TTS / STT) — `shared/api-contract/`
- **System prompts** — `shared/prompts/`
- **Design tokens and UX conventions** — `shared/design/`

The shared specs prevent drift between platforms while letting each platform feel native.

## Provider model

The core abstraction is the **provider protocol**. Each capability (LLM, TTS, STT) has an interface. Implementations live behind it:

- **BYO providers** — concrete implementations that talk directly to a provider's API using a user-supplied key. Each provider declares its own descriptor (id, label, required fields) at registration time. New providers added by contributors register themselves the same way.
- **TalkeoCloudProvider** — paid, zero-config. Logs in with a Talkeo account, makes requests against `api.talkeo.cloud`. Provider name/model/voice details abstracted server-side.

UI and action logic talk only to the protocol, never to a concrete provider. Swapping providers is a runtime decision based on user settings.

This means:

- Adding a new BYO provider = new implementation + descriptor registration. No changes to UI or action logic.
- TalkeoCloudProvider is structurally indistinguishable from BYO providers — just another implementation of the same protocol.
- Users can mix: BYO provider for LLM, TalkeoCloud for TTS, or any combination.

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

`<provider_id>` is whichever provider id the user selected (BYO providers declare their own ids when registered; `talkeo_cloud` is reserved for the Talkeo Cloud client).

API keys never leave the local machine unless explicitly used by a BYO provider's HTTP call.

## BYO ↔ Talkeo Cloud coexistence (non-negotiable)

1. **BYO is first-class always.** Talkeo Cloud is opt-in convenience, never lock-in.
2. **UI switcher:** dropdown per capability. User picks BYO provider or Talkeo Cloud independently per LLM/TTS/STT.
3. **Talkeo Cloud abstracts internals.** Users see "Talkeo" as a brand. They don't see what underlying LLM / voice model we use behind the scenes (we may swap them freely server-side).
4. **BYO names providers explicitly.** Users see and pick the actual provider + model/voice id. Transparency.
5. **No degradation on switch.** Core functionality works identically regardless of provider choice.

## Versioning of the Talkeo Cloud API

The Talkeo Cloud HTTP API is versioned in the URL: `/v1/llm/complete`, `/v1/tts/synthesize`, etc.

We never break `v1` once distributed clients exist in the wild. Breaking changes go to `v2`, with `v1` maintained until clients have migrated.

## Storage

Local storage (SQLite) holds:

- User queries (text selected, action invoked, result, timestamp).
- Provider history (which provider was used per query).

This is the foundation for future personalization features (forced practice on captured weak areas, vocabulary tracking, etc.).

Storage is platform-agnostic at the schema level (`shared/`), platform-specific at the implementation level (`apps/<platform>/`).

## Per-platform implementation notes

Detailed engineering notes for each platform live in `apps/<platform>/CLAUDE.md` and `apps/<platform>/README.md`.
