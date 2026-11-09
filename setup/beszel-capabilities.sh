#!/usr/bin/env bash
# @name: Setup: Beszel agent capabilities
# @description: Gives the Beszel agent the capabilities for S.M.A.R.T. and hardware stats, then restarts it
# Non-interactive, so it also works with nexterm/run-on-folder.sh. Restores the old unit file if the agent doesn't come back up.

# Re-execute as root if necessary
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || { echo "$(hostname): not root and sudo is missing"; exit 1; }
    exec sudo bash "$0" "$@"
fi

SERVICE=${SERVICE:-/etc/systemd/system/beszel-agent.service}

KEYS=(AmbientCapabilities CapabilityBoundingSet NoNewPrivileges SystemCallArchitectures)
declare -A settings=(
    [AmbientCapabilities]="CAP_SYS_RAWIO CAP_SYS_ADMIN CAP_PERFMON"
    [CapabilityBoundingSet]="CAP_SYS_RAWIO CAP_SYS_ADMIN CAP_PERFMON"
    [NoNewPrivileges]="yes"
    [SystemCallArchitectures]="native"
)

show() {
    local lines
    lines=$(grep -E "^($(IFS='|'; echo "${KEYS[*]}"))=" "$SERVICE") || lines="(none set)"
    sed 's/^/  /' <<<"$lines"
}

echo "== $(hostname): Beszel agent capabilities"
if [[ ! -f $SERVICE ]]; then
    echo "== $SERVICE not found, skipped"
    exit 0
fi

echo "Current settings:"
show

BACKUP=$(mktemp)
cp -p "$SERVICE" "$BACKUP"
CHANGED=0
for key in "${KEYS[@]}"; do
    value="${settings[$key]}"
    if grep -q "^${key}=" "$SERVICE"; then
        if ! grep -qx "${key}=${value}" "$SERVICE"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$SERVICE"
            echo "[CHANGED] $key"
            CHANGED=$((CHANGED + 1))
        fi
    else
        sed -i "/^\[Service\]/a ${key}=${value}" "$SERVICE"
        echo "[ADDED]   $key"
        CHANGED=$((CHANGED + 1))
    fi
done

if [[ $CHANGED -eq 0 ]] && systemctl is-active --quiet beszel-agent; then
    rm -f "$BACKUP"
    echo "== already configured, nothing to do"
    exit 0
fi

echo "Reloading and restarting"
systemctl daemon-reload
systemctl restart beszel-agent
sleep 3

# In unprivileged LXCs some capabilities don't exist, and the agent may refuse to start with them
if ! systemctl is-active --quiet beszel-agent; then
    echo "== agent doesn't start with the new settings, restoring the old unit file"
    journalctl -u beszel-agent -n 10 --no-pager
    cp -p "$BACKUP" "$SERVICE"
    rm -f "$BACKUP"
    systemctl daemon-reload
    systemctl restart beszel-agent
    exit 1
fi
rm -f "$BACKUP"

echo "Updated settings:"
show
echo
systemctl status beszel-agent --no-pager -n 5
