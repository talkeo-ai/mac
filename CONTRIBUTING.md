# Contributing to Talkeo for Mac

Thanks for your interest. Read this before opening a PR.

## Mindset

- **Use whatever stack/tool/AI you need.** No artificial limits on complexity or AI use. If a technology solves the problem cleanly, use it.
- **Vibecoding is welcome.** Use Claude Code, Cursor, GPT, whatever. What matters is the result and your understanding of it, not how you typed it.
- **Rigorous review.** Every PR is reviewed for four things:
  1. Does it solve a problem on the [ROADMAP](./ROADMAP.md) or an open issue?
  2. Does the author understand what they did and why?
  3. Is the code clean and consistent with the surrounding architecture?
  4. Was it actually built, run, and verified — not just generated?

If you can't answer all four, the PR will be closed (with feedback, no drama).

### Proof of work (required for review)

AI-generated code is welcome, but **AI output alone is never enough** — you must build it, run it, and confirm it works *before* requesting review. A PR that compiles in theory but was never run will be closed. Every PR must include:

- **A GIF or short screen recording of the change working.** Mandatory for any UI/UX change — it's the fastest proof the behavior is real. Drag the file into the PR description (GitHub hosts it; don't commit it to the repo).
- **Confirmation it builds** — `swift build` *and* the Xcode build, both clean.
- **What you actually tested** — the real manual steps you ran to verify it, not aspirational checkboxes.

## Scope

### In scope

- Native macOS app for Talkeo.
- TalkeoSelect popup mode (AI on selected text in any app) and other planned modes (Practice with Leo, History, Vocab review).
- AI actions on selected text: translate, improve, define, pronounce, custom.
- Multiple LLM / TTS / STT providers behind protocol layers.
- **BYO provider adapters** as reference examples for self-hosted users.
- Accessibility-friendly defaults.

### Out of scope

- Windows app. See [`talkeo-ai/windows`](https://github.com/talkeo-ai/windows).
- Backend code. See [`talkeo-ai/talkeo`](https://github.com/talkeo-ai/talkeo).
- Features requiring server-side state. Those belong in the backend, consumed via the Talkeo Cloud HTTP API.

If you're unsure, open a discussion issue before coding.

## Providers

Talkeo uses provider protocols (`LLMProvider`, `TTSProvider`, `STTProvider`) so the same UI works with any backend.

- **Self-hosted mode** uses your own API keys. Contributions for reference BYO adapters are welcome. They serve as examples for other contributors implementing their own adapters.
- **Talkeo Cloud mode** is the managed option. The Talkeo Cloud client is implemented and maintained by the Talkeo team and is not a target for community contributions.

The protocols are designed so both modes are interchangeable at runtime. When you implement a BYO adapter, the same UI works against Talkeo Cloud without changes.

## How to contribute

1. Find an issue labeled `good first issue` or `help wanted`, or pick a roadmap item.
2. Comment on the issue saying you want to work on it (avoids duplicate work).
3. Fork the repo, make your changes, open a PR. Reference the issue: `Fixes #N`.
4. The maintainer reviews against the three criteria above.
5. Iterate or merge.

For tiny fixes (typos, obvious bugs), a direct PR without an issue is fine.

## Code conventions

- **Swift API Design Guidelines** for naming and style. When in doubt, run `swift-format`.
- **Settings persist with `schema_version`** field. Migration paths required when changing.
- **API keys NEVER in code or commits.** Local config files only (`~/.config/talkeo.json`), gitignored.
- **Providers behind protocols.** No hardcoded providers in UI/action logic. The user (or Talkeo Cloud, separately) decides the provider at runtime.
- **English everywhere.** Code, comments, commits, PRs, issues, docs.

## Maintainer

[@realjoaquinalvarez](https://github.com/realjoaquinalvarez) has final say on scope, architecture, and merges. Decisions are documented; if you disagree, open a discussion before a PR.

## License

By contributing, you agree your contributions are licensed under MIT (see [LICENSE](./LICENSE)).
