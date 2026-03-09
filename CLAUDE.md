# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`sandbox-init` (`sbinit`) is a one-command setup tool for Claude Code devcontainer isolation. It copies bundled devcontainer config files into a project's `.devcontainer/` directory, enabling secure sandboxed development via Docker with a default-deny firewall.

## Commands

**Lint:**
```bash
shellcheck sandbox-init install.sh tests/test_sandbox_init.sh
```

**Run tests:**
```bash
bash tests/test_sandbox_init.sh
```

**CI runs both shellcheck and tests on Ubuntu + macOS** (see `.github/workflows/test.yml`).

## Architecture

Two-stage tool: `install.sh` installs the `sbinit` command globally, then `sbinit` sets up individual projects.

### Key files

- **`sandbox-init`** — Main CLI script. Parses args, resolves target dir, copies/fetches 4 devcontainer files (devcontainer.json, Dockerfile, init-firewall.sh, sbrun). Defaults to bundled files; `--remote` fetches from GitHub.
- **`install.sh`** — Installer. Downloads `sandbox-init` to `~/.local/bin/`, bundles devcontainer files alongside it, creates `sbinit` symlink. Supports `--uninstall`.
- **`devcontainer/`** — Bundled devcontainer files that get copied into projects:
  - `devcontainer.json` — Container config with IDE extensions, mounts, capabilities
  - `Dockerfile` — Node 20 base image with dev tools, Claude Code CLI, zsh
  - `init-firewall.sh` — Default-deny iptables firewall whitelisting GitHub, npm, Anthropic, VS Code, and Cursor domains
  - `sbrun` — Shortcut to run `claude --dangerously-skip-permissions`
- **`tests/test_sandbox_init.sh`** — 14 test cases covering happy path, error handling, force/backup, dry-run, bundled vs remote modes

### Design patterns

- **Bundled-first:** Defaults to local bundled files for reliability; `--remote` forces GitHub fetch; auto-falls back to remote if bundled files missing.
- **Cleanup on failure:** Trap handlers remove partial `.devcontainer/` on errors. Force mode backs up existing dirs with timestamps.
- **All scripts are pure bash** — no external dependencies beyond standard Unix tools and `curl` (for remote fetches).
