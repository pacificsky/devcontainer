# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker devcontainer images pre-loaded with AI coding agents (Claude Code, OpenAI Codex) and development toolchains. Designed to run coding agents in sandboxed environments. Published to `ghcr.io`.

## Image Variants

- **`Dockerfile`** (full): Dev tools + cloud CLIs (AWS, Azure, GCP) + GitHub CLI
- **`Dockerfile.lite`**: Dev tools + GitHub CLI only, no cloud CLIs

Both share the same base (`mcr.microsoft.com/devcontainers/base:ubuntu`). The full image includes Go, Rust, Node.js LTS, Python 3 + uv. The lite image includes Node.js LTS, Python 3 + uv (no Go/Rust). They also diverge at the cloud CLI layer. Container user is `vscode`.

## Base Image Quirks

The base image is a **minimized Ubuntu** — docs, man pages, and non-essential content are stripped to reduce size. This causes two issues:

1. **dpkg doc excludes**: `/etc/dpkg/dpkg.cfg.d/excludes` blocks `/usr/share/doc/*` and `/usr/share/man/*`. To include docs/man for a specific package, add a `path-include` config file named `zz-<pkg>` (the `zz-` prefix ensures it sorts alphabetically **after** `excludes`, so includes win).
2. **Fake `man` binary**: `/usr/bin/man` is replaced with a stub script via `dpkg-divert`. To restore real man pages, remove the stub (`rm -f /usr/bin/man`), undo the diversion (`dpkg-divert --quiet --remove --rename /usr/bin/man`), and install `man-db`.

## Build Commands

```bash
# Build full image locally
docker build -t devcontainer:local -f Dockerfile .

# Build lite image locally
docker build -t devcontainer-lite:local -f Dockerfile.lite .

# Test that core tools are installed
docker run --rm devcontainer:local /bin/bash -c "command -v claude && command -v codex && command -v gh"
```

## CI/CD

Four GitHub Actions workflows in `.github/workflows/`:

| Workflow | Trigger | Image |
|---|---|---|
| `daily-docker-build.yml` | Daily 3AM PST + manual | full (`ghcr.io/<repo>`) |
| `daily-docker-build-lite.yml` | Daily 3AM PST + manual | lite (`ghcr.io/<repo>-lite`) |
| `docker-pr-build.yml` | PR touching `Dockerfile` | full (build+test only) |
| `docker-pr-build-lite.yml` | PR touching `Dockerfile.lite` | lite (build+test only) |

Daily builds: multi-arch (amd64/arm64) with digest-based merge, tagged `latest`, `daily-YYYY-MM-DD`, `YYYY-MM-DD`. Keeps last 7 versions. PR builds: single-arch validation with smoke tests.

## Dockerfile Layer Strategy

Layers are ordered by stability (most stable first) to maximize cache hits.

**Full image**: System packages → uv → Go → Rust → Node.js LTS → Cloud CLIs + GitHub CLI → Shell config → AI tools → ENV/PATH

**Lite image**: System packages → uv → Node.js LTS → GitHub CLI → Shell config → AI tools → ENV/PATH
