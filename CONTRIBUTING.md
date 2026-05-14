# Contributing to Talkeo

Thanks for your interest. Read this before opening a PR.

## Mindset

- **Use whatever stack/tool/AI you need.** No artificial limits on complexity or AI use. If a technology solves the problem cleanly, use it.
- **Vibecoding is welcome.** Use Claude Code, Cursor, GPT, whatever. What matters is the result and your understanding of it — not how you typed it.
- **Rigorous review.** Every PR is reviewed for three things:
  1. Does it solve a problem on the [ROADMAP](./ROADMAP.md) or an open issue?
  2. Does the author understand what they did and why?
  3. Is the code clean and consistent with the surrounding architecture?

If you can't answer all three, the PR will be closed (with feedback, no drama).

## Scope

### In scope

- Native text selection assistants per platform (macOS, Windows, Linux).
- AI actions on selected text: translate, improve, define, pronounce, custom.
- Multiple LLM / TTS / STT providers behind protocol layers.
- **BYO providers** (Groq, OpenAI, ElevenLabs, Fish Audio, etc.) — community contributions welcome.
- Accessibility-friendly defaults.

### Out of scope

- Mobile (iOS / Android). Separate projects if needed.
- Web SaaS surfaces. Talkeo has other surfaces for those.
- Features requiring server-side state. That belongs in Talkeo Cloud (see below), not in this client.

If you're unsure, open a discussion issue before coding.

## Providers: BYO vs. Talkeo Cloud

Talkeo has two ways to provide AI capabilities:

- **BYO providers** (LLM / TTS / STT) use the user's own API keys. **Contributions for new BYO providers are welcome** — implement the relevant protocol (`LLMProvider`, `TTSProvider`, `STTProvider`).
- **Talkeo Cloud** is the optional zero-config paid offering, maintained by the Talkeo team. Talkeo Cloud bindings are **not contributed by the community** — they are implemented and maintained by the maintainer.

The provider protocols are designed so BYO implementations and Talkeo Cloud implementations are interchangeable at runtime. Contributors should design protocol-conforming code; Talkeo Cloud integration happens separately and does not need to be considered when implementing BYO providers.

## How to contribute

1. Find an issue labeled `good first issue` or `help wanted`, or pick a roadmap item.
2. Comment on the issue saying you want to work on it (avoids duplicate work).
3. Fork the repo, make your changes, open a PR. Reference the issue: `Fixes #N`.
4. The maintainer reviews against the three criteria above.
5. Iterate or merge.

For tiny fixes (typos, obvious bugs), a direct PR without an issue is fine.

## Code conventions

- **Platform-native:** match the conventions of the platform you're working on (Swift API Design Guidelines on macOS, .NET conventions on Windows, etc.).
- **Settings persist with `schema_version`** field. Migration paths required when changing.
- **API keys NEVER in code or commits.** Local config files only (`~/.config/talkeo.json`), gitignored.
- **Providers behind protocols/interfaces.** No hardcoded providers in UI/action logic. The user (or Talkeo Cloud, separately) decides the provider at runtime.
- **English everywhere.** Code, comments, commits, PRs, issues, docs.

## Maintainer

[@realjoaquinalvarez](https://github.com/realjoaquinalvarez) has final say on scope, architecture, and merges. Decisions are documented; if you disagree, open a discussion before a PR.

## License

By contributing, you agree your contributions are licensed under MIT (see [LICENSE](./LICENSE)).
