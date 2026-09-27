#!/usr/bin/env bash
# Run on the GitHub-hosted Ubuntu runner. Fedora itself is a privileged container.
set -euxo pipefail

LOG_DIR="$PWD/logs"
mkdir -p "$LOG_DIR"

free_runner_disk() {
    # The runner image fills most of its disk with preinstalled SDKs.
    sudo rm -rf \
        /usr/share/dotnet \
        /usr/local/lib/android \
        /opt/ghc \
        /opt/hostedtoolcache \
        /usr/local/share/boost \
        /usr/local/share/chromium \
        /usr/local/share/powershell \
        /usr/share/swift \
        "$AGENT_TOOLSDIRECTORY" || true
    docker system prune -af || true
    df -h | tee "$LOG_DIR/disk-before.txt"
}

save_guest_logs() {
    docker cp fedora:/var/log/guest-provision.log "$LOG_DIR/guest-provision.log" 2>/dev/null || true
    docker cp fedora:/home/fedora/provision-without.log "$LOG_DIR/provision-without.log" 2>/dev/null || true
    docker cp fedora:/home/fedora/provision-with.log "$LOG_DIR/provision-with.log" 2>/dev/null || true
    docker exec fedora bash -lc 'systemctl --failed --no-pager; echo ====; systemctl is-system-running || true; echo ====; journalctl -n 80 --no-pager || true' \
        >"$LOG_DIR/systemd.txt" 2>&1 || true
}

trap save_guest_logs EXIT

free_runner_disk

docker pull fedora:43
docker rm -f fedora >/dev/null 2>&1 || true

# systemd is not in the Fedora container image. Install it, then boot it as PID 1.
docker run -d --name fedora --privileged \
    --security-opt apparmor=unconfined \
    --security-opt seccomp=unconfined \
    fedora:43 sleep infinity
docker exec fedora bash -lc '
set -euxo pipefail
dnf install -y --setopt=install_weak_deps=False systemd systemd-resolved dbus sudo git python3 procps-ng
useradd -m -s /bin/bash fedora || true
echo "fedora ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/fedora
chmod 440 /etc/sudoers.d/fedora
'
docker commit fedora fedora-systemd >/dev/null
docker rm -f fedora
# apparmor=unconfined is required on the Ubuntu runner. The host's
# unix-chkpwd profile otherwise denies reading the container's /etc/shadow,
# and sudo fails with "Authentication service cannot retrieve authentication info".
docker run -d --name fedora --privileged --cgroupns=host \
    --security-opt apparmor=unconfined \
    --security-opt seccomp=unconfined \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    fedora-systemd /usr/lib/systemd/systemd
sleep 5
docker exec fedora bash -lc 'echo ARCH=$(uname -m); systemctl is-system-running || true; systemctl is-active dbus systemd-journald || true'

# The guest script is root, then drops to fedora for provision.
docker exec -i fedora bash -s << 'GUEST'
set -euxo pipefail
exec >/var/log/guest-provision.log 2>&1
echo "ARCH=$(uname -m)"
cat /etc/os-release | head -6
systemctl is-system-running || true

sudo -u fedora mkdir -p /home/fedora/src
sudo -u fedora git clone --depth 1 --branch main https://github.com/zulip/zulip.git /home/fedora/src/zulip
git config --global --add safe.directory /home/fedora/src/zulip
sudo -u fedora git config --global --add safe.directory /home/fedora/src/zulip
echo "SHA $(sudo -u fedora git -C /home/fedora/src/zulip rev-parse HEAD)"

# The Ubuntu runner's AppArmor profile for unix-chkpwd applies by path even
# when the container is unconfined, so pam_unix cannot read /etc/shadow.
# Provision only needs passwordless sudo, not a real password check.
printf '%s\n' \
    'auth sufficient pam_permit.so' \
    'account sufficient pam_permit.so' \
    'password sufficient pam_permit.so' \
    'session sufficient pam_permit.so' \
    >/etc/pam.d/sudo

run_provision() {
    local logfile="$1"
    # corepack writes to ~/.cache. Keep that directory owned by fedora.
    chown -R fedora:fedora /home/fedora
    sudo -u fedora -H bash -lc "cd /home/fedora/src/zulip && ./tools/provision" >"$logfile" 2>&1
}

set +e
run_provision /home/fedora/provision-without.log
without_status=$?
set -e
echo "WITHOUT_STATUS=$without_status"

if ! grep -F "No such file or directory: 'g++'" /home/fedora/provision-without.log; then
    echo "FATAL: baseline provision did not fail on missing g++"
    exit 2
fi
if rpm -q gcc-c++; then
    echo "FATAL: gcc-c++ was installed on the baseline run"
    exit 2
fi
echo "BASELINE_GXX_MISSING=1"

python3 - << 'PY'
from pathlib import Path
path = Path("/home/fedora/src/zulip/scripts/lib/setup_venv.py")
text = path.read_text()
old = '    "gcc",\n    "python3-devel",\n'
new = '    "gcc",\n    "gcc-c++",\n    "python3-devel",\n'
if old not in text:
    raise SystemExit("gcc dependency list not found")
path.write_text(text.replace(old, new, 1))
PY
chown fedora:fedora /home/fedora/src/zulip/scripts/lib/setup_venv.py

set +e
run_provision /home/fedora/provision-with.log
with_status=$?
set -e
echo "WITH_STATUS=$with_status"
rpm -q gcc gcc-c++
if grep -F "Zulip development environment setup succeeded" /home/fedora/provision-with.log; then
    echo "WITH_FIX_SUCCEEDED=1"
    exit 0
fi
echo "WITH_FIX_FAILED=1"
exit 1
GUEST
