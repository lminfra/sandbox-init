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

The plan path is in `$ARGUMENTS`. Run the shared review helper in `plan` mode:

```bash
bash ${CLAUDE_SKILL_DIR}/../_lib/codex-exec.sh plan "$ARGUMENTS"
```

The helper validates the file, builds the prompt (preamble + plan-mode template + helper-injected metadata + plan body inlined if <50KB else referenced), runs an ACK preflight, pipes the prompt to `codex exec` via stdin with locked flags (`--model gpt-5.5 --sandbox read-only --skip-git-repo-check`), streams Codex's response, and persists everything to `.tmp/runs/codex-review-<ts>-plan/`.

When the script returns, surface the verdict line and the tagged bullet list to the user verbatim. Do not restate the plan or the review.
