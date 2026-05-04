You are reviewing the output of a run captured by Claude Code or the user. The user wants a second opinion on what this output actually says — whether the run did what it was supposed to do, whether there are hidden failures, suspicious metrics, missing artifacts, or misinterpreted output.

The target is: {{TARGET_DESC}}

Run metadata (helper-extracted; trust the values, not your own guesses):

```
{{RUN_METADATA}}
```

Structured run payload (manifest, log excerpts, grepped warnings/errors, full paths):

---
{{RESULTS_BODY}}
---

## Review focus, in priority order

1. **Did the run actually do what it was supposed to do?** Exit code 0 doesn't always mean success. Look for silent failures, swallowed errors, "passing" output that masks a no-op, tests that were collected but skipped.
2. **Did the run actually exercise the changed code or intended dataset/input?** A green run that didn't touch the relevant code is worse than a red run that did.
3. **Were the expected artifacts created or updated?** Files, checkpoints, reports, coverage data, etc. Don't trust the log alone — flag if the manifest shows expected outputs are missing.
4. **Are the metrics or assertions consistent with what the run claims?** Suspicious patterns: timeouts, retries, NaN, unstable values, suspiciously round results, hardcoded numbers.
5. **Hidden warnings or stack traces** the user may have missed in the noise.
6. **Comparison fairness.** If this is an A/B or before/after run: same conditions, same seed, no leakage, no skew?
7. **Open questions.** What would you ask the user before trusting this result?

## Output rules

- Lead with one verdict line, exactly: `Trustworthy`, `Trustworthy with caveats`, or `Not trustworthy`, followed by a single-clause justification.
- Then bullets, each `[must-fix]` / `[should-fix]` / `[nice-to-have]` and a concrete issue with a line reference into the excerpt or a full-file path.
- Apply the preamble's evidence, scope, tag, praise, and no-finding rules.
- End with a `Files consulted:` footer (log files and source paths both allowed).
