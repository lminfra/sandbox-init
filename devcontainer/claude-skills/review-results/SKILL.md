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

## Path discovery (when `$ARGUMENTS` is empty)

If the user invoked this without a path, do not call the helper yet. Find the most likely recent run artifact and confirm with the user before proceeding. Search in this order, most-likely first:

1. `<project root>/.tmp/runs/*` — directories or log files written by the user, scripts, or the (forthcoming) run-log feature. **Exclude `codex-review-*` directories** — those are review artifacts, not run results.
2. `<project root>/test-output/`, `<project root>/logs/`, `<project root>/coverage/`, `<project root>/artifacts/` — conventional log/artifact directories at the project root.
3. Recently modified files at the project root or one level deep matching `*.log`, `*.out`, `*.txt`, `*.json` (in CI / pytest / benchmark conventions).

Use `ls -t` (or equivalent) to sort by modification time, most-recent first. Then:

- If exactly one candidate exists, or one is dramatically more recent than the rest, pick it and tell the user which file/directory you chose and why before running the helper.
- If two or three plausible candidates exist, list them with timestamps and a one-line summary (e.g. file size or directory file count) and ask the user to pick. Do not guess.
- If no plausible candidate exists, ask the user for the path explicitly.

Once a path is resolved, proceed as if it had been passed in `$ARGUMENTS`.

## Invocation

```bash
bash ${CLAUDE_SKILL_DIR}/../_lib/codex-exec.sh results "<resolved-path>"
```

The helper validates the target, gathers run metadata (command, cwd, exit code, duration, env, timestamp where available), builds a structured payload (manifest + first/last 200 lines of the main log + grepped warnings/errors + paths to full logs — never raw "largest file"), runs an ACK preflight, pipes via stdin with locked flags, and persists the run.

When the script returns, surface the verdict and tagged bullets verbatim. Do not restate the log content.
