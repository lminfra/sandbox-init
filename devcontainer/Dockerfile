FROM node:20

ARG TZ
ENV TZ="$TZ"

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  tmux \
  locales \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Install Claude
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/node/.local/bin:$PATH"

# Install Codex
RUN npm install -g @openai/codex

# In a containerized/remote env there's usually no browser, so transparently
# rewrite `codex login` to `codex login --device-auth` (with a notice).
# Pass-through if the user already supplied --device-auth, --help, or -h.
RUN printf '%s\n' \
  '' \
  '# sbinit: prefer device-auth for `codex login` (no browser in containerized env)' \
  'codex() {' \
  '  if [[ "$1" == "login" ]]; then' \
  '    for arg in "${@:2}"; do' \
  '      case "$arg" in --device-auth|--help|-h) command codex "$@"; return $? ;; esac' \
  '    done' \
  '    echo "=> [sbinit] codex login: using --device-auth (no browser in containerized/remote env)"' \
  '    command codex login --device-auth "${@:2}"' \
  '  else' \
  '    command codex "$@"' \
  '  fi' \
  '}' \
  >> /home/node/.zshrc

# Install Miniconda (detect arch for Apple Silicon / ARM support)
RUN ARCH="$(uname -m)" && \
  wget -q "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${ARCH}.sh" -O /tmp/miniconda.sh && \
  bash /tmp/miniconda.sh -b -p /home/node/miniconda3 && \
  rm /tmp/miniconda.sh
ENV PATH="/home/node/miniconda3/bin:$PATH"

# Copy and set up firewall script, sbrun shortcut, and code-server folder patcher
COPY init-firewall.sh /usr/local/bin/
COPY default-domains.txt /usr/local/bin/
COPY fw-reload /usr/local/bin/
COPY fw-add /usr/local/bin/
COPY sbrun /usr/local/bin/
COPY patch-cs-folder.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/fw-reload /usr/local/bin/fw-add /usr/local/bin/sbrun /usr/local/bin/patch-cs-folder.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/patch-cs-folder.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall
USER node
