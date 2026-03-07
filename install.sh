#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_NAME="sandbox-init"
SYMLINK_NAME="sbinit"
UPSTREAM_BASE="https://raw.githubusercontent.com/anthropics/claude-code/main/.devcontainer"
DEVCONTAINER_FILES=("devcontainer.json" "Dockerfile" "init-firewall.sh" "sbrun")

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
for arg in "$@"; do
  case "$arg" in
    --upstream) USE_UPSTREAM=true ;;
    --uninstall) DO_UNINSTALL=true ;;
    *) die "Unknown option: $arg (supported: --upstream, --uninstall)" ;;
  esac
done

# Handle uninstall
if [[ "$DO_UNINSTALL" == true ]]; then
  removed=0
  for target in "${INSTALL_DIR}/${SCRIPT_NAME}" "${INSTALL_DIR}/${SYMLINK_NAME}"; do
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

# Check PATH
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  echo ""
  echo "WARNING: ${INSTALL_DIR} is not in your PATH."
  echo "Add it by appending this to your shell profile (~/.bashrc or ~/.zshrc):"
  echo ""
  echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
  echo ""
fi

info "Done! Run 'sbinit --help' to get started."
