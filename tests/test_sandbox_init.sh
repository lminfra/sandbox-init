#!/usr/bin/env bash
set -euo pipefail

# Test runner for sandbox-init

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_INIT="${SCRIPT_DIR}/../sandbox-init"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# --- Helpers ---

setup() {
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  if [[ -n "${TEST_DIR:-}" ]] && [[ -d "$TEST_DIR" ]]; then
    rm -rf "$TEST_DIR"
  fi
}

pass() {
  echo "  PASS: $1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  echo "  FAIL: $1 — $2"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

skip() {
  echo "  SKIP: $1 — $2"
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

# --- Tests ---

test_help() {
  local name="--help prints usage and exits 0"
  local output
  output=$("$SANDBOX_INIT" --help 2>&1) || { fail "$name" "non-zero exit"; return; }
  if echo "$output" | grep -q "Usage:"; then
    pass "$name"
  else
    fail "$name" "missing Usage in output"
  fi
}

test_version() {
  local name="--version prints version and exits 0"
  local output
  output=$("$SANDBOX_INIT" --version 2>&1) || { fail "$name" "non-zero exit"; return; }
  if echo "$output" | grep -q "sandbox-init"; then
    pass "$name"
  else
    fail "$name" "missing version string"
  fi
}

test_happy_path() {
  local name="happy path: creates .devcontainer/ with 3 files"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  local ok=true
  for f in devcontainer.json Dockerfile init-firewall.sh; do
    if [[ ! -f "$target/.devcontainer/$f" ]]; then
      fail "$name" "missing $f"
      ok=false
      break
    fi
  done

  if [[ "$ok" == true ]]; then
    if [[ -x "$target/.devcontainer/init-firewall.sh" ]]; then
      pass "$name"
    else
      fail "$name" "init-firewall.sh not executable"
    fi
  fi

  teardown
}

test_default_current_dir() {
  local name="defaults to current directory when no arg"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! (cd "$target" && "$SANDBOX_INIT") >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if [[ -d "$target/.devcontainer" ]]; then
    pass "$name"
  else
    fail "$name" ".devcontainer/ not created"
  fi

  teardown
}

test_existing_without_force() {
  local name="existing .devcontainer/ without --force exits with error"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target/.devcontainer"

  if "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "should have failed but succeeded"
  else
    pass "$name"
  fi

  teardown
}

test_force_creates_backup() {
  local name="--force backs up and overwrites"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target/.devcontainer"
  echo "old" > "$target/.devcontainer/marker.txt"

  if ! "$SANDBOX_INIT" --force "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  # Check backup exists
  local backup_count
  backup_count=$(find "$target" -maxdepth 1 -name ".devcontainer.bak.*" -type d | wc -l)
  if [[ "$backup_count" -eq 0 ]]; then
    fail "$name" "no backup created"
    teardown
    return
  fi

  # Check new devcontainer exists
  if [[ -f "$target/.devcontainer/devcontainer.json" ]]; then
    pass "$name"
  else
    fail "$name" "new .devcontainer/ not created"
  fi

  teardown
}

test_nonexistent_target() {
  local name="non-existent target directory exits with error"
  if "$SANDBOX_INIT" "/tmp/this-does-not-exist-$$" >/dev/null 2>&1; then
    fail "$name" "should have failed but succeeded"
  else
    pass "$name"
  fi
}

test_dry_run() {
  local name="--dry-run creates no files"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  local output
  output=$("$SANDBOX_INIT" --dry-run "$target" 2>&1) || { fail "$name" "non-zero exit"; teardown; return; }

  if [[ -d "$target/.devcontainer" ]]; then
    fail "$name" ".devcontainer/ was created"
  elif echo "$output" | grep -q "dry-run"; then
    pass "$name"
  else
    fail "$name" "missing dry-run output"
  fi

  teardown
}

test_repo_flag() {
  local name="--repo flag changes source URL"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  local output
  output=$("$SANDBOX_INIT" --remote --repo myorg/myrepo --dry-run "$target" 2>&1)

  if echo "$output" | grep -q "myorg/myrepo"; then
    pass "$name"
  else
    fail "$name" "custom repo not reflected in output"
  fi

  teardown
}

test_failed_fetch_cleanup() {
  local name="failed fetch cleans up partial .devcontainer/"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  # Use a bogus repo to trigger fetch failure
  if "$SANDBOX_INIT" --remote --repo "bogus/nonexistent-repo-$$" "$target" >/dev/null 2>&1; then
    fail "$name" "should have failed but succeeded"
    teardown
    return
  fi

  if [[ -d "$target/.devcontainer" ]]; then
    fail "$name" "partial .devcontainer/ was not cleaned up"
  else
    pass "$name"
  fi

  teardown
}

test_local_default() {
  local name="defaults to bundled files (no --remote needed)"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  local ok=true
  for f in devcontainer.json Dockerfile init-firewall.sh; do
    if [[ ! -f "$target/.devcontainer/$f" ]]; then
      fail "$name" "missing $f"
      ok=false
      break
    fi
  done

  if [[ "$ok" == true ]]; then
    pass "$name"
  fi

  teardown
}

test_local_dry_run() {
  local name="dry-run shows copy when using bundled files"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  local output
  output=$("$SANDBOX_INIT" --dry-run "$target" 2>&1) || { fail "$name" "non-zero exit"; teardown; return; }

  if echo "$output" | grep -q "Would copy"; then
    pass "$name"
  else
    fail "$name" "expected 'Would copy' in output"
  fi

  teardown
}

test_unknown_option() {
  local name="unknown option exits with error"
  if "$SANDBOX_INIT" --bogus >/dev/null 2>&1; then
    fail "$name" "should have failed"
  else
    pass "$name"
  fi
}

test_update_bad_repo() {
  local name="--update with bad repo fails and leaves bundled files intact"
  setup

  # Copy sandbox-init and its bundled dir to an isolated location
  local install_dir="$TEST_DIR/install"
  mkdir -p "$install_dir/devcontainer"
  cp "$SANDBOX_INIT" "$install_dir/sandbox-init"
  chmod +x "$install_dir/sandbox-init"
  echo "original" > "$install_dir/devcontainer/devcontainer.json"
  echo "original" > "$install_dir/devcontainer/Dockerfile"
  echo "original" > "$install_dir/devcontainer/init-firewall.sh"
  echo "original" > "$install_dir/devcontainer/sbrun"

  if "$install_dir/sandbox-init" --update --repo "bogus/nonexistent-repo-$$" >/dev/null 2>&1; then
    fail "$name" "should have failed but succeeded"
    teardown
    return
  fi

  # Bundled files should still have original content
  if grep -q "original" "$install_dir/devcontainer/devcontainer.json"; then
    pass "$name"
  else
    fail "$name" "bundled files were corrupted by failed update"
  fi

  teardown
}

test_update_respects_repo_flag() {
  local name="--update respects --repo flag"
  setup

  local install_dir="$TEST_DIR/install"
  mkdir -p "$install_dir/devcontainer"
  cp "$SANDBOX_INIT" "$install_dir/sandbox-init"
  chmod +x "$install_dir/sandbox-init"

  local output
  output=$("$install_dir/sandbox-init" --update --repo "myorg/myrepo" 2>&1) || true

  if echo "$output" | grep -q "myorg/myrepo"; then
    pass "$name"
  else
    fail "$name" "custom repo not reflected in update output"
  fi

  teardown
}

test_gpu_flag() {
  local name="--gpu injects --gpus=all into devcontainer.json"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" --gpu "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if grep -q '"--gpus=all"' "$target/.devcontainer/devcontainer.json"; then
    pass "$name"
  else
    fail "$name" "missing --gpus=all in devcontainer.json"
  fi

  teardown
}

test_no_gpu_by_default() {
  local name="without --gpu, no --gpus=all in devcontainer.json"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if grep -q '"--gpus=all"' "$target/.devcontainer/devcontainer.json"; then
    fail "$name" "found --gpus=all without --gpu flag"
  else
    pass "$name"
  fi

  teardown
}

test_gpu_dry_run() {
  local name="--gpu --dry-run shows GPU injection plan"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  local output
  output=$("$SANDBOX_INIT" --gpu --dry-run "$target" 2>&1) || { fail "$name" "non-zero exit"; teardown; return; }

  if echo "$output" | grep -q "gpus=all"; then
    pass "$name"
  else
    fail "$name" "missing GPU injection in dry-run output"
  fi

  teardown
}

test_firewall_convenience_scripts() {
  local name="fw-reload, fw-add, and default-domains.txt are created"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  local ok=true
  for f in fw-reload fw-add default-domains.txt; do
    if [[ ! -f "$target/.devcontainer/$f" ]]; then
      fail "$name" "missing $f"
      ok=false
      break
    fi
  done

  if [[ "$ok" == true ]]; then
    if [[ -x "$target/.devcontainer/fw-reload" ]] && [[ -x "$target/.devcontainer/fw-add" ]]; then
      pass "$name"
    else
      fail "$name" "fw-reload or fw-add not executable"
    fi
  fi

  teardown
}

test_default_domains_has_content() {
  local name="default-domains.txt contains expected domains"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if grep -q "api.anthropic.com" "$target/.devcontainer/default-domains.txt"; then
    pass "$name"
  else
    fail "$name" "missing expected domain in default-domains.txt"
  fi

  teardown
}

test_md_seeded_by_default() {
  local name="seeds CLAUDE.md and adds it to .gitignore by default"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if [[ ! -f "$target/CLAUDE.md" ]]; then
    fail "$name" "CLAUDE.md was not seeded"
    teardown
    return
  fi

  if [[ ! -f "$target/.gitignore" ]] || ! grep -qxF "CLAUDE.md" "$target/.gitignore"; then
    fail "$name" "CLAUDE.md not added to .gitignore"
    teardown
    return
  fi

  pass "$name"
  teardown
}

test_no_md_flag() {
  local name="--no-md skips CLAUDE.md seed and its .gitignore entry"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" --no-md --no-tmp "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if [[ -f "$target/CLAUDE.md" ]]; then
    fail "$name" "CLAUDE.md was seeded despite --no-md"
  elif [[ -f "$target/.gitignore" ]] && grep -qxF "CLAUDE.md" "$target/.gitignore"; then
    fail "$name" "CLAUDE.md added to .gitignore despite --no-md"
  else
    pass "$name"
  fi

  teardown
}

test_md_no_overwrite() {
  local name="does not overwrite a pre-existing CLAUDE.md"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"
  echo "USER CONTENT" > "$target/CLAUDE.md"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if grep -q "USER CONTENT" "$target/CLAUDE.md"; then
    pass "$name"
  else
    fail "$name" "pre-existing CLAUDE.md was overwritten"
  fi

  teardown
}

test_md_dry_run() {
  local name="--dry-run announces CLAUDE.md seed plan and creates nothing"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  local output
  output=$("$SANDBOX_INIT" --dry-run "$target" 2>&1) || { fail "$name" "non-zero exit"; teardown; return; }

  if [[ -f "$target/CLAUDE.md" || -f "$target/.gitignore" ]]; then
    fail "$name" "dry-run created files"
  elif echo "$output" | grep -q "Would seed.*CLAUDE.md"; then
    pass "$name"
  else
    fail "$name" "missing 'Would seed CLAUDE.md' line"
  fi

  teardown
}

test_md_gitignore_idempotent() {
  local name="CLAUDE.md entry not duplicated if already in .gitignore"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"
  printf 'node_modules\nCLAUDE.md\n' > "$target/.gitignore"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  local count
  count=$(grep -cxF "CLAUDE.md" "$target/.gitignore")
  if [[ "$count" -eq 1 ]]; then
    pass "$name"
  else
    fail "$name" "expected 1 'CLAUDE.md' line, got $count"
  fi

  teardown
}

test_tmp_dir_created() {
  local name=".tmp/ created with runs/scratch/notes subdirs and gitignored"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  local ok=true
  for sub in runs scratch notes; do
    if [[ ! -d "$target/.tmp/$sub" ]]; then
      fail "$name" "missing .tmp/$sub"
      ok=false
      break
    fi
    if [[ ! -f "$target/.tmp/$sub/.gitkeep" ]]; then
      fail "$name" "missing .tmp/$sub/.gitkeep"
      ok=false
      break
    fi
  done

  if [[ "$ok" == true ]]; then
    if grep -qxF ".tmp/" "$target/.gitignore"; then
      pass "$name"
    else
      fail "$name" ".tmp/ not in .gitignore"
    fi
  fi

  teardown
}

test_no_tmp_flag() {
  local name="--no-tmp skips .tmp/ creation"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" --no-tmp --no-md "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if [[ -d "$target/.tmp" ]]; then
    fail "$name" ".tmp/ was created despite --no-tmp"
  elif [[ -f "$target/.gitignore" ]] && grep -qxF ".tmp/" "$target/.gitignore"; then
    fail "$name" ".tmp/ was added to .gitignore despite --no-tmp"
  else
    pass "$name"
  fi

  teardown
}

test_tmp_no_overwrite() {
  local name="does not overwrite a pre-existing .tmp/ directory"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target/.tmp"
  echo "user data" > "$target/.tmp/user-file.txt"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if [[ -f "$target/.tmp/user-file.txt" ]] && grep -q "user data" "$target/.tmp/user-file.txt"; then
    pass "$name"
  else
    fail "$name" "pre-existing .tmp/ contents were lost"
  fi

  teardown
}

test_tmp_dry_run() {
  local name="--dry-run announces .tmp/ creation plan but creates nothing"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  local output
  output=$("$SANDBOX_INIT" --dry-run "$target" 2>&1) || { fail "$name" "non-zero exit"; teardown; return; }

  if [[ -d "$target/.tmp" ]]; then
    fail "$name" "dry-run created .tmp/"
  elif echo "$output" | grep -q "Would create.*\.tmp/"; then
    pass "$name"
  else
    fail "$name" "missing 'Would create .tmp/' line"
  fi

  teardown
}

test_skills_seeded_by_default() {
  local name="seeds .claude/skills/ tree by default"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  local ok=true
  for mode in plan impl results codebase; do
    if [[ ! -f "$target/.claude/skills/review-$mode/SKILL.md" ]]; then
      fail "$name" "missing review-$mode/SKILL.md"
      ok=false
      break
    fi
    if [[ ! -f "$target/.claude/skills/review-$mode/prompt-template.md" ]]; then
      fail "$name" "missing review-$mode/prompt-template.md"
      ok=false
      break
    fi
  done

  if [[ "$ok" == true ]]; then
    if [[ ! -f "$target/.claude/skills/_lib/codex-exec.sh" ]]; then
      fail "$name" "missing _lib/codex-exec.sh"
    elif [[ ! -f "$target/.claude/skills/_lib/preamble.md" ]]; then
      fail "$name" "missing _lib/preamble.md"
    else
      pass "$name"
    fi
  fi

  teardown
}

test_no_skills_flag() {
  local name="--no-skills skips skill tree creation"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" --no-skills --no-md --no-tmp "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if [[ -d "$target/.claude/skills" ]]; then
    fail "$name" ".claude/skills/ created despite --no-skills"
  else
    pass "$name"
  fi

  teardown
}

test_skills_no_overwrite() {
  local name="does not overwrite a pre-existing .claude/skills/ tree"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target/.claude/skills/custom-skill"
  echo "USER" > "$target/.claude/skills/custom-skill/SKILL.md"

  local output
  output=$("$SANDBOX_INIT" "$target" 2>&1) || { fail "$name" "command failed"; teardown; return; }

  if grep -q "USER" "$target/.claude/skills/custom-skill/SKILL.md" \
      && echo "$output" | grep -qi "skipping"; then
    pass "$name"
  else
    fail "$name" "pre-existing skills tree was modified or no skip message"
  fi

  teardown
}

test_skills_dry_run() {
  local name="--dry-run announces .claude/skills/ seed plan and creates nothing"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  local output
  output=$("$SANDBOX_INIT" --dry-run "$target" 2>&1) || { fail "$name" "non-zero exit"; teardown; return; }

  if [[ -d "$target/.claude/skills" ]]; then
    fail "$name" "dry-run created skills tree"
  elif echo "$output" | grep -q "Would copy.*claude-skills"; then
    pass "$name"
  else
    fail "$name" "missing 'Would copy ... claude-skills' line"
  fi

  teardown
}

test_skills_prompt_amp_backslash_safe() {
  local name="codex-exec.sh prompt assembly preserves & and \\ in body content"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "sandbox-init failed"
    teardown
    return
  fi

  # Plan content with characters that historically corrupted the prompt
  # (awk/bash-5 treat & as a back-reference; backslash is also special).
  cat > "$target/test-plan.md" <<'EOF'
# Plan
- Use `npm install && npm test`
- Capture: `cmd 2>&1 | tee log`
- Path: `\\server\share`
- Literal placeholder: {{NESTED}}
EOF

  # Stub codex so we exercise prompt assembly without firing the real CLI.
  mkdir -p "$target/stub-bin"
  cat > "$target/stub-bin/codex" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$target/stub-bin/codex"

  (
    cd "$target" || exit 1
    PATH="$target/stub-bin:$PATH" bash .claude/skills/_lib/codex-exec.sh plan test-plan.md >/dev/null 2>&1
  )

  local prompt
  prompt=$(find "$target/.tmp/runs" -name prompt.md -type f 2>/dev/null | head -1)
  if [[ -z "$prompt" ]]; then
    fail "$name" "no prompt.md was written"
    teardown
    return
  fi

  if grep -qF '{{PLAN_BODY}}' "$prompt"; then
    fail "$name" "{{PLAN_BODY}} placeholder leaked into prompt (& or \\ corruption)"
  elif ! grep -qF 'npm install && npm test' "$prompt"; then
    fail "$name" "literal '&&' was not preserved in prompt"
  elif ! grep -qF '2>&1' "$prompt"; then
    fail "$name" "literal '2>&1' was not preserved in prompt"
  else
    pass "$name"
  fi

  teardown
}

test_skills_helper_executable() {
  local name="codex-exec.sh has executable bit set after seed"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" "$target" >/dev/null 2>&1; then
    fail "$name" "command failed"
    teardown
    return
  fi

  if [[ -x "$target/.claude/skills/_lib/codex-exec.sh" ]]; then
    pass "$name"
  else
    fail "$name" "codex-exec.sh is not executable"
  fi

  teardown
}

# --- Run ---

echo "Running sandbox-init tests..."
echo ""

test_help
test_version
test_happy_path
test_default_current_dir
test_existing_without_force
test_force_creates_backup
test_nonexistent_target
test_dry_run
test_repo_flag
test_failed_fetch_cleanup
test_local_default
test_local_dry_run
test_unknown_option
test_update_bad_repo
test_update_respects_repo_flag
test_gpu_flag
test_no_gpu_by_default
test_gpu_dry_run
test_firewall_convenience_scripts
test_default_domains_has_content
test_md_seeded_by_default
test_no_md_flag
test_md_no_overwrite
test_md_dry_run
test_md_gitignore_idempotent
test_tmp_dir_created
test_no_tmp_flag
test_tmp_no_overwrite
test_tmp_dry_run
test_skills_seeded_by_default
test_no_skills_flag
test_skills_no_overwrite
test_skills_dry_run
test_skills_helper_executable
test_skills_prompt_amp_backslash_safe

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped"

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
