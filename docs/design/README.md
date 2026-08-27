# Design Documents

> **Note for contributors:** these are architectural decision records (ADRs), not user-facing
> documentation. For user guides, see [`docs/README.md`](../README.md).

One live document remains. Everything else from the build phase (Feb 2026) was removed for the
2.0 release: those systems are implemented and documented in `docs/`, so the original ADRs no
longer describe the shipping code. History still has them:

```bash
git log --follow -- docs/design/
```

## Live documents

| Document | Status | What's useful |
|----------|--------|----------------|
| [MCP_2026_STRATEGY.md](MCP_2026_STRATEGY.md) | Implemented (Aug 2026) | ADR for the MCP 2026-07-28 adoption: spec changes, shipped workstreams, compatibility matrix for legacy clients, old Ruby, Docker, and worktrees. Open follow-ups are in its section 6. |
