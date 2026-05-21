#!/bin/bash
#
# Isolated test of the gating logic in scripts/entrypoint.sh.
#
# Verifies the conditions under which the entrypoint will (and won't)
# attempt to remap the vscode user. Does NOT exercise the actual
# usermod/groupmod/chown — those require root and a live container, and
# are covered by the runtime test in the docker-pr-build* CI workflows.

set -u

# Duplicate of remap_needed from scripts/entrypoint.sh — keep in sync.
remap_needed() {
    [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ] || return 1
    [ "$(id -u vscode)" = "$HOST_UID" ] && [ "$(id -g vscode)" = "$HOST_GID" ] && return 1
    return 0
}

# Stub `id vscode` so we can simulate different in-container vscode states
# without needing an actual vscode user on the test host.
fake_uid=501
fake_gid=20
id() {
    case "$1 ${2-}" in
        "-u vscode") echo "$fake_uid" ;;
        "-g vscode") echo "$fake_gid" ;;
        *) command id "$@" ;;
    esac
}
export -f id

pass=0
fail=0
check() {
    local label="$1" expect="$2" actual="$3"
    if [ "$expect" = "$actual" ]; then
        echo "PASS: $label"
        pass=$((pass + 1))
    else
        echo "FAIL: $label (expected $expect, got $actual)"
        fail=$((fail + 1))
    fi
}

# macOS: no env vars, vscode at image default 501:20
unset HOST_UID HOST_GID
fake_uid=501; fake_gid=20
remap_needed; check "macOS (no env vars) skips remap" 1 $?

# Linux first start: env vars set, vscode at image default
HOST_UID=1000 HOST_GID=1000
fake_uid=501; fake_gid=20
remap_needed; check "Linux first start triggers remap" 0 $?

# Linux subsequent start: env vars set, vscode already remapped
HOST_UID=1000 HOST_GID=1000
fake_uid=1000; fake_gid=1000
remap_needed; check "Linux subsequent start skips remap" 1 $?

# Partial env (only HOST_UID): incomplete config, skip remap
HOST_UID=1000; unset HOST_GID
fake_uid=501; fake_gid=20
remap_needed; check "Partial env (HOST_UID only) skips remap" 1 $?

# UID matches but GID differs: still needs remap
HOST_UID=501 HOST_GID=1000
fake_uid=501; fake_gid=20
remap_needed; check "UID matches but GID differs triggers remap" 0 $?

# Sentinel ENTRYPOINT_REMAPPED=1: outer guard prevents re-entry even when remap_needed
ENTRYPOINT_REMAPPED=1
HOST_UID=1000 HOST_GID=1000
fake_uid=501; fake_gid=20
if [ "$ENTRYPOINT_REMAPPED" != "1" ] && remap_needed; then
    entered=yes
else
    entered=no
fi
check "ENTRYPOINT_REMAPPED sentinel blocks re-entry" no "$entered"

echo "---"
echo "Passed: $pass  Failed: $fail"
[ "$fail" = "0" ]
