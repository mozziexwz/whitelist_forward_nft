#!/bin/bash
# Disposable host only: actual systemd must restore a first custom deployment
# after SIGKILL, without inheriting the controller's shell environment.
# shellcheck disable=SC2034,SC2154
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$EUID" = 0 ] && [ -d /run/systemd/system ] || exit 1
for tool in nft ip jool systemctl systemd-run; do command -v "$tool" >/dev/null; done
for table in unified whitelist_filter port_forward unified_filter unified_nat nft_sh_transition; do
    if nft list table inet "$table" >/dev/null 2>&1; then echo "Managed table already exists: $table"; exit 1; fi
done
[ ! -e /etc/systemd/system/nft-sh-translate.service ] || exit 1
WORK=$(mktemp -d /var/tmp/nft-kernel-systemd.XXXXXX)
BASE="" DRIVER="" PASS=0 FAIL=0
export NFT_SH_WHITELIST_FILE="$WORK/whitelist" NFT_SH_FORWARD_FILE="$WORK/forward"
export NFT_SH_ENABLED_FILE="$WORK/enabled" NFT_SH_PERSIST_DIR="$WORK/nftables.d"
export NFT_SH_MAIN_CONF="$WORK/nftables.conf" NFT_SH_SYSCTL_FILE="$WORK/sysctl.conf"
export NFT_SH_TRANSLATE_DIR="$WORK/translate" NFT_SH_LIBEXEC_DIR="$WORK/libexec" NFT_SH_SYSTEMD_DIR="$WORK/systemd"
printf -v NFT_SH_XLATE_ID 'k%06x' "$(( $$ & 16777215 ))"
export NFT_SH_XLATE_ID NFT_SH_XLATE_V4=198.19.236 NFT_SH_XLATE_V6=fd73:7465:7374
export NFT_KERNEL_ROLLBACK_TIMEOUT="${NFT_KERNEL_ROLLBACK_TIMEOUT:-3}"
[[ "$NFT_KERNEL_ROLLBACK_TIMEOUT" =~ ^[1-9][0-9]?$ ]] && [ "$NFT_KERNEL_ROLLBACK_TIMEOUT" -le 60 ] || exit 2
export TMPDIR="$WORK" SSH_CONNECTION='198.51.100.1 50000 198.51.100.2 22'
# shellcheck source=../nft.sh
source "$ROOT/nft.sh"
cleanup() {
    local rc=$? unit
    if [ "$rc" -ne 0 ] || [ "$FAIL" -ne 0 ]; then cat "$WORK/driver.log" 2>/dev/null || true; fi
    if [ -n "$DRIVER" ]; then
        while read -r unit _; do
            [ -z "$unit" ] || systemctl stop "$unit" "${unit%.timer}.service" >/dev/null 2>&1 || true
        done < <(systemctl list-units --all --plain --no-legend --type=timer "nft-sh-rollback-$DRIVER-*" 2>/dev/null)
        kill -KILL "$DRIVER" 2>/dev/null || true
        wait "$DRIVER" 2>/dev/null || true
    fi
    if [ -n "$BASE" ]; then
        : > "$BASE/translation.changed"
        restore_snapshot "$BASE" || rc=1
    fi
    rm -rf -- "$WORK"
    return "$rc"
}
trap cleanup EXIT
check() {
    local title="$1"; shift
    if "$@"; then echo "PASS: $title"; PASS=$((PASS + 1))
    else echo "FAIL: $title"; FAIL=$((FAIL + 1)); fi
}
printf '0.0.0.0/0\n::/0\n' > "$WHITELIST_FILE"
: > "$FORWARD_FILE"
echo 1 > "$WHITELIST_ENABLED_FILE"
begin_action
BASE="$SNAPSHOT_DIR"
release_action_lock
SNAPSHOT_DIR=""
cat > "$WORK/driver.sh" <<'SH'
#!/bin/bash
source "$1"
INTERACTIVE=1; CLI_MODE=1; ROLLBACK_TIMEOUT="$NFT_KERNEL_ROLLBACK_TIMEOUT"
begin_action || exit 1
trap end_action EXIT
printf '%s\n' "$SNAPSHOT_DIR" > "$2/snapshot"
fwd_validate 48091 198.51.100.10 48090 ipv6 && fwd_append || exit 1
CONFIRM_ALWAYS=1
apply_all_rules
SH
mkfifo "$WORK/input"
exec {input_fd}<>"$WORK/input"
bash "$WORK/driver.sh" "$ROOT/nft.sh" "$WORK" < "$WORK/input" > "$WORK/driver.log" 2>&1 &
DRIVER=$!
ready=0
for ((i = 0; i < 1200; i++)); do
    if grep -q '确认正常请在' "$WORK/driver.log"; then ready=1; break; fi
    kill -0 "$DRIVER" 2>/dev/null || break
    sleep 0.05
done
[ "$ready" = 1 ] || { cat "$WORK/driver.log"; exit 1; }
snap=$(cat "$WORK/snapshot")
translation_settings
check 'custom translator created' translation_resource_owned 64
check 'first-deployment parameters not persisted before confirmation' test ! -e "$TRANSLATE_DEPLOY"
timer_present() { systemctl list-units --all --plain --no-legend --type=timer "nft-sh-rollback-$DRIVER-*" | grep -q 'nft-sh-rollback-'; }
check 'guard uses real systemd timer' timer_present
kill -KILL "$DRIVER"
wait "$DRIVER" 2>/dev/null || true
for ((i = 0; i < (NFT_KERNEL_ROLLBACK_TIMEOUT + 45) * 4; i++)); do [ -d "$snap" ] || break; sleep 0.25; done
check 'independent timer restores and removes snapshot' test ! -d "$snap"
resources_absent() { ! ip link show "${XL_ID}64" >/dev/null 2>&1 && ! translation_resource_owned 64; }
routes_absent() { [ -z "$(ip -4 route show "$XL4.64/32")$(ip -6 route show "$XL6:64::/96")" ]; }
check 'custom namespace and veth removed' resources_absent
check 'custom routes removed' routes_absent
check 'declaration restored' test ! -s "$FORWARD_FILE"
check 'original live firewall restored' bash -c '! nft list table inet unified >/dev/null 2>&1'
exec {input_fd}>&-
printf 'Kernel systemd context: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
