#!/bin/bash
#
# Sync Claude Code from the image layer into the persistent volume.
#
# Problem: Claude installs to /home/vscode/.local/, but a named volume
# mounted at /home/vscode shadows the image layer. This script stages
# the image's Claude at /opt/claude-image/ (build time) and copies it
# into the volume on container start when the image has a newer version.
#

STAGED_DIR="/opt/claude-image"
LIVE_SHARE="/home/vscode/.local/share/claude"
LIVE_BIN="/home/vscode/.local/bin/claude"

sync_claude() {
    [ ! -f "$STAGED_DIR/version" ] && return 0

    local image_version volume_version=""
    image_version=$(cat "$STAGED_DIR/version")
    [ -z "$image_version" ] && return 0

    if [ -L "$LIVE_BIN" ]; then
        volume_version=$(basename "$(readlink "$LIVE_BIN")")
    fi

    [ "$image_version" = "$volume_version" ] && return 0

    echo "[entrypoint] Updating Claude: ${volume_version:-not installed} -> $image_version"
    mkdir -p "$LIVE_SHARE/versions" "$(dirname "$LIVE_BIN")"
    cp -a "$STAGED_DIR/versions/$image_version" "$LIVE_SHARE/versions/$image_version"
    ln -sf "$LIVE_SHARE/versions/$image_version" "$LIVE_BIN"
    echo "[entrypoint] Claude updated to $image_version"
}

# Never let sync failure prevent container startup
sync_claude || echo "[entrypoint] WARNING: Claude sync failed, continuing." >&2

exec "$@"
