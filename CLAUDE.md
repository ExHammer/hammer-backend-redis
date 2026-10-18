# CLAUDE.md

Claude Code guidance for this repository. The canonical agent instructions live in AGENTS.md.

@AGENTS.md

## Plugin Setup

```bash
claude plugin install elixir@claude-code-elixir
claude plugin install superpowers@claude-plugins-official
claude plugin install code-review@claude-plugins-official
```

## Claude-specific notes

- This is a library, not an app: there is no Phoenix server to run. Verification means a running Redis (`docker compose up -d redis`) plus the CI commands in AGENTS.md.
- Before claiming a change works, run `mix test --warnings-as-errors --include redis --include slow` and confirm tests were not skipped for lack of Redis (superpowers:verification-before-completion).
- Behaviour changes to Lua scripts: use superpowers:test-driven-development, then `/code-review` before opening a PR.
- The sibling checkout `/Users/manu/Projects/hammer` is the core library; treat it as read-only reference from this repo.
- Do not commit, tag, or publish to Hex unless asked.
- `.claude/settings.local.json` is the user's local allowlist; do not edit it.
