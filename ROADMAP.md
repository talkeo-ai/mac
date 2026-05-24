# Talkeo for Mac, Roadmap

> Source of truth for what the Mac app is building and why. Items represent intent, not promises. For ecosystem-wide roadmap (backend, GitHub org, multi-agent flow), see `docs/ECOSYSTEM.md`. For other platforms, see [`talkeo-ai/windows`](https://github.com/talkeo-ai/windows).

## The problem we solve

Reading, writing, and listening in a non-native language create constant friction. You stop, switch tabs, paste into a translator, copy back, lose flow. AI tools that work on **selected text, in any app** eliminate this friction.

**Talkeo for Mac** puts AI tutoring across the surfaces where language friction actually happens. Text selection (TalkeoSelect mode), voice practice with Leo, vocab review, and more. Free with your own provider API keys. Optional Talkeo Cloud (paid) for zero-config.

## App identity

Talkeo is the app. Features are modes inside the app:

- **TalkeoSelect.** Popup-on-text-selection. Translate, improve, define, pronounce on any selected text in any app. (Current MVP focus.)
- **Practice mode.** Voice conversation with Leo, the AI tutor agent. (Planned, post-Cloud integration.)
- **History.** Review past practice sessions, captured selections, learning progress. (Planned.)
- **Vocab review.** Spaced repetition on words seen in selections and practice. (Planned.)
- **Settings and account.** Configure providers, BYO keys, Talkeo Cloud login. (Active.)

One app, one download. Features ship incrementally as the Cloud backend exposes the needed capabilities.

## v0.1, TalkeoSelect MVP (active sprint)

**Goal:** Core text selection actions working with BYO providers on macOS, with a Settings panel.

- [x] Text selection detection on macOS (Accessibility API plus clipboard fallback)
- [x] Floating tooltip UI
- [ ] Provider protocol layer (`LLMProvider`, `TTSProvider`), provider-neutral by design
- [ ] At least one BYO LLM provider reference implementation
- [ ] At least one BYO TTS provider reference implementation
- [ ] Core actions: Translate, Improve, Define, Pronounce
- [ ] Settings panel (configure providers, manage keys, voice IDs, models)
- [ ] Settings persisted to `~/.config/talkeo.json` (`schema_version: 1`)
- [ ] OSS foundation polish (LICENSE, README, CONTRIBUTING, ROADMAP, CHANGELOG, issue/PR templates)
- [ ] Talkeo Cloud waitlist signup (in-app email capture)

## v0.2, Talkeo Cloud integration

**Goal:** Optional managed experience. Users sign in with a Talkeo account, get curated providers without configuring keys. BYO remains fully functional and first-class.

Triggers when the Cloud backend migration completes (see `docs/ECOSYSTEM.md` for sprint phases).

- [ ] `TalkeoCloudProvider` implementations (LLM, TTS, STT) in the client. Call the Cloud HTTP API.
- [ ] Login flow (auth against Cloud)
- [ ] UI provider switcher (BYO vs Talkeo Cloud, per capability)
- [ ] `selections` persistence: captured text from TalkeoSelect saved to Cloud for later practice context
- [ ] Free credits tier integration
- [ ] Paid subscription tier integration

## v0.3, Practice mode (Leo integration)

**Goal:** Voice practice sessions with Leo, the AI tutor agent, accessible from the Mac app.

- [ ] Main window with Practice mode UI (separate from TalkeoSelect popup)
- [ ] Voice session with Leo via WebRTC/streaming
- [ ] Practice sessions tailored to the user's captured selections (using context from v0.2 persistence)
- [ ] Session feedback (corrections, improvement areas) surfaced post-session

## v0.4 and beyond, direction TBD

Decide based on v0.3 traction and user feedback. Candidate directions:

- **History plus Vocab review modes.** Review past practice plus spaced repetition for words seen.
- **Global subtitles overlay.** System audio capture plus real-time transcription plus click-to-translate. Watch any content, activate subtitles only when needed, translate specific words on demand.
- **Personalized teacher, forced practice.** Sessions driven by accumulated usage data (which words looked up, which phrasings struggled with).

## Open source

- License: MIT.
- Code public.
- Provider implementations in this repo are reference adapters for BYO use. Production routing decisions for Talkeo Cloud (managed) live in a private repo. See `docs/ECOSYSTEM.md` provider strategy.
- Contributions welcome via issues plus PRs. PRs reference an issue. Maintainer veto on scope, architecture, merges.

## Conventions

- Each version has a **named Goal**, not just a feature list.
- Items map to GitHub issues with labels (`good first issue`, `help wanted`, `area: providers / ui / selection / practice / cloud`).
- Roadmap can change. Direction commits, not specific dates.
- PRs reference roadmap items (`Fixes #N`).
