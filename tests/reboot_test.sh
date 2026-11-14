#!/bin/bash
# 一次性测试 VPS 的真实重启验收：prepare -> 外部执行重启 -> verify -> cleanup。
# 修改真实配置和 nftables 开机状态，必须使用测试机；state 目录需在重启后保留。
# shellcheck disable=SC2034,SC2154
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="${1:-}" STATE="${2:-}"
[ "$EUID" -eq 0 ] && [[ "$STATE" = /* ]] || { echo "用法: sudo bash $0 prepare|verify|cleanup /绝对路径/state"; exit 1; }
# shellcheck source=../nft.sh
source "$ROOT/nft.sh"
CONF=$(detect_nft_main_conf)
FILES=("$WHITELIST_FILE" "$FORWARD_FILE" "$WHITELIST_ENABLED_FILE" "$NFT_PERSIST_FILE" "$SYSCTL_FILE" "$CONF")
check() { if "$@"; then echo "PASS: $*"; else echo "FAIL: $*"; return 1; fi; }
restore_host() {
    local i path dropin
    [ -f "$STATE/prepared" ] || { echo "没有可恢复的验收快照"; return 1; }
    for i in "${!FILES[@]}"; do
        path="${FILES[i]}"
        if [ -f "$STATE/file.$i" ]; then cp -p "$STATE/file.$i" "$path"
        else rm -f -- "$path"; fi
    done
    # nftables 的 ExecStop 通常会清空整个 ruleset；临时清除此命令，只恢复服务状态。
    if [ "$(cat "$STATE/nft.active")" != active ]; then
        mkdir -p /run/systemd/system/nftables.service.d
        dropin="/run/systemd/system/nftables.service.d/90-nft-reboot-test.conf"
        [ ! -e "$dropin" ] || { echo "清理 drop-in 已存在，停止"; return 1; }
        printf '[Service]\nExecStop=\n' > "$dropin"
        systemctl daemon-reload
        systemctl stop nftables
        rm -f "$dropin"
        rmdir /run/systemd/system/nftables.service.d 2>/dev/null || true
        systemctl daemon-reload
    fi
    if [ "$(cat "$STATE/nft.enabled")" = disabled ]; then systemctl disable nftables >/dev/null 2>&1; fi
    nft delete table inet unified 2>/dev/null || true
    # Debian 默认主配置会在首次启动时生成一个空的 inet filter；仅在仍为空时移除。
    if [ ! -e "$STATE/had_filter" ]; then
        if nft -j list table inet filter > "$STATE/filter.json" 2>/dev/null; then
            if python3 - "$STATE/filter.json" <<'PY'
import json, sys
entries=json.load(open(sys.argv[1]))["nftables"]
for entry in entries:
    if any(k not in ("metainfo", "table", "chain") for k in entry): raise SystemExit(1)
    if "chain" in entry:
        c=entry["chain"]
        if c["name"] not in ("input", "forward", "output") or c.get("policy", "accept") != "accept": raise SystemExit(1)
PY
            then nft delete table inet filter; fi
        fi
    fi
    sysctl -w "net.ipv4.ip_forward=$(cat "$STATE/ip_forward.before")" >/dev/null
    if [ ! -e "$STATE/had_persist_dir" ]; then rmdir "$NFT_PERSIST_DIR" 2>/dev/null || true; fi
    : > "$STATE/cleaned"
    echo "PASS: 已恢复验收前的配置、服务开机状态和 IPv4 转发状态"
}
case "$PHASE" in
prepare)
    [ ! -e "$STATE/prepared" ] || { echo "验收状态已存在"; exit 1; }
    for table in "$NFT_TABLE" "${LEGACY_TABLES[@]}"; do
        if nft_table_exists "$table"; then echo "已有 inet $table，拒绝覆盖"; exit 1; fi
    done
    for path in "${FILES[@]:0:5}"; do
        [ ! -e "$path" ] || { echo "已有 $path，请使用没有部署本脚本的测试机"; exit 1; }
    done
    mkdir -p "$STATE"
    chmod 700 "$STATE"
    systemctl is-active nftables > "$STATE/nft.active" || true
    systemctl is-enabled nftables > "$STATE/nft.enabled" || true
    case "$(cat "$STATE/nft.enabled")" in enabled|disabled) ;; *) echo "不支持当前 nftables 服务状态"; exit 1;; esac
    for i in "${!FILES[@]}"; do
        [ ! -f "${FILES[i]}" ] || cp -p "${FILES[i]}" "$STATE/file.$i"
    done
    [ ! -d "$NFT_PERSIST_DIR" ] || : > "$STATE/had_persist_dir"
    nft_table_exists filter && : > "$STATE/had_filter"
    cat /proc/sys/net/ipv4/ip_forward > "$STATE/ip_forward.before"
    cat /proc/sys/kernel/random/boot_id > "$STATE/boot.before"
    : > "$STATE/prepared"
    trap 'rc=$?; if [ "$rc" -ne 0 ]; then restore_host; fi' EXIT
    : "${NFT_TEST_TARGET_IP:?需要可达的测试回显服务器 IPv4}"
    printf '%s\n' "$NFT_TEST_TARGET_IP" > "$STATE/target"
    # 保留所有现有服务的访问；白名单的拒绝行为由 netns 和共存测试覆盖。
    printf '0.0.0.0/0\n::/0\n' > "$WHITELIST_FILE"
    : > "$FORWARD_FILE"
    echo 1 > "$WHITELIST_ENABLED_FILE"
    bash "$ROOT/nft.sh" add-forward 45989 "$NFT_TEST_TARGET_IP" 46888
    bash "$ROOT/nft.sh" add-forward 45990 "$NFT_TEST_TARGET_IP" 46889
    sha256sum "$NFT_PERSIST_FILE" > "$STATE/persist.sha256"
    check systemctl is-enabled nftables
    check test -s "$SYSCTL_FILE"
    check nft list table inet unified >/dev/null
    echo "READY_FOR_REBOOT: $STATE"
    ;;
verify)
    [ -e "$STATE/prepared" ] && [ ! -e "$STATE/cleaned" ]
    before=$(cat "$STATE/boot.before")
    after=$(cat /proc/sys/kernel/random/boot_id)
    check test "$before" != "$after"
    check systemctl is-active nftables
    check systemctl is-enabled nftables
    check sha256sum -c "$STATE/persist.sha256"
    check test "$(cat /proc/sys/net/ipv4/ip_forward)" = 1
    check nft list table inet unified >/dev/null
    check grep -qxF "$NFT_INCLUDE_LINE" "$CONF"
    local_ip=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    python3 - "$local_ip" <<'PY'
import socket, sys, urllib.request
host=sys.argv[1]
with urllib.request.urlopen("http://%s:45989/" % host, timeout=5) as r:
    assert r.read().strip() == b"nft-reboot-target"
print("PASS: 重启后 TCP 真实转发")
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
s.sendto(b"nft-reboot-udp", (host, 45990))
assert s.recvfrom(100)[0] == b"nft-reboot-udp"
print("PASS: 重启后 UDP 真实转发")
PY
    : > "$STATE/verified"
    echo "重启验收通过：SSH 可重连，规则、配置、IPv4 转发及 TCP/UDP 转发均已恢复"
    ;;
cleanup) restore_host ;;
*) echo "未知阶段: $PHASE"; exit 2 ;;
esac
