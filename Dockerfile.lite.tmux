# Lite variant: dev tools + AI agents, no cloud CLIs (AWS/Azure/GCP)
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

# Layer 1: Base system dependencies and utilities (most stable)
# Re-include byobu docs/man (base image minimized via /etc/dpkg/dpkg.cfg.d/excludes)
# Filename zz- ensures this is processed AFTER excludes so includes win
# Remove man stub diversion so man-db can install the real man binary
RUN printf 'path-include /usr/share/doc/byobu/*\npath-include /usr/share/man/man1/byobu*\n' > /etc/dpkg/dpkg.cfg.d/zz-byobu && \
    rm -f /usr/bin/man && dpkg-divert --quiet --remove --rename /usr/bin/man && \
    apt-get update && \
    apt-get install -y \
        curl wget unzip \
        jq yq \
        vim nano \
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
    # Cleanup
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Layer 2: Install uv (modern Python package manager)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv

# Cache-bust from here down so daily builds pick up new versions of
# everything installed via script (Homebrew, Node, GitHub CLI, AI tools)
ARG CACHEBUST

# Layer 3: Install Homebrew
USER vscode
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
USER root

# Layer 3.1: install prek (pre-commit implementation in Rust)
COPY --from=ghcr.io/j178/prek:v0.3.4 /prek /usr/local/bin/prek

# Layer 4: Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs

# Layer 5: Install GitHub CLI
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    wget -nv -O- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y gh && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Layer 6: Shell configuration
RUN chsh -s /usr/bin/zsh vscode
USER vscode
COPY --chown=vscode:vscode config/.zshrc /home/vscode/.zshrc
COPY --chown=vscode:vscode config/.p10k.zsh /home/vscode/.p10k.zsh
RUN git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
    ${ZSH_CUSTOM:-/home/vscode/.oh-my-zsh/custom}/themes/powerlevel10k && \
    # Enable byobu auto-launch on login
    printf '_byobu_sourced=1 . /usr/bin/byobu-launch 2>/dev/null || true\n' >> ~/.zprofile && \
    printf '_byobu_sourced=1 . /usr/bin/byobu-launch 2>/dev/null || true\n' >> ~/.profile

# Layer 7: AI CLI tools (most volatile - frequent releases)
# Install Claude Code
RUN curl -fsSL https://claude.ai/install.sh | bash

# Stage Claude installation outside /home/vscode so it survives volume mounts
RUN CLAUDE_VERSION=$(basename "$(readlink /home/vscode/.local/bin/claude)") && \
    sudo mkdir -p /opt/claude-image/versions && \
    sudo cp -a /home/vscode/.local/share/claude/versions/"${CLAUDE_VERSION}" /opt/claude-image/versions/ && \
    echo "${CLAUDE_VERSION}" | sudo tee /opt/claude-image/version > /dev/null

# Install OpenAI Codex
RUN sudo npm install -g @openai/codex

# Layer 8: Final environment setup
ENV PATH="/home/vscode/.local/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}"
ENV SHELL=/usr/bin/zsh
ENV DISABLE_AUTOUPDATER=true

# Entrypoint: sync Claude from image layer into volume on start
COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

USER vscode
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["zsh", "-l"]
