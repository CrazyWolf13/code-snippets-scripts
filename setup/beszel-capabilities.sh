#!/usr/bin/env bash
# @name: Setup: Beszel agent capabilities
# @description: Gives the Beszel agent the capabilities for S.M.A.R.T. and Intel GPU stats, on bare metal also disk group and intel-gpu-tools, then restarts it
# Non-interactive, so it also works with nexterm/run-on-folder.sh. Restores the old unit file if the agent doesn't come back up.

# Re-execute as root if necessary
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || { echo "$(hostname): not root and sudo is missing"; exit 1; }
    exec sudo bash "$0" "$@"
fi

SERVICE=${SERVICE:-/etc/systemd/system/beszel-agent.service}

# SMART monitoring source: https://beszel.dev/guide/smart-data#disk-group
# Intel GPU monitoring source: https://beszel.dev/guide/gpu#intel
#
# CAP_SYS_RAWIO  -> SMART disk access
# CAP_SYS_ADMIN  -> SMART/NVMe access
# CAP_PERFMON    -> Intel GPU metrics
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

# Bare metal only: in VMs and LXCs there are no disks or GPUs to read
if ! systemd-detect-virt -q 2>/dev/null; then
    # SMART fallback from https://beszel.dev/guide/smart-data
    if id beszel >/dev/null 2>&1 && ! id -nG beszel | grep -qw disk; then
        usermod -aG disk beszel
        echo "[ADDED]   beszel user to the disk group"
        CHANGED=$((CHANGED + 1))
    fi
    # intel_gpu_top for Intel GPU stats, https://beszel.dev/guide/gpu#intel
    if grep -qx 0x8086 /sys/class/drm/card*/device/vendor 2>/dev/null && ! command -v intel_gpu_top >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq intel-gpu-tools >/dev/null
        echo "[ADDED]   intel-gpu-tools"
        CHANGED=$((CHANGED + 1))
    fi
fi

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
