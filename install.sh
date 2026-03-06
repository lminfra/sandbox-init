#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_NAME="sandbox-init"
SYMLINK_NAME="sbinit"

die() {
  echo "error: $1" >&2
  exit 1
}

info() {
  echo "=> $1"
}

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
cp "$SOURCE" "${INSTALL_DIR}/${SCRIPT_NAME}"
chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"

# Install bundled devcontainer files if available (enables --local flag)
if [[ -d "${SCRIPT_DIR}/${BUNDLED_DIR_NAME}" ]]; then
  cp -r "${SCRIPT_DIR}/${BUNDLED_DIR_NAME}" "${INSTALL_DIR}/${BUNDLED_DIR_NAME}"
  info "Installed bundled devcontainer files (use --local to skip network fetch)"
fi

# Create symlink
ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${INSTALL_DIR}/${SYMLINK_NAME}"

# Cleanup temp file if remote install
if [[ "$CLEANUP_SOURCE" == true ]]; then
  rm -f "$SOURCE"
fi

info "Installed ${SCRIPT_NAME} to ${INSTALL_DIR}/${SCRIPT_NAME}"
info "Created symlink ${SYMLINK_NAME} -> ${SCRIPT_NAME}"

# Check PATH
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  echo ""
  echo "WARNING: ${INSTALL_DIR} is not in your PATH."
  echo "Add it by appending this to your shell profile (~/.bashrc or ~/.zshrc):"
  echo ""
  echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
  echo ""
fi

info "Done! Run 'sandbox-init --help' to get started."
