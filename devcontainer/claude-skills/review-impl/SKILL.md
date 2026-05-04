---
name: review-impl
description: Ask Codex to review an implementation for correctness,
  edge cases, test coverage, code quality, fit with the codebase, and
  backwards compatibility. Invoke when the user wants a second opinion
  on work that was just done (e.g. "review this implementation",
  "have Codex check my changes", "review src/auth/", or via
  `/review-impl [target]`).
allowed-tools: Bash
---

# Review an implementation with Codex

The target is in `$ARGUMENTS`. It can be:

- A **file path** — e.g. `src/auth/login.py`
- A **directory path** — e.g. `src/auth/`
- A **git ref or range** — e.g. `HEAD`, `HEAD~3..HEAD`, `main..HEAD`
- **Empty** — defaults to the branch's changes vs the detected default branch plus uncommitted edits ("what was just done")

Run the shared review helper in `impl` mode:

```bash
bash ${CLAUDE_SKILL_DIR}/../_lib/codex-exec.sh impl "$ARGUMENTS"
```

The helper resolves the target type, computes the diff base for empty targets (and embeds it verbatim in the prompt — no silent defaults), assembles the prompt with `git status --short` and the relevant diff, applies the 150 KB inline cap with file-path fallback, runs an ACK preflight, pipes via stdin with locked flags, and persists the run.

When the script returns, surface the verdict and tagged bullets verbatim. Do not restate the diff.
