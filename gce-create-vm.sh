#!/usr/bin/env bash
# Creates a Compute Engine VM with an optional data disk and static internal and external IPs
# (SSH through IAP, falling back to the external IP), then provisions it on first boot with
# vm-startup.sh (OS updates, git/rsync/btop/tmux, an app user with rootless Docker, and a shared
# group for every gcloud login).
#
# Usage:
#   ./gce-create-vm.sh [--config FILE] [options]
#
# Settings are applied in this order (later wins): script defaults, --config FILE (shell KEY=value
# lines, e.g. hazards-watch.env), then command-line options. Put --config first.
#
# Options (config-file variable in brackets):
#   --project ID               [PROJECT]            default: current gcloud project
#   --region REGION            [REGION]             default: europe-west1
#   --zone ZONE                [ZONE]               default: <region>-b
#   --name NAME                [NAME]               VM name (required)
#   --description TEXT         [DESCRIPTION]
#
#   --machine-type TYPE        [MACHINE_TYPE]       e.g. n4-standard-4, n4-highmem-8, e2-standard-4
#   --cpu N --memory SIZE      [CPU, MEMORY]        custom shape instead of --machine-type, e.g. --cpu 6 --memory 48GB
#   --machine-family FAMILY    [MACHINE_FAMILY]     family for a custom shape (default: n4)
#
#   --image-family FAMILY      [IMAGE_FAMILY]       default: rocky-linux-10-optimized-gcp
#   --image-project PROJECT    [IMAGE_PROJECT]      default: rocky-linux-cloud
#   --boot-disk-size GB        [BOOT_DISK_SIZE]     default: 20
#   --boot-disk-type TYPE      [BOOT_DISK_TYPE]     default: hyperdisk-balanced (use pd-balanced for e2/n2)
#
#   --data-disk-name NAME      [DATA_DISK_NAME]     default: <name>-data. Reused if it already exists.
#   --data-disk-size GB        [DATA_DISK_SIZE]     default: 100. An existing smaller disk is grown.
#   --data-disk-type TYPE      [DATA_DISK_TYPE]     default: same as boot disk type
#   --data-disk-iops N         [DATA_DISK_IOPS]     hyperdisk only; default: disk type baseline
#   --data-disk-throughput N   [DATA_DISK_THROUGHPUT] MiB/s, hyperdisk only; default: baseline
#   --no-data-disk             [DATA_DISK=no]
#   --data-mount PATH          [DATA_MOUNT]         default: /data
#
#   --network NET              [NETWORK]            default: default
#   --subnet SUBNET            [SUBNET]             default: default
#   --internal-ip IP           [INTERNAL_IP]        static internal IP to reserve; default: auto-assigned, then reserved
#   --no-external-ip           [EXTERNAL_IP=no]     no public IP (default: a static public IP, assigned by Google and
#                                                   reserved as <name>-external-ip; an existing VM's ephemeral IP is
#                                                   promoted to static). Without one, Cloud NAT is created for egress and
#                                                   SSH only works from inside the VPC (e.g. another VM).
#   --ssh-source-ranges CIDRS  [SSH_SOURCE_RANGES]  who may SSH to the external IP (default: 0.0.0.0/0)
#   --no-iap                   [IAP=no]             don't allow SSH through Identity-Aware Proxy. IAP needs the
#                                                   roles/iap.tunnelResourceAccessor role (not part of roles/editor);
#                                                   users without it fall back to the external IP.
#   --network-tier TIER        [NETWORK_TIER]       PREMIUM (default) or STANDARD, for the external IP
#   --allow-ports PORTS        [ALLOW_PORTS]        TCP ports open to the subnet range (default: 80,443,22,3389,6380,6389,5389;
#                                                   "" for none)
#   --tags TAGS                [TAGS]               extra network tags (comma separated)
#   --labels LABELS            [LABELS]             extra labels, e.g. env=prod,team=hw
#   --service-account EMAIL    [SERVICE_ACCOUNT]    default: the project's Compute Engine default SA
#   --scopes SCOPES            [SCOPES]             default: storage read-only, logging, monitoring, trace
#   --spot                     [SPOT=yes]           Spot VM (much cheaper, can be stopped at any time)
#   --no-ops-agent             [OPS_AGENT=no]       skip the Ops Agent (logging/metrics) policy
#
#   --app-user USER            [APP_USER]           default: watcher
#   --app-group GROUP          [APP_GROUP]          default: watchers
#   --startup-script FILE      [STARTUP_SCRIPT]     default: vm-startup.sh next to this script
#
#   --no-wait                  after the restart, don't wait for provisioning to finish
#   --dry-run                  print the gcloud commands instead of running them
#   -h, --help
#
# A new VM boots once (vm-startup.sh only mounts the data disk), is restarted by this script, and
# vm-startup.sh then runs the installs and setup; this script follows its progress until done.
# Each resource is skipped if it already exists, so re-running is safe. For an existing VM, only
# the startup script and its metadata are updated (apply them with a reboot or
# `sudo google_metadata_script_runner startup`).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# --- Defaults --------------------------------------------------------------

PROJECT=""
REGION=europe-west1
ZONE=""
NAME=""
DESCRIPTION=""
MACHINE_TYPE=n4-standard-2
CPU=""
MEMORY=""
MACHINE_FAMILY=n4
IMAGE_FAMILY=rocky-linux-10-optimized-gcp
IMAGE_PROJECT=rocky-linux-cloud
BOOT_DISK_SIZE=20
BOOT_DISK_TYPE=hyperdisk-balanced
DATA_DISK=yes
DATA_DISK_NAME=""
DATA_DISK_SIZE=100
DATA_DISK_TYPE=""
DATA_DISK_IOPS=""
DATA_DISK_THROUGHPUT=""
DATA_MOUNT=/data
NETWORK=default
SUBNET=default
INTERNAL_IP=""
EXTERNAL_IP=yes
SSH_SOURCE_RANGES=0.0.0.0/0
IAP=yes
NETWORK_TIER=PREMIUM
ALLOW_PORTS=80,443,22,3389,6380,6389,5389
TAGS=""
LABELS=""
SERVICE_ACCOUNT=""
SCOPES=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/trace.append
SPOT=no
OPS_AGENT=yes
APP_USER=watcher
APP_GROUP=watchers
STARTUP_SCRIPT="$SCRIPT_DIR/vm-startup.sh"
WAIT=yes
DRY_RUN=no

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    opt=$1; shift
    case $opt in
        --config)               [ -f "$1" ] || die "config file not found: $1"
                                # shellcheck disable=SC1090
                                source "$1"; shift ;;
        --project)              PROJECT=$1; shift ;;
        --region)               REGION=$1; shift ;;
        --zone)                 ZONE=$1; shift ;;
        --name)                 NAME=$1; shift ;;
        --description)          DESCRIPTION=$1; shift ;;
        --machine-type)         MACHINE_TYPE=$1; shift ;;
        --cpu)                  CPU=$1; shift ;;
        --memory)               MEMORY=$1; shift ;;
        --machine-family)       MACHINE_FAMILY=$1; shift ;;
        --image-family)         IMAGE_FAMILY=$1; shift ;;
        --image-project)        IMAGE_PROJECT=$1; shift ;;
        --boot-disk-size)       BOOT_DISK_SIZE=$1; shift ;;
        --boot-disk-type)       BOOT_DISK_TYPE=$1; shift ;;
        --data-disk-name)       DATA_DISK_NAME=$1; shift ;;
        --data-disk-size)       DATA_DISK_SIZE=$1; shift ;;
        --data-disk-type)       DATA_DISK_TYPE=$1; shift ;;
        --data-disk-iops)       DATA_DISK_IOPS=$1; shift ;;
        --data-disk-throughput) DATA_DISK_THROUGHPUT=$1; shift ;;
        --no-data-disk)         DATA_DISK=no ;;
        --data-mount)           DATA_MOUNT=$1; shift ;;
        --network)              NETWORK=$1; shift ;;
        --subnet)               SUBNET=$1; shift ;;
        --internal-ip)          INTERNAL_IP=$1; shift ;;
        --external-ip)          EXTERNAL_IP=yes ;;
        --no-external-ip)       EXTERNAL_IP=no ;;
        --ssh-source-ranges)    SSH_SOURCE_RANGES=$1; shift ;;
        --no-iap)               IAP=no ;;
        --network-tier)         NETWORK_TIER=$1; shift ;;
        --allow-ports)          ALLOW_PORTS=$1; shift ;;
        --tags)                 TAGS=$1; shift ;;
        --labels)               LABELS=$1; shift ;;
        --service-account)      SERVICE_ACCOUNT=$1; shift ;;
        --scopes)               SCOPES=$1; shift ;;
        --spot)                 SPOT=yes ;;
        --no-ops-agent)         OPS_AGENT=no ;;
        --app-user)             APP_USER=$1; shift ;;
        --app-group)            APP_GROUP=$1; shift ;;
        --startup-script)       STARTUP_SCRIPT=$1; shift ;;
        --no-wait)              WAIT=no ;;
        --dry-run)              DRY_RUN=yes ;;
        -h|--help)              usage; exit 0 ;;
        *)                      die "unknown option: $opt (see --help)" ;;
    esac
done

# --- Derived settings and checks -------------------------------------------

[ -n "$NAME" ] || die "--name is required"
if [ "$EXTERNAL_IP" = no ] && [ "$IAP" = no ]; then
    echo "warning: --no-external-ip with --no-iap: SSH will only work from inside the VPC" >&2
fi
[ -n "$PROJECT" ] || PROJECT=$(gcloud config get-value project 2>/dev/null)
[ -n "$PROJECT" ] || die "--project is required (no default gcloud project set)"
[ -n "$ZONE" ] || ZONE="${REGION}-b"
[ "${ZONE%-*}" = "$REGION" ] || die "zone $ZONE is not in region $REGION"
[ -n "$DATA_DISK_NAME" ] || DATA_DISK_NAME="${NAME}-data"
[ -n "$DATA_DISK_TYPE" ] || DATA_DISK_TYPE=$BOOT_DISK_TYPE
[ -f "$STARTUP_SCRIPT" ] || die "startup script not found: $STARTUP_SCRIPT"
if [ -n "$CPU$MEMORY" ]; then
    [ -n "$CPU" ] && [ -n "$MEMORY" ] || die "--cpu and --memory must be given together"
    SHAPE_ARGS=(--custom-vm-type="$MACHINE_FAMILY" --custom-cpu="$CPU" --custom-memory="$MEMORY")
    SHAPE="custom ${MACHINE_FAMILY} ${CPU} vCPU / ${MEMORY}"
else
    SHAPE_ARGS=(--machine-type="$MACHINE_TYPE")
    SHAPE=$MACHINE_TYPE
fi
if [ -z "$SERVICE_ACCOUNT" ]; then
    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)")
    SERVICE_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
fi
SUBNET_RANGE=$(gcloud compute networks subnets describe "$SUBNET" --project="$PROJECT" \
    --region="$REGION" --format="value(ipCidrRange)")
[ -n "$SUBNET_RANGE" ] || die "subnet $SUBNET not found in $REGION"

# The VM's own name is always a network tag, so firewall rules can target just this VM.
NET_TAGS=$NAME${TAGS:+,$TAGS}
VM_LABELS="managed-by=gce-create-vm${LABELS:+,$LABELS}"
IP_NAME="${NAME}-ip"
EXT_IP_NAME="${NAME}-external-ip"
ROUTER="${NETWORK}-router-${REGION}"
NAT="${NETWORK}-nat-${REGION}"

run() {
    if [ "$DRY_RUN" = yes ]; then printf '+'; printf ' %q' "$@"; echo; else "$@"; fi
}
exists() { "$@" --project="$PROJECT" --format="value(name)" >/dev/null 2>&1; }
step() { echo; echo "== $*"; }

cat <<EOF
Project:     $PROJECT
Zone:        $ZONE
VM:          $NAME ($SHAPE, $IMAGE_FAMILY, ${BOOT_DISK_SIZE}GB $BOOT_DISK_TYPE boot disk)
Data disk:   $([ "$DATA_DISK" = yes ] && echo "$DATA_DISK_NAME ${DATA_DISK_SIZE}GB $DATA_DISK_TYPE${DATA_DISK_IOPS:+, $DATA_DISK_IOPS IOPS}${DATA_DISK_THROUGHPUT:+, $DATA_DISK_THROUGHPUT MiB/s} -> $DATA_MOUNT" || echo none)
Network:     $NETWORK/$SUBNET ($SUBNET_RANGE), internal IP ${INTERNAL_IP:-auto}, external IP: $([ "$EXTERNAL_IP" = yes ] && echo "static ($EXT_IP_NAME, $NETWORK_TIER)" || echo none)
Open ports:  ${ALLOW_PORTS:-none} (from $SUBNET_RANGE)
App user:    $APP_USER (group $APP_GROUP)
EOF

# --- Network ---------------------------------------------------------------

step "Network"

# Lets VMs without an external IP reach Google APIs (logging, monitoring, Artifact Registry).
if [ "$(gcloud compute networks subnets describe "$SUBNET" --project="$PROJECT" --region="$REGION" \
        --format="value(privateIpGoogleAccess)")" != True ]; then
    run gcloud compute networks subnets update "$SUBNET" --project="$PROJECT" --region="$REGION" \
        --enable-private-ip-google-access
fi

if ! exists gcloud compute addresses describe "$IP_NAME" --region="$REGION"; then
    run gcloud compute addresses create "$IP_NAME" --project="$PROJECT" --region="$REGION" \
        --subnet="$SUBNET" ${INTERNAL_IP:+--addresses="$INTERNAL_IP"}
fi
RESERVED_IP=$(gcloud compute addresses describe "$IP_NAME" --project="$PROJECT" --region="$REGION" \
    --format="value(address)" 2>/dev/null || true)
RESERVED_IP=${RESERVED_IP:-$INTERNAL_IP}    # dry run: the address isn't reserved yet

EXTERNAL_ADDRESS=""
if [ "$EXTERNAL_IP" = yes ]; then
    # Reserve a static external IP. If the VM already has an ephemeral one, reserving that same
    # address promotes it to static without changing it; otherwise Google picks a new address.
    if ! exists gcloud compute addresses describe "$EXT_IP_NAME" --region="$REGION"; then
        CURRENT_EXT_IP=$(gcloud compute instances describe "$NAME" --project="$PROJECT" --zone="$ZONE" \
            --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)
        run gcloud compute addresses create "$EXT_IP_NAME" --project="$PROJECT" --region="$REGION" \
            --network-tier="$NETWORK_TIER" ${CURRENT_EXT_IP:+--addresses="$CURRENT_EXT_IP"}
    fi
    EXTERNAL_ADDRESS=$(gcloud compute addresses describe "$EXT_IP_NAME" --project="$PROJECT" \
        --region="$REGION" --format="value(address)" 2>/dev/null || true)
fi

if [ "$EXTERNAL_IP" = no ]; then
    # Outbound internet (dnf, Docker Hub, git) for VMs with no external IP.
    if ! exists gcloud compute routers describe "$ROUTER" --region="$REGION"; then
        run gcloud compute routers create "$ROUTER" --project="$PROJECT" --region="$REGION" --network="$NETWORK"
    fi
    if ! exists gcloud compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION"; then
        run gcloud compute routers nats create "$NAT" --project="$PROJECT" --router="$ROUTER" --region="$REGION" \
            --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
    fi
fi

# SSH through Identity-Aware Proxy, for every VM on the network.
if [ "$IAP" = yes ] && ! exists gcloud compute firewall-rules describe "${NETWORK}-allow-ssh-iap"; then
    run gcloud compute firewall-rules create "${NETWORK}-allow-ssh-iap" --project="$PROJECT" \
        --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:22 \
        --source-ranges=35.235.240.0/20
fi

# SSH to this VM's external IP (the fallback when IAP isn't permitted).
if [ "$EXTERNAL_IP" = yes ]; then
    if exists gcloud compute firewall-rules describe "${NAME}-allow-ssh"; then
        run gcloud compute firewall-rules update "${NAME}-allow-ssh" --project="$PROJECT" \
            --source-ranges="$SSH_SOURCE_RANGES"
    else
        run gcloud compute firewall-rules create "${NAME}-allow-ssh" --project="$PROJECT" \
            --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:22 \
            --source-ranges="$SSH_SOURCE_RANGES" --target-tags="$NAME"
    fi
fi

if [ -n "$ALLOW_PORTS" ]; then
    RULES=$(echo "$ALLOW_PORTS" | sed 's/[^,][^,]*/tcp:&/g')
    if exists gcloud compute firewall-rules describe "${NAME}-allow-internal"; then
        run gcloud compute firewall-rules update "${NAME}-allow-internal" --project="$PROJECT" \
            --rules="$RULES" --source-ranges="$SUBNET_RANGE"
    else
        run gcloud compute firewall-rules create "${NAME}-allow-internal" --project="$PROJECT" \
            --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules="$RULES" \
            --source-ranges="$SUBNET_RANGE" --target-tags="$NAME"
    fi
fi

# --- Data disk -------------------------------------------------------------

DISK_ARGS=()
if [ "$DATA_DISK" = yes ]; then
    step "Data disk"
    PERF_ARGS=()
    if [[ $DATA_DISK_TYPE == hyperdisk-* ]]; then
        [ -n "$DATA_DISK_IOPS" ] && PERF_ARGS+=(--provisioned-iops="$DATA_DISK_IOPS")
        [ -n "$DATA_DISK_THROUGHPUT" ] && PERF_ARGS+=(--provisioned-throughput="$DATA_DISK_THROUGHPUT")
    fi
    if exists gcloud compute disks describe "$DATA_DISK_NAME" --zone="$ZONE"; then
        read -r CUR_SIZE CUR_IOPS CUR_TPUT < <(gcloud compute disks describe "$DATA_DISK_NAME" \
            --project="$PROJECT" --zone="$ZONE" --format="value(sizeGb,provisionedIops,provisionedThroughput)")
        echo "reusing $DATA_DISK_NAME (${CUR_SIZE}GB, ${CUR_IOPS:-?} IOPS, ${CUR_TPUT:-?} MiB/s)"
        if [ "$CUR_SIZE" -lt "$DATA_DISK_SIZE" ]; then
            run gcloud compute disks resize "$DATA_DISK_NAME" --project="$PROJECT" --zone="$ZONE" \
                --size="${DATA_DISK_SIZE}GB" --quiet
        fi
        if [ ${#PERF_ARGS[@]} -gt 0 ] && \
           { [ "${DATA_DISK_IOPS:-$CUR_IOPS}" != "$CUR_IOPS" ] || [ "${DATA_DISK_THROUGHPUT:-$CUR_TPUT}" != "$CUR_TPUT" ]; }; then
            run gcloud compute disks update "$DATA_DISK_NAME" --project="$PROJECT" --zone="$ZONE" "${PERF_ARGS[@]}"
        fi
    else
        run gcloud compute disks create "$DATA_DISK_NAME" --project="$PROJECT" --zone="$ZONE" \
            --type="$DATA_DISK_TYPE" --size="${DATA_DISK_SIZE}GB" "${PERF_ARGS[@]}"
    fi
    # auto-delete=no: deleting the VM keeps the data.
    DISK_ARGS=(--disk=name="$DATA_DISK_NAME",device-name="$DATA_DISK_NAME",mode=rw,auto-delete=no)
fi

# --- VM --------------------------------------------------------------------

step "VM"

# Read by vm-startup.sh. enable-oslogin=FALSE: gcloud logins use metadata SSH keys, so the guest
# agent creates local accounts that vm-startup.sh can add to $APP_GROUP.
# enable-guest-attributes: vm-startup.sh reports its progress there.
METADATA="enable-oslogin=FALSE,enable-osconfig=TRUE,enable-guest-attributes=TRUE,data-mount=$DATA_MOUNT,app-user=$APP_USER,app-group=$APP_GROUP"
if [ "$DATA_DISK" = yes ]; then METADATA+=",data-disk-device=$DATA_DISK_NAME"; fi

NEW_VM=no
if exists gcloud compute instances describe "$NAME" --zone="$ZONE"; then
    echo "$NAME exists; updating its startup script, metadata and external IP only"
    run gcloud compute instances add-metadata "$NAME" --project="$PROJECT" --zone="$ZONE" \
        --metadata="$METADATA" --metadata-from-file=startup-script="$STARTUP_SCRIPT"
    # A VM without any external IP gets the reserved one attached.
    if [ "$EXTERNAL_IP" = yes ] && [ -z "$(gcloud compute instances describe "$NAME" --project="$PROJECT" \
            --zone="$ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)")" ]; then
        run gcloud compute instances add-access-config "$NAME" --project="$PROJECT" --zone="$ZONE" \
            --access-config-name="external-nat" --network-tier="$NETWORK_TIER" \
            ${EXTERNAL_ADDRESS:+--address="$EXTERNAL_ADDRESS"}
    fi
else
    NEW_VM=yes
    NIC="nic-type=GVNIC,stack-type=IPV4_ONLY,subnet=$SUBNET${RESERVED_IP:+,private-network-ip=$RESERVED_IP}"
    if [ "$EXTERNAL_IP" = yes ]; then
        NIC+=",network-tier=$NETWORK_TIER${EXTERNAL_ADDRESS:+,address=$EXTERNAL_ADDRESS}"
    else
        NIC+=",no-address"
    fi
    if [ "$SPOT" = yes ]; then
        SCHED_ARGS=(--provisioning-model=SPOT --instance-termination-action=STOP)
    else
        SCHED_ARGS=(--provisioning-model=STANDARD --maintenance-policy=MIGRATE)
    fi
    run gcloud compute instances create "$NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        ${DESCRIPTION:+--description="$DESCRIPTION"} \
        "${SHAPE_ARGS[@]}" \
        --network-interface="$NIC" \
        --metadata="$METADATA" \
        --metadata-from-file=startup-script="$STARTUP_SCRIPT" \
        "${SCHED_ARGS[@]}" \
        --service-account="$SERVICE_ACCOUNT" \
        --scopes="$SCOPES" \
        --tags="$NET_TAGS" \
        --labels="$VM_LABELS$([ "$OPS_AGENT" = yes ] && echo ",goog-ops-agent-policy=v2-template-1-7-0")" \
        --image-family="$IMAGE_FAMILY" \
        --image-project="$IMAGE_PROJECT" \
        --boot-disk-type="$BOOT_DISK_TYPE" \
        --boot-disk-size="${BOOT_DISK_SIZE}GB" \
        --boot-disk-device-name="${NAME}-boot" \
        "${DISK_ARGS[@]}" \
        --shielded-secure-boot \
        --shielded-vtpm \
        --shielded-integrity-monitoring
fi

if [ "$OPS_AGENT" = yes ]; then
    # Installs the Ops Agent on every VM in the zone that carries the matching label.
    OPS_POLICY="goog-ops-agent-v2-template-1-7-0-${ZONE}"
    if ! gcloud compute instances ops-agents policies describe "$OPS_POLICY" --project="$PROJECT" \
            --zone="$ZONE" >/dev/null 2>&1; then
        OPS_CONFIG=$(mktemp)
        printf 'agentsRule:\n  packageState: installed\n  version: latest\ninstanceFilter:\n  inclusionLabels:\n  - labels:\n      goog-ops-agent-policy: v2-template-1-7-0\n' > "$OPS_CONFIG"
        # describe also fails on a policy it can't parse (e.g. one edited outside these commands);
        # creating that one again reports ALREADY_EXISTS, which isn't worth stopping for.
        if ! OPS_OUT=$(run gcloud compute instances ops-agents policies create "$OPS_POLICY" \
                --project="$PROJECT" --zone="$ZONE" --file="$OPS_CONFIG" 2>&1); then
            grep -q ALREADY_EXISTS <<<"$OPS_OUT" || { rm -f "$OPS_CONFIG"; die "$OPS_OUT"; }
            echo "warning: Ops Agent policy $OPS_POLICY already exists but can't be read; leaving it as is." >&2
            echo "         To recreate it: gcloud compute instances ops-agents policies delete $OPS_POLICY --project=$PROJECT --zone=$ZONE" >&2
        fi
        [ -z "${OPS_OUT:-}" ] || echo "$OPS_OUT"
        rm -f "$OPS_CONFIG"
    fi
fi

# --- Restart and provisioning ----------------------------------------------

guest_status() {
    gcloud compute instances get-guest-attributes "$NAME" --project="$PROJECT" --zone="$ZONE" \
        --query-path=vm-provision/status --format="value(value)" 2>/dev/null || true
}
# wait_for_status TIMEOUT_SECONDS PATTERN... : prints each new status, returns once one matches.
wait_for_status() {
    local deadline=$((SECONDS + $1)) last="" cur want
    shift
    while [ $SECONDS -lt $deadline ]; do
        cur=$(guest_status)
        if [ -n "$cur" ] && [ "$cur" != "$last" ]; then echo "  status: $cur"; last=$cur; fi
        for want in "$@"; do
            # shellcheck disable=SC2053
            [[ $cur == $want ]] && return 0
        done
        sleep 15
    done
    return 1
}
LOGS_HINT="gcloud compute instances get-serial-port-output $NAME --project=$PROJECT --zone=$ZONE | grep startup-script"

# Also resumes an earlier run that stopped between the first boot and the restart.
if [ "$NEW_VM" = yes ] || [ "$(guest_status)" = first-boot-done ]; then
    step "First boot (mounting the data disk)"
    if [ "$DRY_RUN" = no ]; then
        wait_for_status 900 first-boot-done 'failed:*' \
            || die "no first-boot report after 15 minutes. Check: $LOGS_HINT"
        [[ $(guest_status) != failed:* ]] || die "first boot failed. Check: $LOGS_HINT"
    fi

    step "Restart"
    run gcloud compute instances stop "$NAME" --project="$PROJECT" --zone="$ZONE"
    run gcloud compute instances start "$NAME" --project="$PROJECT" --zone="$ZONE"

    if [ "$WAIT" = yes ] && [ "$DRY_RUN" = no ]; then
        step "Provisioning (OS updates, packages, users, rootless Docker); usually 5-15 minutes"
        wait_for_status 2700 done 'failed:*' \
            || die "provisioning still running after 45 minutes. Check: $LOGS_HINT"
        [[ $(guest_status) == done ]] || die "provisioning failed. Check: $LOGS_HINT"
    fi
fi

# Each follow-up command is printed once per way in: IAP (needs roles/iap.tunnelResourceAccessor,
# which roles/editor doesn't include) and the external IP as the fallback. With neither, only
# --internal-ip from a machine inside the VPC works.
SSH_BASE="gcloud compute ssh $NAME --project=$PROJECT --zone=$ZONE"
ssh_cmds() {
    [ "$IAP" = yes ] && printf '  via IAP:        %s --tunnel-through-iap %s\n' "$SSH_BASE" "$1"
    [ "$EXTERNAL_IP" = yes ] && printf '  via public IP:  %s %s\n' "$SSH_BASE" "$1"
    if [ "$IAP" = no ] && [ "$EXTERNAL_IP" = no ]; then
        printf '  from the VPC:   %s --internal-ip %s\n' "$SSH_BASE" "$1"
    fi
    return 0
}

cat <<EOF

Done. Private IP: ${RESERVED_IP:-<assigned at creation>}$([ "$EXTERNAL_IP" = yes ] && echo ", public IP: ${EXTERNAL_ADDRESS:-<reserved at creation>}")
Provisioning status: $([ "$DRY_RUN" = no ] && guest_status || echo "n/a (dry run)")
EOF
echo "Follow the setup log:"
ssh_cmds "-- sudo journalctl -u google-startup-scripts -f"
echo "Log in (with your git keys forwarded):"
ssh_cmds "-- -A"
if [ "$IAP" = yes ]; then
    echo "If IAP says 'not authorized' (4033), you need roles/iap.tunnelResourceAccessor$([ "$EXTERNAL_IP" = yes ] && echo "; meanwhile use the public IP command")."
fi
