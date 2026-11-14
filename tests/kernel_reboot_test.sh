#!/bin/bash
# Disposable dual-stack host only. The remote echo/client lives on a second
# host. prepare -> external client -> reboot -> verify -> client -> cleanup.
# shellcheck disable=SC2034,SC2154
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="${1:-}"
STATE="${2:-/var/tmp/nft-kernel-reboot-acceptance}"
[[ "$STATE" =~ ^/var/tmp/nft-kernel-reboot[-a-zA-Z0-9_/]*$ && "$STATE" != *..* ]] || exit 1
[ "$EUID" -eq 0 ] || exit 1
export TMPDIR="$STATE"
# shellcheck source=../nft.sh
source "$ROOT/nft.sh"

restore_host() {
    local base override
    [ -f "$STATE/base" ] || return 0
    [ ! -e "$STATE/cleaned" ] || return 0
    systemctl stop nft-kernel-acceptance-permit.service >/dev/null 2>&1 || true
    [ ! -f "$STATE/permit.sh" ] || bash "$STATE/permit.sh" remove
    systemctl disable nft-kernel-acceptance-permit.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/nft-kernel-acceptance-permit.service
    base=$(cat "$STATE/base")
    : > "$base/translation.changed"
    restore_snapshot "$base"
    systemctl daemon-reload
    if [ "$(cat "$STATE/nft.active")" != active ]; then
        # Debian's default ExecStop flushes all rules. Suppress only that stop
        # command while returning the service to its original inactive state.
        override=/run/systemd/system/nftables.service.d/zz-nft-kernel-acceptance.conf
        [ ! -e "$override" ] || return 1
        mkdir -p "$(dirname "$override")"
        printf '[Service]\nExecStop=\n' > "$override"
        systemctl daemon-reload
        systemctl stop nftables
        rm -f "$override"
        rmdir "$(dirname "$override")" 2>/dev/null || true
        systemctl daemon-reload
    fi
    if [ "$(cat "$STATE/nft.enabled")" = disabled ]; then systemctl disable nftables; fi
    if [ ! -e "$STATE/had_filter" ] && nft -j list table inet filter > "$STATE/filter.json" 2>/dev/null; then
        if python3 - "$STATE/filter.json" <<'PY'
import json, sys
for entry in json.load(open(sys.argv[1]))['nftables']:
    if any(key not in ('metainfo', 'table', 'chain') for key in entry):
        sys.exit(1)
    if 'chain' in entry:
        chain = entry['chain']
        if chain['name'] not in ('input', 'forward', 'output') or chain.get('policy', 'accept') != 'accept':
            sys.exit(1)
PY
        then nft delete table inet filter; fi
    fi
    for item in persist translate libexec; do
        if [ ! -e "$STATE/had.$item" ]; then
            case "$item" in persist) rmdir "$NFT_PERSIST_DIR" 2>/dev/null || true ;;
                translate) rmdir "$TRANSLATE_DIR" 2>/dev/null || true ;;
                libexec) rmdir "$LIBEXEC_DIR" 2>/dev/null || true ;; esac
        fi
    done
    translation_guard_open
    if nft_table_exists nft_sh_transition; then echo 'Transition guard remains' >&2; return 1; fi
    : > "$STATE/cleaned"
    if [ ! -e "$STATE/had.lock" ] && [ -f "$FORWARD_FILE.lock" ] && [ ! -s "$FORWARD_FILE.lock" ]; then
        rm -f "$FORWARD_FILE.lock"
    fi
    echo 'PASS: restored managed files, kernel resources, sysctls and service states'
}

case "$PHASE" in
prepare)
    [ ! -e "$STATE" ] || { echo 'Acceptance state already exists' >&2; exit 1; }
    : "${NFT_TEST_TARGET4:?Need the second host IPv4}"
    : "${NFT_TEST_TARGET6:?Need the second host IPv6}"
    validate_target_ip "$NFT_TEST_TARGET4" && validate_target_ip "$NFT_TEST_TARGET6"
    for table in "$NFT_TABLE" "${LEGACY_TABLES[@]}" nft_sh_transition; do
        if nft_table_exists "$table"; then echo "Already has inet $table" >&2; exit 1; fi
    done
    [ ! -e "$SYSTEMD_DIR/nft-sh-translate.service" ] || exit 1
    [ ! -e /etc/systemd/system/nft-kernel-acceptance-permit.service ] || exit 1
    mkdir -m 700 "$STATE"
    printf '%s\n' "$NFT_TEST_TARGET4" > "$STATE/target4"
    printf '%s\n' "$NFT_TEST_TARGET6" > "$STATE/target6"
    cat /proc/sys/kernel/random/boot_id > "$STATE/boot.before"
    systemctl is-enabled nftables > "$STATE/nft.enabled" || true
    systemctl is-active nftables > "$STATE/nft.active" || true
    case "$(cat "$STATE/nft.enabled")" in enabled|disabled) ;; *) exit 1 ;; esac
    [ ! -d "$NFT_PERSIST_DIR" ] || : > "$STATE/had.persist"
    [ ! -d "$TRANSLATE_DIR" ] || : > "$STATE/had.translate"
    [ ! -d "$LIBEXEC_DIR" ] || : > "$STATE/had.libexec"
    [ ! -e "$FORWARD_FILE.lock" ] || : > "$STATE/had.lock"
    nft_table_exists filter && : > "$STATE/had_filter"
    begin_action
    printf '%s\n' "$SNAPSHOT_DIR" > "$STATE/base"
    release_action_lock
    SNAPSHOT_DIR=""
    trap 'rc=$?; if [ "$rc" -ne 0 ]; then restore_host; fi' EXIT
    # Preserve access to existing services. Denials are tested in isolation.
    printf '0.0.0.0/0\n::/0\n' > "$WHITELIST_FILE"
    : > "$FORWARD_FILE"
    echo 1 > "$WHITELIST_ENABLED_FILE"
    export NFT_SH_FORCE=1
    bash "$ROOT/nft.sh" add-forward --listen-family ipv6 45981 "$NFT_TEST_TARGET6" 46888
    bash "$ROOT/nft.sh" add-forward --listen-family ipv6 45982 "$NFT_TEST_TARGET4" 46888
    bash "$ROOT/nft.sh" add-forward --listen-family ipv4 45983 "$NFT_TEST_TARGET6" 46888
    bash "$ROOT/nft.sh" add-forward 45984 "$NFT_TEST_TARGET4" 46888
    systemctl start nft-sh-translate.service
    [ "$(systemctl is-active nftables || true)" = "$(cat "$STATE/nft.active")" ]
    cat > "$STATE/permit.sh" <<'SH'
#!/bin/bash
set -eu
state=$(cd "$(dirname "$0")" && pwd)
operation=${1:-setup}
rule() {
    local bin="$1"; shift
    if [ "$operation" = setup ]; then
        "$bin" -C DOCKER-USER "$@" -m comment --comment nft-kernel-acceptance 2>/dev/null ||
            "$bin" -I DOCKER-USER 1 "$@" -m comment --comment nft-kernel-acceptance
    else "$bin" -D DOCKER-USER "$@" -m comment --comment nft-kernel-acceptance 2>/dev/null || true; fi
}
for bin in iptables ip6tables; do
    "$bin" -nL DOCKER-USER >/dev/null 2>&1 || continue
    for link in nftsh64 nftsh46; do rule "$bin" -i "$link" -j ACCEPT; rule "$bin" -o "$link" -j ACCEPT; done
    if [ "$bin" = iptables ]; then target=$(cat "$state/target4"); else target=$(cat "$state/target6"); fi
    for proto in tcp udp; do rule "$bin" -s "$target" -d "$target" -p "$proto" --dport 46888 -j ACCEPT; done
    rule "$bin" -s "$target" -d "$target" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
done
SH
    chmod 700 "$STATE/permit.sh"
    cat > /etc/systemd/system/nft-kernel-acceptance-permit.service <<EOF
[Unit]
Description=Temporary scoped Docker exceptions for kernel forwarding acceptance
After=docker.service nft-sh-translate.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $STATE/permit.sh setup
ExecStop=/bin/bash $STATE/permit.sh remove
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now nft-kernel-acceptance-permit.service
    sha256sum "$NFT_PERSIST_FILE" > "$STATE/nft.sha256"
    sha256sum "$LIBEXEC_DIR/nft.sh" > "$STATE/helper.sha256"
    touch "$STATE/prepared"
    echo "READY_FOR_EXTERNAL_CLIENT_AND_REBOOT: $STATE"
    ;;
verify)
    [ -e "$STATE/prepared" ] && [ ! -e "$STATE/cleaned" ]
    [ "$(cat "$STATE/boot.before")" != "$(cat /proc/sys/kernel/random/boot_id)" ]
    sha256sum -c "$STATE/nft.sha256" "$STATE/helper.sha256"
    for ((i = 0; i < 60; i++)); do
        systemctl is-active --quiet nft-sh-translate.service && break
        if systemctl is-failed --quiet nft-sh-translate.service; then
            journalctl -b -u nft-sh-translate.service --no-pager -n 30
            exit 1
        fi
        sleep 0.5
    done
    systemctl is-active --quiet nft-sh-translate.service
    [ "$(systemctl show -p Type --value nft-sh-translate.service)" = oneshot ]
    [ "$(systemctl show -p MainPID --value nft-sh-translate.service)" = 0 ]
    translation_current
    [ -z "$(ip netns pids nftsh64)$(ip netns pids nftsh46)" ]
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ]
    [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = 1 ]
    nft list table inet unified >/dev/null
    ip -6 route show default
    touch "$STATE/verified"
    echo 'PASS: real reboot, persistent nft/Jool/routes and exited oneshot (no relay process)'
    ;;
cleanup)
    restore_host
    ;;
*) echo "Usage: $0 prepare|verify|cleanup [/var/tmp/nft-kernel-reboot-name]" >&2; exit 2 ;;
esac
