---
name: review-codebase
description: Ask Codex to perform a broad architectural and sanity
  review of the project for structural issues, missing pieces,
  technical debt, systemic risks, and developer-workflow health.
  Invoke when the user wants a high-level second opinion on the
  project as a whole (e.g. "give me a sanity check on this codebase",
  "have Codex review the architecture", or via
  `/review-codebase [focus-area]`).
allowed-tools: Bash
---

# Review codebase with Codex

The optional focus area is in `$ARGUMENTS`. Empty = broad review. A phrase narrows Codex's attention while still walking the whole project.

Run the shared review helper in `codebase` mode:

```bash
bash ${CLAUDE_SKILL_DIR}/../_lib/codex-exec.sh codebase "$ARGUMENTS"
```

The helper builds a project manifest (`tree -L 2` with sane ignores; language/framework hints from package.json, pyproject.toml, Cargo.toml, go.mod, etc.; brief recent commit summary), passes it as the prompt context (no inline body — Codex reads files itself via sandbox), runs an ACK preflight, pipes via stdin with locked flags, and persists the run.

When the script returns, surface the verdict and tagged bullets verbatim.
