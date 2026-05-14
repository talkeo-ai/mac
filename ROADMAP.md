# Talkeo — Roadmap

> Source of truth for what we're building and why. Items are intent, not promises.

## The problem we solve

Reading, writing, and listening in a non-native language create constant friction. You stop, switch tabs, paste into a translator, copy back, lose flow. AI tools that work on **selected text, in any app** eliminate this friction.

Talkeo is the native popup that does this — translate, improve, define, pronounce — without leaving the app you're in. Free with your own provider API keys. Optionally paid (Talkeo Cloud, future) for zero-config and curated providers.

## v0.1 — MVP (current sprint, ship target 17-18 May 2026)

**Goal:** Core text actions working with BYO providers, on macOS, with a Settings panel and a Talkeo Cloud waitlist signup.

- [x] Text selection detection on macOS (Accessibility API + clipboard fallback)
- [x] Floating tooltip UI
- [ ] Provider protocol layer (`LLMProvider`, `TTSProvider`) — provider-neutral by design
- [ ] At least one BYO LLM provider implementation (specific provider TBD; architecture supports any)
- [ ] At least one BYO TTS provider implementation
- [ ] Core actions: Translate, Improve, Define, Pronounce
- [ ] Settings panel (configure providers, manage keys, voice IDs, models)
- [ ] Settings persisted to `~/.config/talkeo.json` (`schema_version: 1`)
- [ ] Talkeo Cloud waitlist signup (in-app email capture; backend = simple form service)
- [ ] OSS foundation (LICENSE, README, CONTRIBUTING, this ROADMAP, CHANGELOG, issue/PR templates)
- [ ] Public GitHub repo

## v0.2 — Talkeo Cloud

**Goal:** Optional paid zero-config experience. Users sign in with a Talkeo account, get curated LLM/TTS/voices without configuring keys. BYO remains fully functional and first-class.

- [ ] Talkeo Cloud backend (separate repo): router + voice catalog + auth + billing + streaming pass-through
- [ ] `TalkeoCloudProvider` implementations (LLM, TTS, STT) inside the client
- [ ] Login flow + free credits tier
- [ ] Paid subscription tier
- [ ] UI provider switcher (BYO ↔ Talkeo Cloud, per capability)

## v0.3 — Direction TBD: pick one when v0.2 ships

Two candidate directions, decide based on v0.2 traction + user feedback:

- **Global subtitles overlay** (likely — most aligned with the daily-use vision). System audio capture + real-time transcription + click-to-translate. Watch any content, activate subtitles only when needed, translate specific words on demand, or full L1 fallback.
- **Personalized teacher / forced practice.** Speaking + reading practice sessions driven by accumulated usage data (which words you looked up, which phrasings you struggled with). Forces practice on actual weak spots, not random vocabulary.

## Beyond

- Custom user-defined actions
- Linux port (community-driven, see below)
- Whatever the data flywheel + user feedback surfaces

## Cross-platform strategy

- **macOS = source of truth** for UX and architecture decisions.
- **Windows is built in parallel with macOS, not after.** Contributors own the Windows implementation under `apps/windows/` (WinUI 3 + C# planned). Maintainer (@realjoaquinalvarez) tests and reviews but does not write the Windows code.
- **Linux:** no roadmap commitment from the maintainer. Community proposals welcome — open an issue describing your approach (GTK4 / Qt / Electron / whatever) before starting work.

## Conventions

- Each version has a **named Goal**, not just a feature list.
- Items map to GitHub issues with labels (`good first issue`, `help wanted`, `area: macos / windows / providers / ui / cloud`).
- This roadmap can change. We commit to direction, not specific dates.
- PRs reference roadmap items (`Fixes #N`).
