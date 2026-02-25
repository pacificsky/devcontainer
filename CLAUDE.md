# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker devcontainer images pre-loaded with AI coding agents (Claude Code, OpenAI Codex) and development toolchains. Designed to run coding agents in sandboxed environments. Published to `ghcr.io`.

## Image Variants

- **`Dockerfile`** (full): Dev tools + cloud CLIs (AWS, Azure, GCP) + GitHub CLI
- **`Dockerfile.lite`**: Dev tools + GitHub CLI only, no cloud CLIs

Both share the same base (`mcr.microsoft.com/devcontainers/base:ubuntu`) and toolchain layers (Go, Rust, Node.js LTS, Python 3 + uv). They diverge at the cloud CLI layer. Container user is `vscode`.

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

Layers are ordered by stability (most stable first) to maximize cache hits:
1. System packages (apt)
2. uv (Python package manager)
3. Go
4. Rust
5. Node.js LTS
6. Cloud CLIs (full only) / GitHub CLI
7. AI tools (Claude Code, Codex) — most volatile
8. ENV/PATH setup
