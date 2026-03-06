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
  output=$("$SANDBOX_INIT" --repo myorg/myrepo --dry-run "$target" 2>&1)

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
  if "$SANDBOX_INIT" --repo "bogus/nonexistent-repo-$$" "$target" >/dev/null 2>&1; then
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

test_local_flag() {
  local name="--local copies bundled files without network"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  if ! "$SANDBOX_INIT" --local "$target" >/dev/null 2>&1; then
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
  local name="--local --dry-run shows copy instead of fetch"
  setup
  local target="$TEST_DIR/project"
  mkdir -p "$target"

  local output
  output=$("$SANDBOX_INIT" --local --dry-run "$target" 2>&1) || { fail "$name" "non-zero exit"; teardown; return; }

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
test_local_flag
test_local_dry_run
test_unknown_option

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped"

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
