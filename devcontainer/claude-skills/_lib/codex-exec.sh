#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# codex-exec.sh — shared helper for the codex-review skills.
#
# Usage: codex-exec.sh <mode> [target...]
#   mode ∈ {plan, impl, results, codebase}
#
# Constraints (locked from prior bug history; do not relax):
# - Prompt is always piped via stdin with `-` as the prompt arg. Never argv.
# - --model is always pinned explicitly (no silent fallback).
# - ACK preflight runs before any heavy invocation.
# - Default isolation: --sandbox read-only --skip-git-repo-check (review-only).
#   Inside a devcontainer (DEVCONTAINER=true) or when CODEX_REVIEW_BYPASS_SANDBOX=1,
#   we switch to --dangerously-bypass-approvals-and-sandbox because the container
#   itself is the security boundary; Codex's bwrap-based sandbox needs unprivileged
#   user namespaces which most devcontainers don't allow, so the inner sandbox
#   either blocks every read or fails to initialize.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MODEL="gpt-5.5"
ACK_TIMEOUT=15
REVIEW_TIMEOUT=600

INLINE_CAP_PLAN=$((50 * 1024))
INLINE_CAP_IMPL=$((150 * 1024))
RESULTS_HEAD_LINES=200
RESULTS_TAIL_LINES=200

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(dirname "$SCRIPT_DIR")"
PREAMBLE_PATH="$SCRIPT_DIR/preamble.md"

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
info() { echo "==> $*" >&2; }

require_codex() {
  if ! command -v codex >/dev/null 2>&1; then
    die "codex CLI not found on PATH. Install: npm install -g @openai/codex@latest"
  fi
}

# Decide which isolation flags to pass to `codex exec`.
#
# Default (host): `--sandbox read-only --skip-git-repo-check` — Codex wraps its
# shell tool in bwrap and the host kernel allows unprivileged user namespaces.
#
# Devcontainer / externally-sandboxed env: bwrap fails with "No permissions to
# create a new namespace" and Codex can read nothing, defeating the review.
# Switch to `--dangerously-bypass-approvals-and-sandbox`, which Codex documents
# as "intended solely for running in environments that are externally sandboxed."
# Inside our devcontainer the security boundary is already the firewall +
# bind-mounted workspace + per-project isolation; the inner bwrap layer is
# redundant defense, not load-bearing.
#
# Triggers (any of):
#   - DEVCONTAINER=true (set by the bundled Dockerfile)
#   - CODEX_REVIEW_BYPASS_SANDBOX=1 (manual override for other sandboxed envs)
codex_isolation_flags() {
  if [[ "${DEVCONTAINER:-}" == "true" || "${CODEX_REVIEW_BYPASS_SANDBOX:-}" == "1" ]]; then
    printf '%s\0%s\0' "--dangerously-bypass-approvals-and-sandbox" "--skip-git-repo-check"
  else
    printf '%s\0%s\0%s\0' "--sandbox" "read-only" "--skip-git-repo-check"
  fi
}

# Read codex_isolation_flags into a bash array (NUL-separated, robust to spaces).
read_isolation_flags() {
  local raw
  raw=$(codex_isolation_flags)
  ISOLATION_FLAGS=()
  while IFS= read -r -d '' f; do
    ISOLATION_FLAGS+=("$f")
  done < <(printf '%s' "$raw")
}

ack_preflight() {
  local mode="$1"
  info "ACK preflight (model=$MODEL, mode=$mode)..."
  local out rc=0
  # Use stdin (not argv) for the ACK prompt, mirroring the heavy-review path.
  # The argv form would violate the locked stdin-only constraint and reproduce
  # the prior multi-KB hang class of bug if anyone copied this pattern.
  read_isolation_flags
  out=$(printf '%s\n' "reply ACK mode=$mode" | timeout "$ACK_TIMEOUT" codex exec --model "$MODEL" "${ISOLATION_FLAGS[@]}" - 2>&1) || rc=$?
  if (( rc != 0 )); then
    if echo "$out" | grep -qiE "model not found|requires.*newer.*version|unknown model"; then
      die "Codex rejected --model $MODEL. Try: npm install -g @openai/codex@latest"
    fi
    printf 'error: ACK preflight failed (mode=%s, rc=%d). Output:\n%s\n' "$mode" "$rc" "$out" >&2
    exit 1
  fi
}

git_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "(not a git repo)"; }
git_head() { git rev-parse --short HEAD 2>/dev/null || echo "(no HEAD)"; }
git_status_short() { git status --short 2>/dev/null || echo "(not a git repo)"; }

detect_default_branch() {
  # Precedence: upstream merge-base ref → origin/main → origin/master → main → master
  local ref
  if ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
    echo "${ref#refs/remotes/}"; return 0
  fi
  for candidate in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
      echo "$candidate"; return 0
    fi
  done
  return 1
}

require_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$1 mode requires a git repository"
}

byte_size() { wc -c < "$1" | tr -d ' '; }

# Number lines for code/diff snippets (POSIX-friendly cat -n with consistent spacing)
number_lines() { awk '{ printf "%5d  %s\n", NR, $0 }' "$@"; }

# Escape a string for safe use as the replacement in `${var//pat/repl}`.
# Bash 5+ treats `&` as a back-reference to the matched pattern (sed-style),
# so any `&` in user-supplied text (diffs, logs, plans) corrupts the output.
# Escape `\` first (to avoid double-escaping), then escape `&` to `\&`.
escape_for_subst() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//&/\\&}
  printf '%s' "$s"
}

# Redact obvious secrets in environment for command capture
redact_env_for_command() {
  read_isolation_flags
  echo "codex exec --model $MODEL ${ISOLATION_FLAGS[*]} - < <prompt>"
}

# ---------------------------------------------------------------------------
# Output destination (.tmp/runs/codex-review-<ts>-<mode>/)
# ---------------------------------------------------------------------------

resolve_run_dir() {
  local mode="$1"
  local ts; ts=$(date +%Y%m%dT%H%M%S)
  # Prefer the project-local .tmp/runs/ (IDE-visible, survives container rebuild,
  # gitignored by sbinit's preventive pattern). If it doesn't exist, create it
  # rather than silently falling back to /tmp — auto-creating a single empty
  # directory is cheaper than burying review artifacts where the user can't see
  # them. Idempotent and safe to run repeatedly.
  if [[ ! -d ".tmp/runs" ]]; then
    if mkdir -p ".tmp/runs" 2>/dev/null; then
      info "Created .tmp/runs/ for review artifacts"
    else
      warn ".tmp/runs/ could not be created; falling back to /tmp (durability lost)"
      echo "/tmp/codex-review-${ts}-${mode}"
      return 0
    fi
  fi
  echo ".tmp/runs/codex-review-${ts}-${mode}"
}

# ---------------------------------------------------------------------------
# Prompt assembly
# ---------------------------------------------------------------------------

build_metadata_block() {
  local mode="$1" target="$2" ts="$3"
  cat <<EOF
## Helper-injected metadata (trust these, do not re-derive)

- mode: $mode
- target: ${target:-(empty)}
- cwd: $(pwd)
- timestamp: $ts
- git branch: $(git_branch)
- git HEAD: $(git_head)
- git status (short):
\`\`\`
$(git_status_short)
\`\`\`
EOF
}

# ---------------------------------------------------------------------------
# Mode: plan
# ---------------------------------------------------------------------------

build_plan_prompt() {
  local plan_path="$1" ts="$2"
  [[ -f "$plan_path" ]] || die "plan file not found: $plan_path"
  [[ -r "$plan_path" ]] || die "plan file not readable: $plan_path"

  local size; size=$(byte_size "$plan_path")
  local body
  if (( size <= INLINE_CAP_PLAN )); then
    body=$(cat "$plan_path")
  else
    body="(plan exceeds ${INLINE_CAP_PLAN}B inline cap; read it directly at $plan_path)"
  fi

  local plan_path_esc body_esc template
  plan_path_esc=$(escape_for_subst "$plan_path")
  body_esc=$(escape_for_subst "$body")
  template=$(cat "$SKILLS_DIR/review-plan/prompt-template.md")
  template="${template//\{\{PLAN_PATH\}\}/$plan_path_esc}"
  template="${template//\{\{PLAN_BODY\}\}/$body_esc}"

  {
    cat "$PREAMBLE_PATH"
    echo
    build_metadata_block plan "$plan_path" "$ts"
    echo
    printf '%s\n' "$template"
  }
}

# ---------------------------------------------------------------------------
# Mode: impl
# ---------------------------------------------------------------------------

resolve_impl_target() {
  # Echoes "TARGET_DESC\n---SEP---\nIMPL_BODY"
  local target="$1"
  local target_desc body

  if [[ -z "$target" ]]; then
    require_git_repo impl
    local base
    base=$(detect_default_branch) || die "could not detect default branch (tried origin/HEAD, origin/main, origin/master, main, master). Pass an explicit target."
    target_desc="empty (defaulting to changes vs $base plus uncommitted edits)"
    body=$(
      echo "## Diff vs $base (committed branch changes)"
      echo
      git diff "$base"...HEAD 2>/dev/null || true
      echo
      echo "## Uncommitted changes (working tree + index vs HEAD)"
      echo
      git diff HEAD 2>/dev/null || true
    )
  elif [[ -f "$target" ]]; then
    require_git_repo impl
    target_desc="file: $target"
    body=$(
      echo "## git status (short)"
      echo
      git_status_short
      echo
      echo "## Diff touching $target"
      echo
      git log --oneline -n 5 -- "$target" 2>/dev/null || true
      echo
      git diff HEAD -- "$target" 2>/dev/null || true
      echo
      echo "## File contents (line-numbered)"
      echo
      number_lines "$target"
    )
  elif [[ -d "$target" ]]; then
    require_git_repo impl
    target_desc="directory: $target"
    body=$(
      echo "## git status (short)"
      echo
      git_status_short
      echo
      echo "## Files in $target"
      echo
      find "$target" -type f \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.tsx" -o -name "*.go" -o -name "*.rs" -o -name "*.sh" -o -name "*.md" -o -name "*.json" -o -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | head -50
      echo
      echo "## Diff touching $target"
      echo
      git diff HEAD -- "$target" 2>/dev/null || true
    )
  else
    # Treat as git ref / range
    require_git_repo impl
    if ! git rev-parse --verify --quiet "$target" >/dev/null 2>&1 \
        && ! git rev-parse --verify --quiet "${target%%..*}" >/dev/null 2>&1; then
      die "target is not a file, directory, or recognizable git ref: $target"
    fi
    if [[ "$target" == *..* ]]; then
      # Two-dot or three-dot range — git diff covers both forms
      target_desc="git range: $target"
      body=$(
        echo "## git log for range $target"
        echo
        git log --oneline "$target" 2>/dev/null | head -20 || true
        echo
        echo "## git diff for range $target"
        echo
        git diff "$target" 2>/dev/null || true
      )
    else
      # Single commit — show what it introduces (message + diff)
      target_desc="git commit: $target"
      body=$(
        echo "## git show $target (commit message + introduced diff)"
        echo
        git show --pretty=fuller "$target" 2>/dev/null || true
      )
    fi
  fi

  # Apply impl size cap
  local body_size=${#body}
  if (( body_size > INLINE_CAP_IMPL )); then
    body="(impl payload of ${body_size}B exceeds ${INLINE_CAP_IMPL}B cap; first ${INLINE_CAP_IMPL}B follows, then truncated)
${body:0:$INLINE_CAP_IMPL}
... (truncated) ..."
  fi

  printf '%s\n---SEP---\n%s\n' "$target_desc" "$body"
}

build_impl_prompt() {
  local target="$1" ts="$2"
  local resolved target_desc body
  resolved=$(resolve_impl_target "$target")
  target_desc="${resolved%%$'\n'---SEP---*}"
  body="${resolved#*---SEP---$'\n'}"

  local target_desc_esc body_esc template
  target_desc_esc=$(escape_for_subst "$target_desc")
  body_esc=$(escape_for_subst "$body")
  template=$(cat "$SKILLS_DIR/review-impl/prompt-template.md")
  template="${template//\{\{TARGET_DESC\}\}/$target_desc_esc}"
  template="${template//\{\{IMPL_BODY\}\}/$body_esc}"

  {
    cat "$PREAMBLE_PATH"
    echo
    build_metadata_block impl "$target" "$ts"
    echo
    printf '%s\n' "$template"
  }
}

# ---------------------------------------------------------------------------
# Mode: results
# ---------------------------------------------------------------------------

build_results_payload() {
  local target="$1"

  if [[ -f "$target" ]]; then
    local size; size=$(byte_size "$target")
    {
      echo "## Single log file: $target ($size bytes)"
      echo
      echo "### First $RESULTS_HEAD_LINES lines"
      echo "\`\`\`"
      head -n "$RESULTS_HEAD_LINES" "$target"
      echo "\`\`\`"
      echo
      echo "### Last $RESULTS_TAIL_LINES lines"
      echo "\`\`\`"
      tail -n "$RESULTS_TAIL_LINES" "$target"
      echo "\`\`\`"
      echo
      echo "### Grepped warnings / errors / tracebacks"
      echo "\`\`\`"
      grep -niE "(error|warn|fail|traceback|exception|fatal|panic)" "$target" | head -100 || echo "(no matches)"
      echo "\`\`\`"
      echo
      echo "### Full path"
      echo "$target"
    }
  elif [[ -d "$target" ]]; then
    {
      echo "## Run artifact directory: $target"
      echo
      echo "### Manifest (size, mtime, path)"
      echo "\`\`\`"
      find "$target" -type f -printf '%s\t%TY-%Tm-%Td %TH:%TM\t%p\n' 2>/dev/null | sort -k3 || true
      echo "\`\`\`"
      echo
      local main_log
      main_log=$(find "$target" -type f \( -name "*.log" -o -name "stdout*" -o -name "*.txt" -o -name "*.out" \) 2>/dev/null | head -1)
      if [[ -n "$main_log" && -f "$main_log" ]]; then
        local size; size=$(byte_size "$main_log")
        echo "### Main log (heuristic: $main_log, $size bytes)"
        echo
        echo "#### First $RESULTS_HEAD_LINES lines"
        echo "\`\`\`"
        head -n "$RESULTS_HEAD_LINES" "$main_log"
        echo "\`\`\`"
        echo
        echo "#### Last $RESULTS_TAIL_LINES lines"
        echo "\`\`\`"
        tail -n "$RESULTS_TAIL_LINES" "$main_log"
        echo "\`\`\`"
        echo
        echo "#### Grepped warnings / errors / tracebacks"
        echo "\`\`\`"
        grep -niE "(error|warn|fail|traceback|exception|fatal|panic)" "$main_log" | head -100 || echo "(no matches)"
        echo "\`\`\`"
      fi
    }
  else
    die "results target not found (must be file or directory): $target"
  fi
}

build_results_metadata() {
  local target="$1"
  # Look for a sibling metadata.json or similar (from the run-log feature, when it ships)
  local meta=""
  if [[ -d "$target" && -f "$target/metadata.json" ]]; then
    meta=$(cat "$target/metadata.json")
  fi
  if [[ -n "$meta" ]]; then
    echo "$meta"
  else
    cat <<EOF
(no run metadata found — helper could not infer command, exit code, duration.
Codex should ask the user for these if they materially affect the review.)
EOF
  fi
}

build_results_prompt() {
  local target="$1" ts="$2"
  local target_desc body run_meta
  if [[ -f "$target" ]]; then
    target_desc="log file: $target"
  elif [[ -d "$target" ]]; then
    target_desc="run directory: $target"
  else
    die "results target not found: $target"
  fi
  body=$(build_results_payload "$target")
  run_meta=$(build_results_metadata "$target")

  local target_desc_esc run_meta_esc body_esc template
  target_desc_esc=$(escape_for_subst "$target_desc")
  run_meta_esc=$(escape_for_subst "$run_meta")
  body_esc=$(escape_for_subst "$body")
  template=$(cat "$SKILLS_DIR/review-results/prompt-template.md")
  template="${template//\{\{TARGET_DESC\}\}/$target_desc_esc}"
  template="${template//\{\{RUN_METADATA\}\}/$run_meta_esc}"
  template="${template//\{\{RESULTS_BODY\}\}/$body_esc}"

  {
    cat "$PREAMBLE_PATH"
    echo
    build_metadata_block results "$target" "$ts"
    echo
    printf '%s\n' "$template"
  }
}

# ---------------------------------------------------------------------------
# Mode: codebase
# ---------------------------------------------------------------------------

build_codebase_manifest() {
  {
    echo "## Top-level structure (tree -L 2)"
    echo "\`\`\`"
    if command -v tree >/dev/null 2>&1; then
      tree -L 2 -a -I '.git|node_modules|.venv|venv|__pycache__|.tmp|target|dist|build|.next|.cache' 2>/dev/null || ls -la
    else
      ls -la
    fi
    echo "\`\`\`"
    echo
    echo "## Detected manifests"
    for f in package.json pyproject.toml requirements.txt setup.py Cargo.toml go.mod Gemfile composer.json pom.xml build.gradle; do
      if [[ -f "$f" ]]; then
        local size; size=$(byte_size "$f")
        if (( size < 8192 )); then
          echo
          echo "### $f"
          echo "\`\`\`"
          cat "$f"
          echo "\`\`\`"
        else
          echo
          echo "### $f (large; first 50 lines)"
          echo "\`\`\`"
          head -50 "$f"
          echo "\`\`\`"
        fi
      fi
    done
    echo
    echo "## Recent commits (last 20)"
    echo "\`\`\`"
    git log --oneline -n 20 2>/dev/null || echo "(not a git repo)"
    echo "\`\`\`"
  }
}

build_codebase_prompt() {
  local focus="$1" ts="$2"
  local manifest
  manifest=$(build_codebase_manifest)
  local focus_str="${focus:-(none — broad review)}"

  local focus_str_esc manifest_esc template
  focus_str_esc=$(escape_for_subst "$focus_str")
  manifest_esc=$(escape_for_subst "$manifest")
  template=$(cat "$SKILLS_DIR/review-codebase/prompt-template.md")
  template="${template//\{\{FOCUS\}\}/$focus_str_esc}"
  template="${template//\{\{MANIFEST\}\}/$manifest_esc}"

  {
    cat "$PREAMBLE_PATH"
    echo
    build_metadata_block codebase "$focus" "$ts"
    echo
    printf '%s\n' "$template"
  }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local mode="${1:-}"
  shift || true
  local target="${*:-}"

  case "$mode" in
    plan|impl|results|codebase) ;;
    "") die "missing mode argument. Usage: codex-exec.sh <plan|impl|results|codebase> [target...]" ;;
    *) die "unknown mode: $mode (expected plan|impl|results|codebase)" ;;
  esac

  require_codex

  local ts; ts=$(date +%Y%m%dT%H%M%S)
  local run_dir; run_dir=$(resolve_run_dir "$mode")
  mkdir -p "$run_dir"

  local prompt_path="$run_dir/prompt.md"
  local stdout_path="$run_dir/stdout.txt"
  local stderr_path="$run_dir/stderr.txt"
  local meta_path="$run_dir/metadata.json"

  info "Building $mode prompt..."
  case "$mode" in
    plan)     [[ -n "$target" ]] || die "plan mode requires a path argument"
              build_plan_prompt "$target" "$ts" > "$prompt_path" ;;
    impl)     build_impl_prompt "$target" "$ts" > "$prompt_path" ;;
    results)  [[ -n "$target" ]] || die "results mode requires a path argument"
              build_results_prompt "$target" "$ts" > "$prompt_path" ;;
    codebase) build_codebase_prompt "$target" "$ts" > "$prompt_path" ;;
  esac

  ack_preflight "$mode"

  local prompt_bytes; prompt_bytes=$(byte_size "$prompt_path")
  info "Sending $mode review prompt to codex ($prompt_bytes bytes via stdin; artifact dir: $run_dir)..."

  read_isolation_flags
  local started_at; started_at=$(date +%s%N)
  local exit_code=0
  # Capture exit status correctly: `if ! cmd; then exit_code=$?` records the
  # *negated* status (0 when cmd failed, 1 when it succeeded), inverting the
  # logic. Use `cmd || exit_code=$?` to record the actual status.
  timeout "$REVIEW_TIMEOUT" codex exec --model "$MODEL" "${ISOLATION_FLAGS[@]}" - \
        < "$prompt_path" > >(tee "$stdout_path") 2> >(tee "$stderr_path" >&2) \
        || exit_code=$?
  if (( exit_code != 0 )); then
    warn "codex exec returned non-zero exit $exit_code (see $stderr_path); review output (if any) is in $stdout_path"
  fi
  local ended_at; ended_at=$(date +%s%N)
  local duration_ms=$(( (ended_at - started_at) / 1000000 ))

  local codex_version; codex_version=$(codex --version 2>/dev/null | head -1)
  local cwd; cwd=$(pwd)
  local branch; branch=$(git_branch)
  local head; head=$(git_head)

  # Escape strings for JSON. We avoid shelling out to python/jq to keep
  # the helper portable; the values we substitute don't contain newlines
  # except possibly target, which we sanitize.
  local target_esc cmd_esc
  target_esc=$(printf '%s' "$target" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g' | tr -d '\n')
  cmd_esc=$(printf '%s' "$(redact_env_for_command)" | sed 's/\\/\\\\/g; s/"/\\"/g')

  cat > "$meta_path" <<EOF
{
  "mode": "$mode",
  "target": "$target_esc",
  "cwd": "$cwd",
  "git_branch": "$branch",
  "git_head": "$head",
  "codex_version": "$codex_version",
  "model": "$MODEL",
  "command": "$cmd_esc",
  "started_at_ns": $started_at,
  "ended_at_ns": $ended_at,
  "duration_ms": $duration_ms,
  "exit_code": $exit_code,
  "prompt_bytes": $prompt_bytes,
  "prompt_path": "$prompt_path",
  "stdout_path": "$stdout_path",
  "stderr_path": "$stderr_path"
}
EOF

  info "Review persisted to $run_dir/"
  # Review findings exit 0; only wrapper-level errors propagate non-zero.
  exit 0
}

main "$@"
