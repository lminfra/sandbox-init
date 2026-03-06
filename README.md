# sandbox-init (`sbinit`)

One-command setup for Claude Code devcontainer isolation.

Fetches the official devcontainer configuration from [anthropics/claude-code](https://github.com/anthropics/claude-code/tree/main/.devcontainer) and sets up your project for sandboxed development.

## Prerequisites

- [Docker](https://www.docker.com/) installed and running
- [VS Code](https://code.visualstudio.com/) or [Cursor](https://cursor.com/) with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension
- `curl`

## Install

```bash
# From the repo (includes bundled devcontainer files for --local usage)
git clone https://github.com/lminfra/sandbox-init.git
cd sandbox-init
./install.sh

# Or directly (fetches from GitHub at runtime)
curl -fsSL https://raw.githubusercontent.com/lminfra/sandbox-init/main/install.sh | bash
```

## Usage

```bash
# Set up devcontainer in current directory
sbinit

# Set up in a specific directory
sbinit /path/to/my-project

# Overwrite existing .devcontainer/ (backs up first)
sbinit --force

# Preview what would happen
sbinit --dry-run

# Use bundled files (no network fetch, requires repo clone install)
sbinit --local

# Use a fork or custom repo
sbinit --repo myorg/my-claude-config --branch develop
```

## Tutorial

```bash
# 1. Create a new project
mkdir my-project && cd my-project
git init

# 2. Set up the devcontainer
sbinit .

# 3. Open in your editor
#    VS Code: code .
#    Cursor:  cursor .

# 4. From the command palette (Ctrl+Shift+P / Cmd+Shift+P):
#    Run "Dev Containers: Reopen in Container"

# 5. Claude Code is ready inside the container
```

## What gets created

Running `sbinit` creates a `.devcontainer/` directory with three files:

| File | Purpose |
|------|---------|
| `devcontainer.json` | Container config: Node 20 base, VS Code extensions, persistent volumes, ZSH terminal |
| `Dockerfile` | Image: Node 20, dev tools (git, gh, fzf, zsh, vim, jq), Claude Code CLI, iptables |
| `init-firewall.sh` | Network security: default-deny firewall, whitelists GitHub, npm, Anthropic API only |

## Options

| Flag | Description |
|------|-------------|
| `TARGET_DIR` | Directory to set up (default: current directory) |
| `--repo OWNER/REPO` | Override source repo (default: `anthropics/claude-code`) |
| `--branch BRANCH` | Override source branch (default: `main`) |
| `--local` | Use bundled devcontainer files instead of fetching from GitHub |
| `-f`, `--force` | Overwrite existing `.devcontainer/` (backs up old one first) |
| `--dry-run` | Show what would be done, change nothing |
| `--update` | Self-update the tool |
| `-v`, `--version` | Print version |
| `-h`, `--help` | Print usage |

## Customization

After running `sbinit`, you can edit the fetched files to customize your setup. Common modifications:

- **Add VS Code extensions**: Edit `devcontainer.json` → `customizations.vscode.extensions`
- **Install additional tools**: Edit `Dockerfile` to add `apt-get install` packages
- **Allow more domains**: Edit `init-firewall.sh` to whitelist additional hosts

## Uninstall

```bash
rm ~/.local/bin/sandbox-init ~/.local/bin/sbinit
```

## Acknowledgments

- Devcontainer files (`devcontainer.json`, `Dockerfile`, `init-firewall.sh`) are sourced from [anthropics/claude-code](https://github.com/anthropics/claude-code/tree/main/.devcontainer)
- Setup workflow based on the [Claude Code devcontainer documentation](https://docs.anthropic.com/en/docs/claude-code/bedrock-vertex#using-a-devcontainer)

## License

MIT
