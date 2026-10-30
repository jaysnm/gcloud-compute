#!/bin/bash
# Boot-time provisioning for VMs created by gce-create-vm.sh, which attaches it as the
# startup-script. The guest agent runs it as root on every boot. One-time steps are guarded by
# marker files in $STATE_DIR. Delete a marker to repeat that step.
# Settings come from instance metadata (set by gce-create-vm.sh), with the defaults below.
# Re-run by hand:   sudo google_metadata_script_runner startup
# Follow the log:   sudo journalctl -u google-startup-scripts -f
#
# Steps:
#   1. Mount the data disk at /data (format it only if it has no filesystem). On the very first
#      boot the script stops here; gce-create-vm.sh then restarts the VM and the rest runs.
#   2. Update OS packages; install git, openssl, rsync, btop, tmux
#   3. Create the app user and shared group (metadata app-user/app-group, default watcher/watchers);
#      every login account joins the group
#   4. Rootless Docker for watcher (compose + buildx plugins), with data-root on /data/docker
#   5. Shared access: /data/sources for code and bind-mounted platform services data, and a `docker` command that
#      lets any watchers member drive watcher's rootless daemon
set -eEuo pipefail

metadata() {
    curl -fs -H Metadata-Flavor:Google \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" 2>/dev/null || echo "$2"
}
DATA_DISK=$(metadata data-disk-device "")      # empty: no data disk, $DATA_MOUNT is on the boot disk
DATA_MOUNT=$(metadata data-mount /data)
APP_USER=$(metadata app-user watcher)
SHARED_GROUP=$(metadata app-group watchers)
STATE_DIR=/var/lib/vm-provision

log() { echo "vm-startup: $*"; }
mkdir -p "$STATE_DIR"

# Progress is published as the guest attribute vm-provision/status, which gce-create-vm.sh polls:
#   first-boot-done, packages, users, docker, shared-access, done, or failed:<line>
set_status() {
    curl -fs -X PUT --data "$1" -H Metadata-Flavor:Google \
        "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/vm-provision/status" \
        >/dev/null 2>&1 || true
    log "status: $1"
}
trap 'set_status "failed:$LINENO"' ERR

# --- 1. Data disk ----------------------------------------------------------

mkdir -p "$DATA_MOUNT"
if [ -n "$DATA_DISK" ]; then
    DEV=/dev/disk/by-id/google-${DATA_DISK}
    for _ in $(seq 1 30); do [ -e "$DEV" ] && break; sleep 2; done
    if ! blkid "$DEV" >/dev/null 2>&1; then
        log "formatting $DEV"
        mkfs.xfs -L data "$DEV"
    fi
    UUID=$(blkid -s UUID -o value "$DEV")
    if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID $DATA_MOUNT xfs defaults,noatime,nofail 0 2" >> /etc/fstab
        systemctl daemon-reload
    fi
    mountpoint -q "$DATA_MOUNT" || mount "$DATA_MOUNT"
    xfs_growfs "$DATA_MOUNT" >/dev/null || true
fi

if [ ! -e "$STATE_DIR/first-boot.done" ]; then
    touch "$STATE_DIR/first-boot.done"
    set_status first-boot-done
    exit 0
fi

# --- 2. OS packages --------------------------------------------------------

if [ ! -e "$STATE_DIR/packages.done" ]; then
    set_status packages
    dnf -y upgrade --refresh
    dnf -y install epel-release          # btop comes from EPEL
    dnf -y install git openssl rsync btop tmux acl
    dnf clean all                        # keep the small boot disk free
    touch "$STATE_DIR/packages.done"
fi

# --- 3. watcher user and watchers group ------------------------------------

set_status users

getent group "$SHARED_GROUP" >/dev/null || groupadd "$SHARED_GROUP"
if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --groups "$SHARED_GROUP" "$APP_USER"
fi
# Rootless Docker maps container UIDs into this range.
if ! grep -q "^${APP_USER}:" /etc/subuid; then
    usermod --add-subuids 524288-589823 --add-subgids 524288-589823 "$APP_USER"
fi
APP_UID=$(id -u "$APP_USER")
APP_HOME=$(getent passwd "$APP_USER" | cut -d: -f6)
APP_RUNTIME_DIR=/run/user/$APP_UID

# gcloud SSH logins (metadata SSH keys) get local accounts created by the guest agent. New accounts
# join watchers here, and the path unit below also adds any other regular account as soon as
# /etc/passwd changes.
if ! grep -q '^\[Accounts\]' /etc/default/instance_configs.cfg 2>/dev/null; then
    printf '[Accounts]\ngroups = adm,dip,docker,lxd,plugdev,video,%s\n' "$SHARED_GROUP" >> /etc/default/instance_configs.cfg
    systemctl restart google-guest-agent-manager.service google-guest-agent.service 2>/dev/null || true
fi

cat > /usr/local/sbin/sync-app-group <<EOF
#!/bin/bash
# Adds every regular login account (UID 1000-59999) to the $SHARED_GROUP group.
getent passwd | awk -F: '\$3 >= 1000 && \$3 < 60000 {print \$1}' | while read -r u; do
    id -nG "\$u" | grep -qw $SHARED_GROUP || gpasswd -a "\$u" $SHARED_GROUP >/dev/null
done
EOF
chmod 0755 /usr/local/sbin/sync-app-group

cat > /etc/systemd/system/sync-app-group.service <<'EOF'
[Unit]
Description=Add login accounts to the app group

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sync-app-group
EOF
cat > /etc/systemd/system/sync-app-group.path <<'EOF'
[Unit]
Description=Watch /etc/passwd for new login accounts

[Path]
PathChanged=/etc/passwd

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sync-app-group.path
/usr/local/sbin/sync-app-group

# watchers members may run anything as watcher, without a password.
echo "%${SHARED_GROUP} ALL=(${APP_USER}) NOPASSWD: ALL" > /etc/sudoers.d/90-app-group
chmod 0440 /etc/sudoers.d/90-app-group
visudo -cf /etc/sudoers.d/90-app-group >/dev/null

# watcher's home is fully accessible to the group (current and future files).
setfacl -R -m "g:${SHARED_GROUP}:rwX" "$APP_HOME"
find "$APP_HOME" -type d -exec setfacl -d -m "g:${SHARED_GROUP}:rwX" {} +

# --- 4. Rootless Docker ----------------------------------------------------

as_app_user() {
    (cd "$APP_HOME" && runuser -u "$APP_USER" -- env -i \
        HOME="$APP_HOME" USER="$APP_USER" LOGNAME="$APP_USER" \
        PATH=/usr/local/bin:/usr/bin:/bin \
        XDG_RUNTIME_DIR="$APP_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$APP_RUNTIME_DIR/bus" \
        DOCKER_HOST="unix://$APP_RUNTIME_DIR/docker.sock" \
        "$@")
}

if [ ! -e "$STATE_DIR/docker.done" ]; then
    set_status docker
    curl -fsSL https://download.docker.com/linux/rhel/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
    dnf -y install docker-ce docker-ce-cli containerd.io docker-ce-rootless-extras \
        docker-buildx-plugin docker-compose-plugin slirp4netns
    dnf clean all
    # Only the rootless daemon runs; the system-wide one stays off.
    systemctl disable --now docker.service docker.socket containerd.service 2>/dev/null || true
    echo ip_tables > /etc/modules-load.d/docker-rootless.conf
    modprobe ip_tables || true

    # Keep watcher's systemd user manager (and its docker.service) running without a login session.
    loginctl enable-linger "$APP_USER"
    for _ in $(seq 1 30); do [ -S "$APP_RUNTIME_DIR/bus" ] && break; sleep 1; done

    # Images, containers and volumes live on the data disk.
    install -d -o "$APP_USER" -g "$APP_USER" -m 0710 "$DATA_MOUNT/docker"
    as_app_user mkdir -p "$APP_HOME/.config/docker"
    as_app_user tee "$APP_HOME/.config/docker/daemon.json" >/dev/null <<EOF
{
  "data-root": "$DATA_MOUNT/docker",
  "features": { "buildkit": true }
}
EOF

    as_app_user dockerd-rootless-setuptool.sh install
    as_app_user systemctl --user enable docker.service
    if ! grep -q DOCKER_HOST "$APP_HOME/.bashrc"; then
        echo "export DOCKER_HOST=unix://$APP_RUNTIME_DIR/docker.sock" | as_app_user tee -a "$APP_HOME/.bashrc" >/dev/null
    fi
    DOCKER_ROOT=$(as_app_user docker info --format '{{.DockerRootDir}}')
    log "docker root dir: $DOCKER_ROOT"
    [ "$DOCKER_ROOT" = "$DATA_MOUNT/docker" ]
    as_app_user docker compose version
    as_app_user docker buildx version
    touch "$STATE_DIR/docker.done"
fi

# Images, containers, volumes and build cache are all under $DATA_MOUNT/docker. If the data disk
# isn't mounted (the fstab entry is nofail), that path is an empty directory on the boot disk, so
# watcher's Docker waits up to 60s for the mount and otherwise refuses to start.
if [ -n "$DATA_DISK" ]; then
    as_app_user mkdir -p "$APP_HOME/.config/systemd/user/docker.service.d"
    as_app_user tee "$APP_HOME/.config/systemd/user/docker.service.d/require-data-disk.conf" >/dev/null <<EOF
[Service]
ExecStartPre=/usr/bin/timeout 60 /bin/sh -c 'until mountpoint -q $DATA_MOUNT; do sleep 1; done'
EOF
    as_app_user systemctl --user daemon-reload
fi

# --- 5. Shared access ------------------------------------------------------

set_status shared-access

# /data/sources holds checked-out code and the data that containers bind-mount. Group members and
# watcher (the rootless daemon) get read/write access to everything created under it.
chgrp "$SHARED_GROUP" "$DATA_MOUNT"
chmod 2775 "$DATA_MOUNT"
install -d -o "$APP_USER" -g "$SHARED_GROUP" -m 2775 "$DATA_MOUNT/sources"
setfacl -m "g:${SHARED_GROUP}:rwx,u:${APP_USER}:rwx" "$DATA_MOUNT/sources"
setfacl -d -m "g:${SHARED_GROUP}:rwx,u:${APP_USER}:rwx" "$DATA_MOUNT/sources"

# Repos under /data/sources are cloned by different users; skip git's "dubious ownership" check there.
git config --system --get-all safe.directory | grep -qx "$DATA_MOUNT/sources/\*" \
    || git config --system --add safe.directory "$DATA_MOUNT/sources/*"

# `docker` for every user talks to watcher's rootless daemon (as watcher, via the sudoers rule).
cat > /usr/local/bin/docker <<EOF
#!/bin/bash
# Runs the docker CLI against $APP_USER's rootless daemon, whoever the caller is.
# Run it from a directory that $APP_USER can read (e.g. under $DATA_MOUNT/sources).
SOCK=unix://$APP_RUNTIME_DIR/docker.sock
if [ "\$(id -un)" = "$APP_USER" ]; then
    DOCKER_HOST=\$SOCK exec /usr/bin/docker "\$@"
fi
exec sudo -u $APP_USER -H /usr/bin/env DOCKER_HOST=\$SOCK XDG_RUNTIME_DIR=$APP_RUNTIME_DIR /usr/bin/docker "\$@"
EOF
chmod 0755 /usr/local/bin/docker

# Group-writable files by default for group members.
cat > /etc/profile.d/app-group.sh <<EOF
if id -nG 2>/dev/null | grep -qw $SHARED_GROUP; then umask 002; fi
EOF

set_status done
