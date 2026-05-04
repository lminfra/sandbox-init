---
name: review-plan
description: Ask Codex to review a written plan document for technical
  soundness, simpler alternatives, dependency-ordering, scope, missing
  risks, and conflicts with the existing codebase. Invoke when the user
  wants a second opinion on a plan before implementation begins
  (e.g. "review this plan with Codex", "get a second opinion on
  PLAN.md", or via `/review-plan PLAN.md`).
allowed-tools: Bash
---

# Review a plan with Codex

The plan path is in `$ARGUMENTS`.

## Path discovery (when `$ARGUMENTS` is empty)

If the user invoked this without a path, do not call the helper yet. Find the most likely "hot" plan file and confirm with the user before proceeding. Search in this order, most-likely first:

1. `~/.claude/plans/*.md` — Plan Mode outputs from Claude Code (each is a generated `<adjective-adjective-noun>.md`)
2. `<project root>/PLAN*.md`, `<project root>/plan*.md`, `<project root>/RFC*.md` — conventional plan documents
3. `<project root>/.tmp/notes/*.md` — agent-written design notes seeded by `sbinit`
4. `<project root>/docs/*.md` — committed design docs

Use `ls -t` (or equivalent) to sort by modification time, most-recent first. Then:

- If exactly one candidate exists, or one is dramatically more recent than the rest, pick it and tell the user which file you chose and why before running the helper.
- If two or three plausible candidates exist (e.g. several files in `~/.claude/plans/` modified in the same session), list them with timestamps and ask the user to pick. Do not guess.
- If no plausible candidate exists, ask the user for the path explicitly.

Once a path is resolved, proceed as if it had been passed in `$ARGUMENTS`.

## Invocation

```bash
bash ${CLAUDE_SKILL_DIR}/../_lib/codex-exec.sh plan "<resolved-path>"
```

The helper validates the file, builds the prompt (preamble + plan-mode template + helper-injected metadata + plan body inlined if <50KB else referenced), runs an ACK preflight, pipes the prompt to `codex exec` via stdin with locked flags (`--model gpt-5.5 --sandbox read-only --skip-git-repo-check`), streams Codex's response, and persists everything to `.tmp/runs/codex-review-<ts>-plan/`.

When the script returns, surface the verdict line and the tagged bullet list to the user verbatim. Do not restate the plan or the review.
