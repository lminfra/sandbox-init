---
name: review-results
description: Ask Codex to review the output of a run — test logs,
  training logs, benchmark output, command results — for anomalies,
  hidden failures, suspicious metrics, missing artifacts, or
  misinterpreted output. Invoke when the user wants a second opinion
  on what a log actually says (e.g. "review these test results",
  "have Codex look at this benchmark", or via
  `/review-results <log-path>`).
allowed-tools: Bash
---

# Review run results with Codex

The target is in `$ARGUMENTS`. It must be a path to a log file or a directory containing run artifacts (e.g. a `.tmp/runs/<ts>-<slug>/` directory).

Run the shared review helper in `results` mode:

```bash
bash ${CLAUDE_SKILL_DIR}/../_lib/codex-exec.sh results "$ARGUMENTS"
```

The helper validates the target, gathers run metadata (command, cwd, exit code, duration, env, timestamp where available), builds a structured payload (manifest + first/last 200 lines of the main log + grepped warnings/errors + paths to full logs — never raw "largest file"), runs an ACK preflight, pipes via stdin with locked flags, and persists the run.

When the script returns, surface the verdict and tagged bullets verbatim. Do not restate the log content.
