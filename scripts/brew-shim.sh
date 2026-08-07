#!/bin/bash
#
# Lazy Homebrew bootstrap shim, baked into the image at /usr/local/bin/brew.
#
# The real brew lives at /home/linuxbrew/.linuxbrew/bin/brew, which ENV PATH
# lists ahead of /usr/local/bin, so this shim is only reachable while Homebrew
# is not yet installed. First use clones Homebrew into place and execs the
# real brew; the image itself carries zero Homebrew bytes, and with a volume
# mounted at /home/linuxbrew the install persists across image upgrades.
#
# /home/linuxbrew must be a real directory or mount point, never a symlink
# into /home/vscode: bin/brew canonicalizes its own location with `pwd -P`,
# and Linux bottles only work at the literal /home/linuxbrew/.linuxbrew
# prefix — behind a symlink brew computes the physical (wrong) prefix and
# formulae fall back to building from source.
set -euo pipefail

PREFIX=/home/linuxbrew/.linuxbrew
REAL="$PREFIX/bin/brew"

if [[ ! -x "$REAL" ]]; then
    if [[ ! -w /home/linuxbrew ]]; then
        # e.g. the deployment mounted a root-owned volume over the baked-in dir
        sudo -n chown "$(id -u):$(id -g)" /home/linuxbrew 2>/dev/null || true
    fi
    if [[ ! -w /home/linuxbrew ]]; then
        echo "[brew] /home/linuxbrew is not writable by $(id -un); cannot install Homebrew" >&2
        exit 1
    fi

    # Serialize concurrent first uses — two shells, or two containers sharing
    # the same volume, which is why the lock file lives on the volume itself.
    exec 9>>/home/linuxbrew/.bootstrap.lock
    flock 9
    if [[ ! -x "$REAL" ]]; then
        echo "[brew] First use: installing Homebrew into $PREFIX ..." >&2
        mkdir -p "$PREFIX/bin"
        [[ -d "$PREFIX/Homebrew/.git" ]] || git clone https://github.com/Homebrew/brew "$PREFIX/Homebrew"
        ln -sfn ../Homebrew/bin/brew "$REAL"
    fi
    exec 9>&-
fi

exec "$REAL" "$@"
