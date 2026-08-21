# Lite+tmux variant: dev tools + AI agents + byobu, no cloud CLIs (AWS/GCP)
# For the full image with cloud CLIs, use Dockerfile
FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Remap vscode user to macOS-default UID/GID (501:20)
# GID 20 is typically 'dialout' on Ubuntu — move it out of the way first
RUN if getent group 20 > /dev/null 2>&1; then \
        groupmod -g 9999 "$(getent group 20 | cut -d: -f1)"; \
    fi && \
    groupmod -g 20 vscode && \
    usermod -u 501 -g 20 vscode && \
    chown -R 501:20 /home/vscode

# ---------------------------------------------------------------------------
# Tier 1 — stable. Only rebuilt when this file changes.
# ---------------------------------------------------------------------------

# Base system dependencies and utilities
# Re-include byobu docs/man (base image minimized via /etc/dpkg/dpkg.cfg.d/excludes)
# Filename zz- ensures this is processed AFTER excludes so includes win
# Remove man stub diversion so man-db can install the real man binary
# --no-install-recommends keeps the layer lean; less is listed explicitly
# because man-db only Recommends a pager and man is unusable without one.
RUN printf 'path-include /usr/share/doc/byobu/*\npath-include /usr/share/man/man1/byobu*\n' > /etc/dpkg/dpkg.cfg.d/zz-byobu && \
    rm -f /usr/bin/man && dpkg-divert --quiet --remove --rename /usr/bin/man && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        curl wget unzip \
        jq yq \
        vim nano less \
        make \
        build-essential \
        file \
        python3 python3-pip \
        byobu \
        man-db \
        iputils-ping \
        dnsutils \
        traceroute \
        net-tools \
        netcat-openbsd \
        tcpdump \
        telnet \
        nmap && \
    chsh -s /usr/bin/zsh vscode && \
    # Cleanup
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Chromium's system dependencies, so headless browsers fetched by Playwright,
# Puppeteer & co. start without an apt run (see issue #31). This is Playwright's
# complete `install-deps chromium` table for this Ubuntu release -- runtime
# libraries, xvfb for headed mode, and the fonts it expects for Latin, CJK,
# Thai and emoji coverage -- so `playwright install-deps --dry-run chromium`
# reports clean and the smoke tests assert exactly that. ~175 MB of the ~300 MB
# is mesa+LLVM behind libgbm1, which Chromium links directly; the rest is
# mostly fonts. The browser build itself is deliberately NOT baked in: its
# revision is pinned by each project's playwright version, and
# ~/.cache/ms-playwright lives on the home volume so it survives rebuilds.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
        libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 \
        libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 \
        libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 \
        xvfb libfontconfig1 libfreetype6 \
        fonts-liberation fonts-noto-color-emoji fonts-unifont fonts-freefont-ttf \
        fonts-ipafont-gothic fonts-wqy-zenhei fonts-tlwg-loma-otf \
        xfonts-cyrillic xfonts-scalable && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Tier 2 — toolchains and CLIs. These float to whatever is current at build
# time, but they rarely change day to day, so the daily workflow only busts
# them once a week (TOOLCHAIN_REFRESH carries an ISO week number). Six nights
# out of seven these layers come straight from cache.
# ---------------------------------------------------------------------------
ARG TOOLCHAIN_REFRESH

# Layer 1: Install Node.js LTS
# nodesource's setup script runs apt-get update, so this layer has to drop the
# package lists itself — a later RUN cannot reclaim space from an earlier one.
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Layer 2: Install GitHub CLI and Docker CLI
# Docker is client-only (docker-ce-cli + buildx/compose plugins): the daemon is
# the host's, reached over a docker.sock mount at deploy time. No docker-ce or
# containerd — that would be docker-in-docker and needs a privileged container.
RUN ARCH=$(dpkg --print-architecture) && \
    mkdir -p -m 755 /etc/apt/keyrings && \
    wget -nv -O- https://cli.github.com/packages/githubcli-archive-keyring.gpg > /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends gh \
        docker-ce-cli docker-buildx-plugin docker-compose-plugin && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Layer 3: single-binary tools tracked by upstream :latest tags. Kept at the
# bottom of this tier so a new upstream digest invalidates only these two tiny
# layers rather than every toolchain above them.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv
COPY --from=ghcr.io/j178/prek:latest /prek /usr/local/bin/prek

# ---------------------------------------------------------------------------
# Tier 3 — AI CLIs. These genuinely ship most days, so they carry the daily
# cache-bust and sit last, where rebuilding them costs the least.
# ---------------------------------------------------------------------------
ARG AI_CACHEBUST

USER vscode

# Install Claude Code, and stage a copy outside /home/vscode so it survives a
# volume mount. Install and stage share one layer and the staged copy is
# hardlinked, so the second copy costs ~0 bytes instead of duplicating ~80 MB.
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    CLAUDE_VERSION=$(basename "$(readlink /home/vscode/.local/bin/claude)") && \
    sudo mkdir -p /opt/claude-image/versions && \
    sudo cp -al /home/vscode/.local/share/claude/versions/"${CLAUDE_VERSION}" \
                /opt/claude-image/versions/ && \
    echo "${CLAUDE_VERSION}" | sudo tee /opt/claude-image/version > /dev/null

# Install OpenAI Codex, dropping the npm tarball cache it leaves behind
RUN sudo npm install -g @openai/codex && \
    sudo npm cache clean --force && \
    npm cache clean --force

# ---------------------------------------------------------------------------
# Shell configuration last: editing .zshrc or .p10k.zsh then rebuilds ~1 MB
# instead of invalidating the AI tool layers above it.
# ---------------------------------------------------------------------------
COPY --chown=vscode:vscode config/.zshrc /home/vscode/.zshrc
COPY --chown=vscode:vscode config/.p10k.zsh /home/vscode/.p10k.zsh
RUN git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
    ${ZSH_CUSTOM:-/home/vscode/.oh-my-zsh/custom}/themes/powerlevel10k && \
    # Enable byobu auto-launch on login
    printf '_byobu_sourced=1 . /usr/bin/byobu-launch 2>/dev/null || true\n' >> ~/.zprofile && \
    printf '_byobu_sourced=1 . /usr/bin/byobu-launch 2>/dev/null || true\n' >> ~/.profile

# Lazy Homebrew: /usr/local/bin/brew is a shim that installs Homebrew into
# /home/linuxbrew/.linuxbrew on first use — the image carries zero Homebrew
# bytes, and deployments mount a volume at /home/linuxbrew to persist
# installs. PATH lists the real prefix first, so the shim is unreachable once
# Homebrew exists. /home/linuxbrew must stay a real directory, never a
# symlink into /home/vscode: bin/brew resolves its location with `pwd -P`,
# and Linux bottles only work at the literal /home/linuxbrew/.linuxbrew
# physical prefix.
COPY --chmod=0755 scripts/brew-shim.sh /usr/local/bin/brew
RUN sudo install -d -o vscode -g vscode /home/linuxbrew

# Final environment setup
ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/home/vscode/.local/bin:${PATH}"
ENV SHELL=/usr/bin/zsh
ENV DISABLE_AUTOUPDATER=true

# Entrypoint: sync Claude from image layer into volume on start
COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

USER vscode
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["zsh", "-l"]
