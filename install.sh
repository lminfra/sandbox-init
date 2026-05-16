#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_NAME="sandbox-init"
SYMLINK_NAME="sbinit"
DEVC_NAME="devc"
UPSTREAM_BASE="https://raw.githubusercontent.com/anthropics/claude-code/main/.devcontainer"
DEVCONTAINER_FILES=("devcontainer.json" "Dockerfile" "init-firewall.sh" "default-domains.txt" "fw-reload" "fw-add" "sbrun" "patch-cs-folder.sh")

die() {
  echo "error: $1" >&2
  exit 1
}

info() {
  echo "=> $1"
}

# Parse flags
USE_UPSTREAM=false
DO_UNINSTALL=false
DO_FETCH_BWRAP=true
for arg in "$@"; do
  case "$arg" in
    --upstream) USE_UPSTREAM=true ;;
    --uninstall) DO_UNINSTALL=true ;;
    --no-fetch-bwrap) DO_FETCH_BWRAP=false ;;
    *) die "Unknown option: $arg (supported: --upstream, --uninstall, --no-fetch-bwrap)" ;;
  esac
done

# Probe: does a bwrap binary at $1 actually work (can it create a namespace)?
bwrap_ok() {
  "$1" --ro-bind / / --unshare-all --die-with-parent true >/dev/null 2>&1
}

# Fetch a user-local bwrap binary (no root) so Codex's sandboxed review skills
# can run `--sandbox read-only` instead of falling back to the unsandboxed
# danger-full-access mode. Runs by default on every install; suppress with
# --no-fetch-bwrap. Every failure path below is non-fatal (warns and returns):
# the function only actually downloads when it both can help and can succeed
# (Debian/Ubuntu, unprivileged user namespaces enabled, bwrap binary absent).
fetch_bwrap() {
  local dest="${INSTALL_DIR}/bwrap"

  if command -v bwrap >/dev/null 2>&1 && bwrap_ok bwrap; then
    info "bwrap already present and working — no provisioning needed"
    return 0
  fi

  # If the kernel forbids unprivileged user namespaces, a bwrap binary would
  # still fail — this is the un-fixable case, so don't bother downloading.
  if ! unshare -Urm true >/dev/null 2>&1; then
    echo ""
    echo "WARNING: bwrap setup: unprivileged user namespaces are disabled on"
    echo "this host (e.g. kernel.apparmor_restrict_unprivileged_userns=1), so a"
    echo "bwrap binary would still fail. Skipping. Codex review falls back to"
    echo "unsandboxed danger-full-access; set CODEX_SANDBOX_OVERRIDE to choose."
    echo ""
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    echo ""
    echo "WARNING: bwrap setup needs apt-get + dpkg (Debian/Ubuntu). Skipping."
    echo "Install bubblewrap via your platform's package manager instead."
    echo ""
    return 0
  fi

  info "Fetching a user-local bwrap binary (no root required)..."
  local tmp
  tmp="$(mktemp -d)"
  if ! ( cd "$tmp" && apt-get download bubblewrap >/dev/null 2>&1 ); then
    rm -rf "$tmp"
    echo "WARNING: bwrap setup: 'apt-get download bubblewrap' failed. Skipping." >&2
    return 0
  fi
  local deb
  deb="$(find "$tmp" -maxdepth 1 -name 'bubblewrap_*.deb' | head -1 || true)"
  if [[ -z "$deb" ]] || ! dpkg -x "$deb" "${tmp}/x" 2>/dev/null \
     || [[ ! -f "${tmp}/x/usr/bin/bwrap" ]]; then
    rm -rf "$tmp"
    echo "WARNING: bwrap setup: could not extract bwrap from the package. Skipping." >&2
    return 0
  fi
  cp "${tmp}/x/usr/bin/bwrap" "$dest"
  chmod +x "$dest"
  rm -rf "$tmp"

  if bwrap_ok "$dest"; then
    info "Installed working bwrap -> ${dest}"
  else
    echo "WARNING: bwrap setup: installed ${dest} but it failed a sandbox" >&2
    echo "self-test; Codex review will fall back to danger-full-access." >&2
  fi
}

# Handle uninstall
if [[ "$DO_UNINSTALL" == true ]]; then
  removed=0
  for target in "${INSTALL_DIR}/${SCRIPT_NAME}" "${INSTALL_DIR}/${SYMLINK_NAME}" "${INSTALL_DIR}/${DEVC_NAME}"; do
    if [[ -e "$target" || -L "$target" ]]; then
      rm -f "$target"
      info "Removed $target"
      removed=$((removed + 1))
    fi
  done
  if [[ -d "${INSTALL_DIR}/devcontainer" ]]; then
    rm -rf "${INSTALL_DIR}/devcontainer"
    info "Removed ${INSTALL_DIR}/devcontainer/"
    removed=$((removed + 1))
  fi
  if [[ "$removed" -eq 0 ]]; then
    info "Nothing to remove (already uninstalled)"
  else
    info "Uninstall complete"
  fi
  exit 0
fi

# Determine source: local file or remote
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/${SCRIPT_NAME}"

BUNDLED_DIR_NAME="devcontainer"

if [[ ! -f "$SOURCE" ]]; then
  # Remote install: fetch from GitHub
  info "Downloading sandbox-init..."
  SOURCE="$(mktemp)"
  REMOTE_URL="https://raw.githubusercontent.com/lminfra/sandbox-init/main/sandbox-init"
  if ! curl -fsSL -o "$SOURCE" "$REMOTE_URL"; then
    rm -f "$SOURCE"
    die "Failed to download sandbox-init"
  fi
  CLEANUP_SOURCE=true
else
  CLEANUP_SOURCE=false
fi

# Create install directory
mkdir -p "$INSTALL_DIR"

# Install the script
info "Copying ${SCRIPT_NAME} -> ${INSTALL_DIR}/${SCRIPT_NAME}"
cp "$SOURCE" "${INSTALL_DIR}/${SCRIPT_NAME}"
chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"

# Install devc wrapper
DEVC_SOURCE="${SCRIPT_DIR}/${DEVC_NAME}"
if [[ -f "$DEVC_SOURCE" ]]; then
  info "Copying ${DEVC_NAME} -> ${INSTALL_DIR}/${DEVC_NAME}"
  cp "$DEVC_SOURCE" "${INSTALL_DIR}/${DEVC_NAME}"
  chmod +x "${INSTALL_DIR}/${DEVC_NAME}"
fi

# Install devcontainer files
BUNDLED_DEST="${INSTALL_DIR}/${BUNDLED_DIR_NAME}"
if [[ -d "$BUNDLED_DEST" ]]; then
  info "Removing old ${BUNDLED_DEST}/"
  rm -rf "$BUNDLED_DEST"
fi

if [[ "$USE_UPSTREAM" == true ]]; then
  info "Downloading devcontainer files from upstream (anthropics/claude-code)..."
  mkdir -p "$BUNDLED_DEST"
  for f in "${DEVCONTAINER_FILES[@]}"; do
    info "  Fetching ${f} -> ${BUNDLED_DEST}/${f}"
    if ! curl -fsSL -o "${BUNDLED_DEST}/${f}" "${UPSTREAM_BASE}/${f}"; then
      rm -rf "$BUNDLED_DEST"
      die "Failed to download ${f}"
    fi
  done
  chmod +x "${BUNDLED_DEST}/init-firewall.sh"
elif [[ -d "${SCRIPT_DIR}/${BUNDLED_DIR_NAME}" ]]; then
  info "Copying bundled devcontainer files:"
  cp -r "${SCRIPT_DIR}/${BUNDLED_DIR_NAME}" "$BUNDLED_DEST"
  for f in "${DEVCONTAINER_FILES[@]}"; do
    info "  ${f} -> ${BUNDLED_DEST}/${f}"
  done
  echo ""
  echo "  Note: These files include modifications over the upstream claude-code version:"
  echo "    - Cursor domains added to the firewall whitelist"
  echo "    - DNS resolution failures are non-fatal (warns instead of aborting)"
  echo "  To use the official anthropics/claude-code files instead, re-run:"
  echo "    ./install.sh --upstream"
  echo ""
else
  die "Bundled devcontainer files not found at ${SCRIPT_DIR}/${BUNDLED_DIR_NAME} (are you running from the repo?)"
fi

# Create symlink
info "Creating symlink ${SYMLINK_NAME} -> ${SCRIPT_NAME} in ${INSTALL_DIR}/"
ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${INSTALL_DIR}/${SYMLINK_NAME}"

# Cleanup temp file if remote install
if [[ "$CLEANUP_SOURCE" == true ]]; then
  rm -f "$SOURCE"
fi

# Provision a user-local bwrap for Codex's sandboxed review modes (default on;
# disable with --no-fetch-bwrap). No-op when bwrap already works or can't help.
if [[ "$DO_FETCH_BWRAP" == true ]]; then
  fetch_bwrap
fi

# Check devcontainer CLI
if ! command -v devcontainer &>/dev/null; then
  echo ""
  echo "NOTE: The 'devcontainer' CLI was not found on your PATH."
  echo "'devc' requires it to start and enter containers."
  echo "Install it via npm:"
  echo ""
  echo "  npm install -g @devcontainers/cli"
  echo ""
fi

# Check PATH
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  echo ""
  echo "WARNING: ${INSTALL_DIR} is not in your PATH."
  echo "Add it by appending this to your shell profile (~/.bashrc or ~/.zshrc):"
  echo ""
  echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
  echo ""
fi

info "Done! Run 'sbinit --help' or 'devc --help' to get started."
