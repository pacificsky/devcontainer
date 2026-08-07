# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker devcontainer images pre-loaded with AI coding agents (Claude Code, OpenAI Codex) and development toolchains. Designed to run coding agents in sandboxed environments. Published to `ghcr.io`.

## Image Variants

- **`Dockerfile`** (full): Dev tools + cloud CLIs (AWS, GCP) + GitHub CLI + Docker CLI + byobu/tmux
- **`Dockerfile.lite`**: Dev tools + GitHub CLI + Docker CLI only, no cloud CLIs, no byobu/tmux
- **`Dockerfile.lite.tmux`**: Same as lite but with byobu/tmux installed and auto-launched on login

Both share the same base (`mcr.microsoft.com/devcontainers/base:ubuntu`). The full image includes Go, Rust, Node.js LTS, Python 3 + uv. The lite images include Node.js LTS, Python 3 + uv (no Go/Rust). They also diverge at the cloud CLI layer. Container user is `vscode`. The plain lite image is designed for use inside environments that already provide a terminal multiplexer (e.g. tmux on a remote VPS host).

All variants ship a **client-only Docker install** (`docker-ce-cli` + buildx and compose plugins, no daemon): the deployment mounts the host's `/var/run/docker.sock` so containers can build and run images via the outer daemon. Whether `vscode` can reach the mounted socket depends on the host socket's group — handled at deploy time, not in the image (`sudo docker` always works as a fallback).

All variants also ship **lazy Homebrew**: `/usr/local/bin/brew` is a shim (`scripts/brew-shim.sh`) that clones Homebrew into `/home/linuxbrew/.linuxbrew` on first use, so the image carries zero Homebrew bytes and users who never `brew` pay nothing. Deployments mount a volume at `/home/linuxbrew` (a second mount of the home volume, a `volume-subpath`, or a dedicated volume) so installs persist across image upgrades; without the mount, brew still works but is ephemeral. **`/home/linuxbrew` must be a real directory or mount point — never a symlink into `/home/vscode`.** `bin/brew` canonicalizes its own location with `pwd -P`, so behind a symlink it computes a physical prefix other than `/home/linuxbrew/.linuxbrew`, and Linux bottles only work at that exact prefix — everything silently degrades to building from source. The smoke tests assert `brew --prefix` returns the literal default prefix to catch this. Homebrew never needs sudo here: the image bakes an empty vscode-owned `/home/linuxbrew`, and the entrypoint's UID-remap `find /home` sweep covers it.

## Anything Installed Under /home/vscode Is At Risk

The intended deployment mounts a named volume at `/home/vscode`, which **shadows whatever the image put there**. Anything a tool installs into the user's home directory is therefore invisible at runtime. Two consequences baked into the Dockerfiles:

- **Rust lives at `/usr/local/{rustup,cargo}`**, not `~/.cargo` — set via `RUSTUP_HOME`/`CARGO_HOME` before `rustup-init` runs, with `chmod -R a+w` so `vscode` can `cargo install`. (An earlier version ran `rustup` as root and left ~1.2 GB in `/root/.cargo`, unreachable by `vscode` and off `PATH` entirely.)
- **Claude Code cannot avoid `~/.local`**, so the build stages a copy at `/opt/claude-image/` and `scripts/entrypoint.sh` syncs it into the volume on container start. Install and stage happen in **one** `RUN` using `cp -al`, so the staged copy is hardlinked and costs ~0 bytes rather than duplicating ~80 MB in a second layer.

Anything new that installs to the home directory needs the same treatment.

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

# Build lite+tmux image locally
docker build -t devcontainer-lite-tmux:local -f Dockerfile.lite.tmux .

# Test that core tools are installed
docker run --rm devcontainer:local /bin/bash -c "command -v claude && command -v codex && command -v gh"
```

## CI/CD

Seven GitHub Actions workflows in `.github/workflows/`:

| Workflow | Trigger | Image |
|---|---|---|
| `daily-docker-build.yml` | Daily 3AM PST + manual | full (`ghcr.io/<repo>`) |
| `daily-docker-build-lite.yml` | Daily 3AM PST + manual | lite (`ghcr.io/<repo>-lite`) |
| `daily-docker-build-lite-tmux.yml` | Daily 3AM PST + manual | lite+tmux (`ghcr.io/<repo>-lite-tmux`) |
| `docker-pr-build.yml` | Any PR | full (build+test only) |
| `docker-pr-build-lite.yml` | Any PR | lite (build+test only) |
| `docker-pr-build-lite-tmux.yml` | Any PR | lite+tmux (build+test only) |
| `keep-alive.yml` | 1st & 15th monthly + manual | n/a (repo activity) |

Daily builds: multi-arch (amd64/arm64) with digest-based merge, tagged `latest`, `daily-YYYY-MM-DD`, `YYYY-MM-DD`. Keeps last 7 versions. PR builds: single-arch validation with smoke tests.

PR builds run a two-arch matrix (`ubuntu-latest`/amd64, `ubuntu-24.04-arm`/arm64). Each job sets an **explicit `name:`** — `build-and-test-<variant>${{ matrix.suffix }}` — and this is load-bearing, not cosmetic. Without a `name:`, GitHub appends the matrix combination to the check name (`build-and-test-full (ubuntu-latest, linux/amd64)`), but the `main-protection` ruleset requires the bare contexts `build-and-test-full`, `build-and-test-lite`, `build-and-test-lite-tmux`. Those would then never report and **every PR would block forever, including the one making the change**. The suffix scheme keeps amd64 reporting under the existing required name and adds arm64 as an additive check. If you rename these jobs, update the ruleset's `required_status_checks` in the same change.

Daily builds use **registry-backed** build cache in a separate package, `ghcr.io/<repo>-buildcache`, tagged `<variant>-linux-<arch>`. Two reasons it is not the GitHub Actions cache: the GHA cache is capped at 10 GB per repo, which six `mode=max` scopes of these images exceed (causing constant LRU eviction), and a separate package keeps the cache out of reach of the `cleanup-old-images` job, which deletes all but the newest 7 versions of `devcontainer` regardless of tag. PR builds still use `type=gha` — they have no `packages: write` permission. GHCR requires `image-manifest=true,oci-mediatypes=true` on `cache-to` or it rejects the cache manifest.

The keep-alive workflow commits a timestamp to `.github/keep-alive.txt` so the repo never hits GitHub's 60-day default-branch inactivity limit, which auto-disables scheduled workflows. It pushes directly to `main` over SSH using a write-access deploy key (`KEEPALIVE_DEPLOY_KEY` secret); deploy keys are the bypass actor in the `main-protection` ruleset, which otherwise requires PRs with passing `build-and-test-*` checks.

## Dockerfile Layer Strategy

All three Dockerfiles are split into three tiers by how often their contents actually change. Each tier is gated by its own `ARG`, and the daily workflows feed those args at different cadences, so a nightly rebuild only produces new layers for the things that genuinely shipped that day.

| Tier | Gate | Cadence | Contents |
|---|---|---|---|
| 1 | none | on file change | UID/GID remap, apt packages, `chsh` |
| 2 | `TOOLCHAIN_REFRESH` | weekly (`date -u +%G-%V`) | Go, Rust, Node.js, cloud CLIs, GitHub CLI, Docker CLI, `uv`, `prek` |
| 3 | `AI_CACHEBUST` | daily (`github.run_id`) | Claude Code, OpenAI Codex |

**Full image**: system packages → *[weekly]* Go → Rust → Node.js LTS → cloud CLIs + GitHub CLI + Docker CLI → uv + prek → *[daily]* AI tools → shell config → ENV/PATH

**Lite image**: system packages → *[weekly]* Node.js LTS → GitHub CLI + Docker CLI → uv + prek → *[daily]* AI tools → shell config → ENV/PATH

**Lite+Tmux image**: same as lite, plus byobu in the system packages layer and auto-launch in shell config

Ordering rules worth preserving when editing:

- **Shell config (`.zshrc`, `.p10k.zsh`, powerlevel10k) goes last**, below the AI tools. Tweaking zsh config then rebuilds ~1 MB instead of invalidating ~350 MB of AI CLI layers.
- **`uv` and `prek` sit at the bottom of tier 2.** They are `COPY --from=<image>:latest`, so a new upstream digest invalidates everything below them; last in the tier means that costs two tiny layers, not every toolchain.
- **Each `RUN` cleans up after itself in the same `RUN`.** A later `rm -rf /var/lib/apt/lists/*` cannot reclaim space an earlier layer already committed — it just adds a whiteout. This is why the Node.js layer drops its own apt lists even though a later layer does the same.
- Whole-line `#` comments are stripped by Docker before the shell sees them, which is why they can appear mid-`&&`-chain inside a `RUN`.

Several components are trimmed after install: `go/test`, gcloud's `anthoscli` / `.install/.backup` / bundled interpreter (with `CLOUDSDK_PYTHON` pinned to the system one), awscli's bundled help `examples`, `__pycache__` trees, and the npm tarball cache. Rust uses `--profile minimal` plus explicit `clippy`/`rustfmt` to skip `rust-docs`. The PR and daily smoke tests run `--version` on every trimmed tool — a bad trim only surfaces at runtime, so keep those assertions in sync when adding or removing a tool.
