# Based on Microsoft's devcontainer base image with batteries-included development tools
# Optimized for daily autobuilds with proper layer caching
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

# ---------------------------------------------------------------------------
# Tier 2 — language toolchains and cloud CLIs. These float to whatever is
# current at build time, but they rarely change day to day, so the daily
# workflow only busts them once a week (TOOLCHAIN_REFRESH carries an ISO week
# number). Six nights out of seven these layers come straight from cache.
# ---------------------------------------------------------------------------
ARG TOOLCHAIN_REFRESH

# Layer 1: Install Go (latest stable, fetched from go.dev)
# go/test is the compiler's own test corpus and is dead weight in an image.
RUN GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n 1) && \
    ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -xzC /usr/local && \
    rm -rf /usr/local/go/test && \
    echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile

# Layer 2: Install Rust
# Installed under /usr/local rather than rustup's default ~/.cargo: a named
# volume mounted at /home/vscode shadows the image layer, which would hide the
# toolchain entirely at runtime. The minimal profile drops rust-docs (several
# hundred MB of HTML); clippy and rustfmt are added back explicitly.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --no-modify-path --profile minimal -c clippy -c rustfmt && \
    chmod -R a+w "$RUSTUP_HOME" "$CARGO_HOME" && \
    echo 'export PATH=/usr/local/cargo/bin:$PATH' >> /etc/profile

# Layer 3: Install Node.js LTS
# nodesource's setup script runs apt-get update, so this layer has to drop the
# package lists itself — a later RUN cannot reclaim space from an earlier one.
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Layer 4: Install cloud CLIs (AWS, Google Cloud), GitHub CLI, and Docker CLI
# Pointing gcloud at the system interpreter lets the bundled one go, if the
# package ships one at all.
# Docker is client-only (docker-ce-cli + buildx/compose plugins): the daemon is
# the host's, reached over a docker.sock mount at deploy time. No docker-ce or
# containerd — that would be docker-in-docker and needs a privileged container.
ENV CLOUDSDK_PYTHON=/usr/bin/python3
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
        amd64) AWS_ARCH=x86_64 ;; \
        arm64) AWS_ARCH=aarch64 ;; \
        *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o awscliv2.zip && \
    unzip -q awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip && \
    # Install Google Cloud CLI
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list && \
    # Install GitHub CLI
    mkdir -p -m 755 /etc/apt/keyrings && \
    wget -nv -O- https://cli.github.com/packages/githubcli-archive-keyring.gpg > /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    # Install Docker CLI (client only — see layer comment above)
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-cloud-cli gh \
        docker-ce-cli docker-buildx-plugin docker-compose-plugin && \
    # Trim: awscli's bundled help examples, gcloud's Anthos binary (~100 MB),
    # the component manager's rollback copies, and the bundled interpreter.
    find /usr/local/aws-cli -type d -name examples -prune -exec rm -rf {} + && \
    rm -rf /usr/lib/google-cloud-sdk/bin/anthoscli \
           /usr/lib/google-cloud-sdk/.install/.backup \
           /usr/lib/google-cloud-sdk/platform/bundledpythonunix && \
    find /usr/local/aws-cli /usr/lib/google-cloud-sdk -type d -name __pycache__ -prune -exec rm -rf {} + && \
    # Cleanup
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Layer 5: single-binary tools tracked by upstream :latest tags. Kept at the
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

# Final environment setup
ENV PATH="/home/vscode/.local/bin:/usr/local/go/bin:/usr/local/cargo/bin:${PATH}"
ENV SHELL=/usr/bin/zsh
ENV DISABLE_AUTOUPDATER=true

# Entrypoint: sync Claude from image layer into volume on start
COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

USER vscode
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["zsh", "-l"]
