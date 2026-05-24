# Talkeo Ecosystem Context

> Context document for understanding where the Talkeo native app fits in the broader Talkeo product, current sprint state, cofounder coordination, and the planned GitHub org structure. This document is informational — it describes the state of the surrounding work, not commitments inside this repo.

## Product framing

**Talkeo** is an AI-first language tutor. Two main surfaces:

1. **Native apps (this repo)** — Mac, Windows, future Linux/mobile. The closest-to-user surface. Runs in the menu bar, integrates with text selection across the OS, offers practice sessions with Leo (voice agent), vocab review, etc.
2. **Talkeo Cloud (separate backend, separate repo)** — FastAPI backend with multi-agent orchestration, RAG, semantic memory, eval harness, MCP server, observability, deployed on AWS. Single source of truth for product data and AI orchestration.

The native apps are clients of Talkeo Cloud. Same backend serves all platforms.

### App as a product, features as modes

The app is named **Talkeo**. **TalkeoSelect is one feature of the app** — the popup-on-text-selection mode. The naming convention follows products like Claude:

| Claude | Talkeo |
|---|---|
| Claude (app, the brand) | Talkeo (app, the brand) |
| Claude Code (subproduct, CLI) | TalkeoSelect (feature, popup mode) |
| Claude in IDE (integration) | Talkeo Practice (feature, conversation with Leo) |

The Mac app will eventually include: TalkeoSelect (popup), Practice (Leo conversation), History (review past sessions), Vocab review (spaced repetition), Settings/account. Users download one app; multiple modes inside.

## Current sprint state (as of 24/may/2026)

**Sprint window:** 22/may → 17/jul 2026 (8 weeks + 2-week buffer).

**Goal:** rewrite the backend production-grade, migrate from fly.io to AWS, integrate the Mac app with the new Cloud, level up the agentic stack (multi-agent + RAG + observability), maximize open source under a GitHub org.

**Phases:**
- **Pre-Phase (20-21/may):** comprehension cleanup + GitHub org setup.
- **Phase A (22-30/may):** Mac MVP backend stateless. FastAPI básico + streaming Swift ↔ FastAPI + LLM/TTS integration. No AWS yet, no DB migration yet.
- **Phase B.1 (31/may - 19/jun):** Talkeo Cloud migration to AWS. RDS Postgres + pgvector + ECS Fargate + Docker prod + FastAPI production patterns. Strangler Fig migration (no service downtime).
- **Phase B.2 (20-26/jun):** Mac ↔ Cloud integration. Auth flow, persist `selections` from Mac in Postgres, practice session generation with Leo from those selections.
- **Phase C (27/jun - 10/jul):** Multi-agent (Leo + Tutor + Evaluator + Coach), RAG patterns, eval harness, MCP server, Redis, observability completa.
- **Phase D (11-17/jul):** Polish + writeups públicos + skills bridging.
- **Phase E (post-sprint, optional):** Web front migration + other follow-ups.

**Where to find the full roadmap:** `~/Documents/personal/life-os/proyectos/talkeo/roadmap-talkeo.md` (the cofounder coordination doc).

## Cofounder context (Miguel)

Miguel is cofounder of Talkeo. As of 24/may, he is independently working on an AWS migration path for the backend. Before any large backend migration work starts in earnest (Phase B.1), an alignment session between Joaquin and Miguel is pending to:
- Avoid duplicate work on AWS migration.
- Decide who leads the technical migration vs builds on what's already in progress.
- Align on AWS account ownership, billing, IAM model.
- Confirm open source strategy (proposal: maximize, with private exceptions).
- Confirm GitHub org creation and repo transfers.

**Implication for this repo:** if Miguel's AWS work changes the API contract or deployment target, the Mac app's `TALKEO_CLOUD_BASE_URL` and any backend integration code will need to adapt. No work in this repo is gated on Miguel's decisions; the Mac app's MVP features (Phase A scope) can ship against the current fly.io backend.

## GitHub org plan: `talkeo`

A GitHub organization at `github.com/talkeo` is being set up. Repositories will be transferred from personal accounts to the org. The planned structure:

```
github.com/talkeo/
├── .github             (org profile, public)
├── talkeo              (backend monorepo: api + web + mobile + shared, public)
├── mac                 (this repo, public, ya MIT)
├── windows             (separate repo, public, planned)
├── infra               (Terraform/CDK + AWS configs, public, no secrets)
├── agents              (multi-agent orchestration + eval harness, public)
├── mcp                 (MCP server, public)
├── admin               (admin panel, PRIVATE)
└── gateway             (Talkeo Gateway: provider routing, PRIVATE — moat técnico)
```

**Rationale per repo:**
- **`talkeo` (monorepo principal):** api + web + mobile share types and change together. Cross-cutting changes in one PR.
- **`mac` (this repo):** Swift toolchain (Xcode), own lifecycle, distributed as signed .app.
- **`windows`:** .NET toolchain (Visual Studio), own lifecycle, distributed as signed .exe.
- **`infra`:** infra changes ≠ product changes, audience devops.
- **`agents`, `mcp`:** standalone value (consumable outside Talkeo).
- **`admin` (PRIVATE):** users, billing, internal metrics, feature flags, provider cost dashboards. Security + competitive.
- **`gateway` (PRIVATE):** concrete adapters per external provider + routing matrix + fallback chains + production prompts + parameter tuning. The technical moat that keeps Talkeo's provider choices private.

This repo will become `talkeo/mac` once the org is set up and the repo is transferred. The transfer preserves history, stars, issues, and PRs. GitHub auto-redirects the old URL.

## Provider strategy summary

Talkeo positions externally as a provider (of AI tutoring). External observers cannot infer which third-party providers Talkeo Cloud uses internally.

**Public code (this repo + `talkeo/talkeo` backend monorepo):**
- Abstract interfaces only (`LLMProvider`, `TTSProvider`, `STTProvider`).
- Generic HTTP adapter (OpenAI-compatible) for self-hosted users.
- Reference BYO adapter examples for contributors (educational, not a signal of production choice).

**Private (lives in `talkeo/gateway` private repo):**
- Concrete adapters per production provider.
- Routing matrix, fallback chains, tuning, prompts production-tuned.

**Three business model streams enabled:**
1. **Self-hosted (free):** dev clones repo, configures own LLM endpoint, runs Talkeo with own provider.
2. **Talkeo Cloud (managed):** hosts the Gateway + decides routing + keys, charges subscription.
3. **Talkeo Cloud BYOK:** hosts infra + Gateway + logic, user brings provider keys.

## Backend repo (separate context)

The backend lives at `~/dev/talkeo-os/Talkeo-Monorepo/` (current remote: `realjoaquinalvarez/Talkeo.ai.git`). When the org migration happens, it will become `talkeo/talkeo` (the monorepo principal).

**Current state of backend:**
- FastAPI + Supabase Postgres + LiveKit voice agent (Leo) + dispatcher worker.
- Deployed on fly.io, 3 processes (api + agent + dispatcher).
- 29 Postgres migrations, 18 tables, plan documented in `cortex/plans/06-learning-method/`.
- Uses Supabase for: Postgres DB (intensive), Auth (intensive), Storage (audio bucket).

**Planned backend changes (Phase B.1):**
- Rewrite with production patterns.
- DB: Supabase Postgres → AWS RDS Postgres + pgvector.
- Compute: fly.io → AWS ECS Fargate.
- Storage: Supabase Storage → S3.
- Auth: stays in Supabase during Phase B.1 (migration decision deferred to Phase B.2 or post-sprint).
- Schema: migrate as-is, refactor incrementally post-cutover via ADRs. New tables to add: `embeddings` (pgvector), `user_events_log` (append-only), `selections` (from this Mac app).

## What this means for this repo (Mac app)

During the sprint:
- **Phase A (22-30/may):** Mac MVP features. Talk to current fly.io backend. No changes to backend integration.
- **Phase B.1 (31/may - 19/jun):** backend migration to AWS in parallel. Mac app can continue against fly.io until cutover. When cutover happens, only the `TALKEO_CLOUD_BASE_URL` needs to change. API contract preserved during migration (Strangler Fig: new backend exposes same HTTP contract as current).
- **Phase B.2 (20-26/jun):** New feature in this repo — `selections` persistence + practice session integration with Leo. Requires new API endpoints (defined in Cloud), implemented in Mac app as new feature module.
- **Phase C+ (27/jun onwards):** Continue adding native features as Cloud capabilities expand (practice mode UI, multi-agent flow consumer, vocab review UI).

## References

- This repo's product roadmap: `ROADMAP.md`
- Architecture conventions: `docs/architecture.md`
- Mac engineering details: `apps/macos/CLAUDE.md`
- Backend monorepo: `~/dev/talkeo-os/Talkeo-Monorepo/`
- Full cofounder coordination doc: `~/Documents/personal/life-os/proyectos/talkeo/roadmap-talkeo.md`
