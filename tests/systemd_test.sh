#!/bin/bash
# 在一次性测试机上验证真实 systemd 定时回滚。需要 root 和 systemd，
# 且不能已有本脚本的表。配置文件均写入临时目录，不启用宿主 nftables 服务。
# shellcheck disable=SC2034,SC2154
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d /var/tmp/nft-systemd.XXXXXX) || exit 1
PASS=0 FAIL=0
DRIVERS=()
BASE=""
cleanup() {
    local pid unit
    for pid in "${DRIVERS[@]}"; do
        while read -r unit _; do
            [ -n "$unit" ] || continue
            systemctl stop "$unit" "${unit%.timer}.service" >/dev/null 2>&1 || true
        done < <(systemctl list-units --all --plain --no-legend --type=timer "nft-sh-rollback-$pid-*" 2>/dev/null)
    done
    if [ -n "$BASE" ] && [ -d "$BASE" ]; then restore_snapshot "$BASE"; fi
    rm -rf -- "$WORK"
}
trap cleanup EXIT
check() {
    local desc="$1"
    shift
    if "$@"; then PASS=$((PASS + 1)); echo "PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "FAIL: $desc"; fi
}
if [ "$EUID" -ne 0 ] || [ ! -d /run/systemd/system ]; then
    echo "需要运行 systemd 的 root 测试环境"; exit 1
fi
for cmd in nft systemd-run systemctl; do command -v "$cmd" >/dev/null || exit 1; done
for table in unified whitelist_filter port_forward unified_filter unified_nat; do
    if nft list table inet "$table" >/dev/null 2>&1; then
        echo "已有 inet $table 表，拒绝覆盖；请使用一次性测试机"; exit 1
    fi
done
export NFT_SH_WHITELIST_FILE="$WORK/whitelist"
export NFT_SH_FORWARD_FILE="$WORK/forward"
export NFT_SH_ENABLED_FILE="$WORK/enabled"
export NFT_SH_PERSIST_DIR="$WORK/nftables.d"
export NFT_SH_MAIN_CONF="$WORK/nftables.conf"
export NFT_SH_SYSCTL_FILE="$WORK/sysctl.conf"
export TMPDIR="$WORK"
mkdir "$WORK/bin"
REAL_SYSTEMCTL=$(command -v systemctl)
printf '#!/bin/bash\nif [ "$1 $2" = "enable nftables" ]; then exit 0; fi\nexec %q "$@"\n' "$REAL_SYSTEMCTL" > "$WORK/bin/systemctl"
chmod +x "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH"
# shellcheck source=../nft.sh
source "$ROOT/nft.sh"
begin_action || exit 1
BASE="$SNAPSHOT_DIR"
printf '0.0.0.0/0\n::/0\n' > "$WHITELIST_FILE"
: > "$FORWARD_FILE"
echo 1 > "$WHITELIST_ENABLED_FILE"
apply_all_rules > "$WORK/baseline.log" 2>&1 || { cat "$WORK/baseline.log"; exit 1; }
cp "$NFT_PERSIST_FILE" "$WORK/persist.before"
nft -s list table inet unified > "$WORK/table.before"
cat > "$WORK/driver.sh" <<'EOF'
#!/bin/bash
source "$1"
INTERACTIVE=1
ROLLBACK_TIMEOUT=2
begin_action || exit 1
trap end_action EXIT
printf '%s' "$BASHPID" > "$2/pid"
printf '%s' "$SNAPSHOT_DIR" > "$2/snapshot"
wl_add 198.51.100.77 >/dev/null || exit 1
CONFIRM_ALWAYS=1
apply_all_rules
EOF
mkfifo "$WORK/input"
exec {input_fd}<>"$WORK/input"
bash "$WORK/driver.sh" "$ROOT/nft.sh" "$WORK" < "$WORK/input" > "$WORK/driver.log" 2>&1 &
launcher=$!
for ((i = 0; i < 100; i++)); do
    grep -q '确认正常请在' "$WORK/driver.log" && break
    sleep 0.05
done
if ! grep -q '确认正常请在' "$WORK/driver.log"; then cat "$WORK/driver.log"; exit 1; fi
driver=$(cat "$WORK/pid")
DRIVERS+=("$driver")
snap=$(cat "$WORK/snapshot")
unit=$(systemctl list-units --all --plain --no-legend --type=timer "nft-sh-rollback-$driver-*" | awk 'NR == 1 {print $1}')
check "启动真实 systemd timer" test -n "$unit"
if [ -n "$unit" ]; then
    accuracy=$(systemctl show -p AccuracyUSec --value "$unit")
    check "回滚定时器精度不超过 1 秒" test "$accuracy" = 1s
fi
check "规则生效后配置包含本次修改" grep -qx '198.51.100.77' "$WHITELIST_FILE"
nft add chain inet unified acceptance_probe || exit 1
kill -TERM "$driver"
wait "$launcher" 2>/dev/null || true
check "前台进程已经退出" test ! -d "/proc/$driver"
for ((i = 0; i < 120; i++)); do
    [ -d "$snap" ] || break
    sleep 0.1
done
check "后台定时任务按时完成" test ! -d "$snap"
if nft list chain inet unified acceptance_probe >/dev/null 2>&1; then
    check "恢复修改前的实时规则" false
else check "恢复修改前的实时规则" true; fi
if grep -qx '198.51.100.77' "$WHITELIST_FILE"; then
    check "恢复修改前的配置" false
else check "恢复修改前的配置" true; fi
check "未确认的规则没有覆盖持久化文件" cmp -s "$WORK/persist.before" "$NFT_PERSIST_FILE"
nft -s list table inet unified > "$WORK/table.after"
check "回滚后的完整表与原表一致" cmp -s "$WORK/table.before" "$WORK/table.after"
exec {input_fd}>&-

# 确认后定时任务只清理快照，不得再回滚新状态。
if bash "$WORK/driver.sh" "$ROOT/nft.sh" "$WORK" <<< y > "$WORK/confirm.log" 2>&1; then
    check "确认修改成功" true
else cat "$WORK/confirm.log"; check "确认修改成功" false; fi
DRIVERS+=("$(cat "$WORK/pid")")
snap=$(cat "$WORK/snapshot")
for ((i = 0; i < 120; i++)); do
    [ -d "$snap" ] || break
    sleep 0.1
done
check "确认后的 timer 清理快照" test ! -d "$snap"
check "确认后的配置保持生效" grep -qx '198.51.100.77' "$WHITELIST_FILE"
echo "systemd 集成测试: 通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
