#!/bin/bash
#
# Container entrypoint. Two responsibilities:
#
# 1. Remap the vscode user's UID/GID at runtime when HOST_UID/HOST_GID are
#    set, so bind mounts from non-macOS hosts (typically 1000:1000 on Linux)
#    line up with the in-container user. macOS hosts leave the env vars
#    unset and the image's baked-in 501:20 is used as-is.
#
# 2. Sync Claude Code from the image layer into the persistent volume.
#    See sync_claude() for details.

STAGED_DIR="/opt/claude-image"
LIVE_SHARE="/home/vscode/.local/share/claude"
LIVE_BIN="/home/vscode/.local/bin/claude"

remap_needed() {
    [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ] || return 1
    [ "$(id -u vscode)" = "$HOST_UID" ] && [ "$(id -g vscode)" = "$HOST_GID" ] && return 1
    return 0
}

# Elevate to root, remap vscode, then drop back to vscode and re-exec the
# entrypoint — all in a single sudo invocation. This matters because once
# `usermod -u $HOST_UID vscode` rewrites /etc/passwd, the previously-vscode
# UID (501) no longer exists in passwd, so the calling shell can't call
# sudo again ("sudo: you do not exist in the passwd database").
remap_and_reexec() {
    local current_uid current_gid
    current_uid=$(id -u vscode)
    current_gid=$(id -g vscode)

    echo "[entrypoint] Remapping vscode ${current_uid}:${current_gid} -> ${HOST_UID}:${HOST_GID}"

    export CURRENT_UID="$current_uid" CURRENT_GID="$current_gid" ENTRYPOINT_REMAPPED=1

    # secure_path in sudoers would otherwise clobber the image's ENV PATH.
    exec sudo \
        --preserve-env=PATH,HOME,SHELL,TERM,HOST_UID,HOST_GID,CURRENT_UID,CURRENT_GID,ENTRYPOINT_REMAPPED \
        bash -c '
            set -e
            # If another group already holds the target GID, move it out of the
            # way (same dance the Dockerfile does at build time for GID 20).
            squatter=$(getent group "$HOST_GID" | cut -d: -f1)
            if [ -n "$squatter" ] && [ "$squatter" != "vscode" ]; then
                groupmod -g 9998 "$squatter"
            fi
            groupmod -g "$HOST_GID" vscode
            usermod  -u "$HOST_UID" vscode
            # Chown anything under /home owned by the old UID/GID.
            find /home -uid "$CURRENT_UID" -exec chown -h "$HOST_UID" {} + || true
            find /home -gid "$CURRENT_GID" -exec chgrp -h "$HOST_GID" {} + || true
            # Drop privileges to the freshly-remapped vscode and re-enter the
            # entrypoint; the ENTRYPOINT_REMAPPED sentinel skips this block.
            exec runuser -u vscode -- "$@"
        ' remap "$0" "$@"
}

# Claude installs to /home/vscode/.local/, but a named volume mounted at
# /home/vscode shadows the image layer. The Dockerfile stages Claude at
# /opt/claude-image/ at build time; this copies it into the volume on
# container start when the image has a newer version.
sync_claude() {
    [ ! -f "$STAGED_DIR/version" ] && return 0

    local image_version volume_version=""
    image_version=$(cat "$STAGED_DIR/version")
    [ -z "$image_version" ] && return 0

    if [ -L "$LIVE_BIN" ]; then
        volume_version=$(basename "$(readlink "$LIVE_BIN")")
    fi

    [ "$image_version" = "$volume_version" ] && return 0

    # Don't overwrite a newer version already in the volume (e.g. from `claude update`)
    if [ -n "$volume_version" ]; then
        local higher
        higher=$(printf '%s\n%s\n' "$image_version" "$volume_version" | sort -V | tail -n1)
        if [ "$higher" = "$volume_version" ]; then
            echo "[entrypoint] Volume has newer Claude ($volume_version), skipping image version ($image_version)"
            return 0
        fi
    fi

    echo "[entrypoint] Updating Claude: ${volume_version:-not installed} -> $image_version"
    mkdir -p "$LIVE_SHARE/versions" "$(dirname "$LIVE_BIN")"
    cp -a "$STAGED_DIR/versions/$image_version" "$LIVE_SHARE/versions/$image_version"
    ln -sf "$LIVE_SHARE/versions/$image_version" "$LIVE_BIN"
    echo "[entrypoint] Claude updated to $image_version"
}

# If a remap is needed, hand off to remap_and_reexec — it execs and never
# returns. The sentinel prevents looping after the re-exec lands back here.
if [ "$ENTRYPOINT_REMAPPED" != "1" ] && remap_needed; then
    remap_and_reexec "$@"
fi

sync_claude || echo "[entrypoint] WARNING: Claude sync failed, continuing." >&2

exec "$@"
