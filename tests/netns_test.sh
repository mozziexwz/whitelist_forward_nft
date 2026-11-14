#!/bin/bash
# 集成测试：在隔离的 network namespace 中用真实内核加载规则并收发数据包。
# 需要 root、nftables、iproute2、python3（GitHub Actions 的 ubuntu-latest 都满足）:
#   sudo bash tests/netns_test.sh
#
# 拓扑:  客户端 10.10.1.2 / 10.10.1.3（不在白名单）
#            |
#        中转机 10.10.1.1 | 10.10.2.1    <- 运行 nft.sh
#            |
#        目标机 10.10.2.2 + 无关主机 10.10.2.3
#
# 只会创建 / 删除名为 nfttest_* 的 network namespace，不改动宿主机的网络和防火墙规则；
# 持久化文件、nftables 主配置、sysctl 文件都写到临时目录，也不会启用任何 systemd 服务。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/nft.sh"
WORK="$(mktemp -d)"
CLI="nfttest_cli_$$"
RELAY="nfttest_relay_$$"
TGT="nfttest_tgt_$$"
C_LINK="nc$$"
R0_LINK="nr$$"a
T_LINK="nt$$"
R1_LINK="nr$$"b
PASS=0
FAIL=0
PIDS=()
CREATED_NS=()
CREATED_LINKS=()
# 模拟管理员从客户端 10.10.1.2 通过 SSH 登录中转机。必须显式设置：
# 否则通过 SSH 运行本测试时，nft.sh 会沿父进程读到真实的 SSH 连接
DEFAULT_ENV=("SSH_CONNECTION=10.10.1.2 50000 10.10.1.1 22")
RUN_ENV=("${DEFAULT_ENV[@]}")

export NFT_SH_WHITELIST_FILE="$WORK/whitelist.txt"
export NFT_SH_FORWARD_FILE="$WORK/forward.conf"
export NFT_SH_ENABLED_FILE="$WORK/enabled"
export NFT_SH_PERSIST_DIR="$WORK/nftables.d"
export NFT_SH_MAIN_CONF="$WORK/nftables.conf"
export NFT_SH_SYSCTL_FILE="$WORK/sysctl-forward.conf"
unset SSH_CONNECTION SSH_CLIENT

# 假的 systemctl：不让测试去启用宿主机的 nftables.service
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/systemctl"
chmod +x "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH"

cleanup() {
    local p ns dev
    for p in "${PIDS[@]}"; do
        kill "$p" 2>/dev/null
    done
    for ns in "${CREATED_NS[@]}"; do
        ip netns del "$ns" 2>/dev/null
    done
    for dev in "${CREATED_LINKS[@]}"; do
        ip link del "$dev" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# 在中转机里运行 nft.sh（非交互）
run_relay() {
    ip netns exec "$RELAY" env "${RUN_ENV[@]}" bash "$SCRIPT" "$@" </dev/null 2>&1
}

run_ok() {     # run_ok 描述 nft.sh参数...
    local desc="$1" out
    shift
    if out=$(run_relay "$@"); then
        pass "$desc"
    else
        fail "$desc"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
}

run_fail() {   # run_fail 描述 nft.sh参数...（应当失败）
    local desc="$1" out
    shift
    if out=$(run_relay "$@"); then
        fail "$desc（应当失败）"
        printf '%s\n' "$out" | sed 's/^/    /'
    else
        pass "$desc"
    fi
}

query() {      # query 命名空间 协议 地址 端口 [源地址]
    local ns="$1"
    shift
    ip netns exec "$ns" python3 "$WORK/client.py" "$@" 2>/dev/null
}

expect() {     # expect 描述 期望响应 命名空间 协议 地址 端口 [源地址]
    local desc="$1" want="$2" got
    shift 2
    got=$(query "$@")
    if [ "$got" = "$want" ]; then
        pass "$desc"
    else
        fail "$desc（期望 '$want'，实际 '${got:-无响应}'）"
    fi
}

expect_blocked() {   # expect_blocked 描述 命名空间 协议 地址 端口 [源地址]
    local desc="$1" got
    shift
    got=$(query "$@")
    if [ -z "$got" ]; then
        pass "$desc"
    else
        fail "$desc（应被拦截，实际收到 '$got'）"
    fi
}

check() {      # check 描述 命令...
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

write_helpers() {
    cat > "$WORK/server.py" <<'EOF'
import socket, sys, threading

host, tag = sys.argv[1], sys.argv[2]
family = socket.AF_INET6 if ":" in host else socket.AF_INET
ports = [int(p) for p in sys.argv[3:]]

def tcp(port):
    s = socket.socket(family, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port))
    s.listen(16)
    while True:
        c, _ = s.accept()
        c.sendall(("%s:%d\n" % (tag, port)).encode())
        c.close()

def udp(port):
    s = socket.socket(family, socket.SOCK_DGRAM)
    s.bind((host, port))
    while True:
        _, addr = s.recvfrom(100)
        s.sendto(("%s:%d\n" % (tag, port)).encode(), addr)

for p in ports:
    threading.Thread(target=tcp, args=(p,), daemon=True).start()
    threading.Thread(target=udp, args=(p,), daemon=True).start()
threading.Event().wait()
EOF

    cat > "$WORK/client.py" <<'EOF'
import socket, sys

proto, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
src = sys.argv[4] if len(sys.argv) > 4 else None
family = socket.AF_INET6 if ":" in host else socket.AF_INET
s = socket.socket(family, socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM)
s.settimeout(2)
if src:
    s.bind((src, 0))
if proto == "tcp":
    s.connect((host, port))
    print(s.recv(100).decode().strip())
else:
    s.sendto(b"ping", (host, port))
    print(s.recvfrom(100)[0].decode().strip())
EOF
}

setup_network() {
    ip netns add "$CLI" || return 1
    CREATED_NS+=("$CLI")
    ip netns add "$RELAY" || return 1
    CREATED_NS+=("$RELAY")
    ip netns add "$TGT" || return 1
    CREATED_NS+=("$TGT")
    ip link add "$C_LINK" type veth peer name "$R0_LINK" || return 1
    CREATED_LINKS+=("$C_LINK" "$R0_LINK")
    ip link add "$T_LINK" type veth peer name "$R1_LINK" || return 1
    CREATED_LINKS+=("$T_LINK" "$R1_LINK")
    ip link set "$C_LINK" netns "$CLI" || return 1
    ip link set "$R0_LINK" netns "$RELAY" || return 1
    ip link set "$R1_LINK" netns "$RELAY" || return 1
    ip link set "$T_LINK" netns "$TGT" || return 1

    ip -n "$CLI" addr add 10.10.1.2/24 dev "$C_LINK" || return 1
    ip -n "$CLI" addr add 10.10.1.3/24 dev "$C_LINK" || return 1
    ip -n "$CLI" -6 addr add 2001:db8:1::2/64 dev "$C_LINK" nodad || return 1
    ip -n "$CLI" -6 addr add 2001:db8:1::3/64 dev "$C_LINK" nodad || return 1
    ip -n "$CLI" link set "$C_LINK" up || return 1
    ip -n "$CLI" link set lo up || return 1
    ip -n "$CLI" route add default via 10.10.1.1 || return 1

    ip -n "$RELAY" addr add 10.10.1.1/24 dev "$R0_LINK" || return 1
    ip -n "$RELAY" addr add 10.10.2.1/24 dev "$R1_LINK" || return 1
    ip -n "$RELAY" -6 addr add 2001:db8:1::1/64 dev "$R0_LINK" nodad || return 1
    ip -n "$RELAY" link set "$R0_LINK" up || return 1
    ip -n "$RELAY" link set "$R1_LINK" up || return 1
    ip -n "$RELAY" link set lo up || return 1

    # 目标机故意不设默认路由：如果没有 masquerade，回包到不了客户端，转发测试会失败
    ip -n "$TGT" addr add 10.10.2.2/24 dev "$T_LINK" || return 1
    ip -n "$TGT" addr add 10.10.2.3/24 dev "$T_LINK" || return 1
    ip -n "$TGT" link set "$T_LINK" up || return 1
    ip -n "$TGT" link set lo up || return 1
}

start_servers() {
    ip netns exec "$TGT" python3 "$WORK/server.py" 10.10.2.2 target 80 20000 20001 20002 30000 30001 &
    PIDS+=("$!")
    ip netns exec "$TGT" python3 "$WORK/server.py" 10.10.2.3 other 8080 &
    PIDS+=("$!")
    ip netns exec "$RELAY" python3 "$WORK/server.py" 0.0.0.0 relay 9999 &
    PIDS+=("$!")
    ip netns exec "$RELAY" python3 "$WORK/server.py" 2001:db8:1::1 relay6 9999 &
    PIDS+=("$!")
    sleep 1
}

run_rollback_driver() {
    ip netns exec "$RELAY" env "${DEFAULT_ENV[@]}" \
        bash "$WORK/rollback-driver.sh" "$SCRIPT" "$WORK" "${1:-2}"
}

test_rollback() {
    local confirm_fd driver_pid foreground_pid ready=0 i snap
    cat > "$WORK/rollback-driver.sh" <<'EOF'
#!/bin/bash
source "$1"
INTERACTIVE=1
ROLLBACK_TIMEOUT="$3"
begin_action || exit 1
trap end_action EXIT
printf '%s' "$SNAPSHOT_DIR" > "$2/rollback.snapshot"
printf '%s' "$BASHPID" > "$2/rollback.pid"
wl_remove 10.10.1.3 >/dev/null || exit 1
CONFIRM_ALWAYS=1
apply_all_rules
EOF

    echo "== 确认与超时回滚 =="
    run_ok "为回滚测试添加第二个客户端" add-ip 10.10.1.3
    if run_rollback_driver <<< n > "$WORK/rollback.log" 2>&1; then
        fail "拒绝确认应返回失败"
    else
        pass "拒绝确认返回失败"
    fi
    expect "拒绝后恢复原白名单" "relay:9999" "$CLI" tcp 10.10.1.1 9999 10.10.1.3

    if run_rollback_driver 1 < <(sleep 2) > "$WORK/rollback.log" 2>&1; then
        fail "等待确认超时应返回失败"
    else
        pass "等待确认超时返回失败"
    fi
    expect "超时后恢复原白名单" "relay:9999" "$CLI" tcp 10.10.1.1 9999 10.10.1.3

    check "确认 y 后应用成功" run_rollback_driver <<< y
    expect_blocked "确认后新的白名单保持生效" "$CLI" tcp 10.10.1.1 9999 10.10.1.3
    run_ok "恢复第二个客户端供后台回滚测试" add-ip 10.10.1.3

    # 保持 stdin 打开但不输入，等真实 apply 进入确认界面后终止主脚本。
    # 后台 setsid 任务必须保留中转机命名空间，且在前台退出后仍能恢复规则。
    mkfifo "$WORK/confirm.fifo"
    exec {confirm_fd}<>"$WORK/confirm.fifo"
    run_rollback_driver < "$WORK/confirm.fifo" > "$WORK/rollback.log" 2>&1 &
    driver_pid=$!
    PIDS+=("$driver_pid")
    for ((i = 0; i < 30; i++)); do
        if grep -q '确认正常请在' "$WORK/rollback.log"; then ready=1; break; fi
        sleep 0.05
    done
    if [ "$ready" -eq 1 ]; then
        snap=$(cat "$WORK/rollback.snapshot")
        foreground_pid=$(cat "$WORK/rollback.pid")
        kill -TERM "$foreground_pid"
        wait "$driver_pid" 2>/dev/null || true
        pass "规则加载后终止前台进程"
        expect_blocked "后台回滚前删减后的规则已生效" "$CLI" tcp 10.10.1.1 9999 10.10.1.3
        for ((i = 0; i < 100; i++)); do
            [ -d "$snap" ] || break
            sleep 0.1
        done
        check "后台任务完成并清理快照" test ! -d "$snap"
        expect "前台退出后后台恢复了真实规则" "relay:9999" "$CLI" tcp 10.10.1.1 9999 10.10.1.3
        check "前台退出后后台恢复了配置文件" grep -qx '10.10.1.3' "$NFT_SH_WHITELIST_FILE"
    else
        fail "前台进程未进入确认界面"
        cat "$WORK/rollback.log"
        kill -TERM "$driver_pid" 2>/dev/null
        wait "$driver_pid" 2>/dev/null || true
    fi
    exec {confirm_fd}>&-
}

main() {
    local listing cmd legacy

    if [ "$EUID" -ne 0 ]; then
        echo "需要 root 权限运行: sudo bash $0"
        exit 1
    fi
    for cmd in nft ip python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "缺少命令: $cmd"
            exit 1
        fi
    done

    write_helpers
    setup_network || { echo "创建隔离网络失败"; exit 1; }
    start_servers

    echo 1 > "$NFT_SH_ENABLED_FILE"
    : > "$NFT_SH_WHITELIST_FILE"
    : > "$NFT_SH_FORWARD_FILE"

    echo "== 输入校验与防失联 =="
    run_fail "拒绝无效 IP" add-ip 999.1.1.1
    run_fail "拒绝域名" add-ip example.com
    run_fail "白名单为空时，非交互模式拒绝应用（防失联）" apply
    run_ok   "添加白名单 10.10.1.2" add-ip 10.10.1.2
    run_ok   "添加 IPv6 CIDR" add-ip 2001:db8:2::1/64
    check    "CIDR 主机位已清零" grep -qx "2001:db8:2::/64" "$NFT_SH_WHITELIST_FILE"
    run_ok   "添加 IPv6 客户端" add-ip 2001:db8:1::2
    run_fail "拒绝重复添加" add-ip 10.10.1.2
    run_ok   "添加单端口转发 8080 -> 10.10.2.2:80" add-forward 8080 10.10.2.2 80
    run_ok   "添加端口段转发 10000-10002 -> 20000-20002" add-forward 10000-10002 10.10.2.2 20000-20002
    run_ok   "添加同号端口段转发 30000-30001" add-forward 30000-30001 10.10.2.2 30000-30001
    run_fail "拒绝端口越界" add-forward 60000-70000 10.10.2.2 60000-70000
    run_fail "拒绝与已有端口段重叠" add-forward 10001 10.10.2.2 80
    run_fail "拒绝端口数量不一致" add-forward 40000-40002 10.10.2.2 50000-50005
    run_fail "拒绝域名目标" add-forward 40000 example.com 80
    run_fail "拒绝回环目标" add-forward 40000 127.0.0.1 80
    RUN_ENV=("SSH_CONNECTION=10.10.1.2 50000 10.10.1.1 2222")
    run_fail "拒绝转发 SSH 端口" add-forward 2222 10.10.2.2 22
    run_fail "非交互模式拒绝删除当前 SSH 来源 IP" del-ip 10.10.1.2
    RUN_ENV=("${DEFAULT_ENV[@]}")
    check    "被拒绝后白名单保持不变" grep -qx "10.10.1.2" "$NFT_SH_WHITELIST_FILE"
    check    "添加转发时自动开启 IPv4 转发" test "$(ip netns exec "$RELAY" cat /proc/sys/net/ipv4/ip_forward)" = "1"

    echo "== 规则内容 =="
    listing=$(ip netns exec "$RELAY" nft list table inet unified 2>&1)
    check "inet unified 表已加载" grep -q "table inet unified" <<< "$listing"
    check "DNAT 写法为 dnat ip to" grep -q "dnat ip to 10.10.2.2:80" <<< "$listing"
    check "端口映射表已加载" grep -q "10001 : 20001" <<< "$listing"
    check "IPv6 白名单已加载" grep -q "2001:db8:2::/64" <<< "$listing"
    check "input 默认拒绝" grep -q "policy drop" <<< "$listing"
    check "持久化文件写到了测试目录" test -s "$NFT_SH_PERSIST_DIR/unified.nft"
    check "include 行写到了测试用的主配置" grep -qxF "include \"$NFT_SH_PERSIST_DIR/unified.nft\"" "$NFT_SH_MAIN_CONF"
    check "持久化文件可以重复加载（第 1 次）" ip netns exec "$RELAY" nft -f "$NFT_SH_PERSIST_DIR/unified.nft"
    check "持久化文件可以重复加载（第 2 次）" ip netns exec "$RELAY" nft -f "$NFT_SH_PERSIST_DIR/unified.nft"

    echo "== 转发与白名单 =="
    expect "TCP 单端口转发" "target:80" "$CLI" tcp 10.10.1.1 8080 10.10.1.2
    expect "UDP 单端口转发" "target:80" "$CLI" udp 10.10.1.1 8080 10.10.1.2
    expect "端口段一一对应 10000 -> 20000" "target:20000" "$CLI" tcp 10.10.1.1 10000 10.10.1.2
    expect "端口段一一对应 10001 -> 20001" "target:20001" "$CLI" tcp 10.10.1.1 10001 10.10.1.2
    expect "端口段一一对应 10002 -> 20002 (UDP)" "target:20002" "$CLI" udp 10.10.1.1 10002 10.10.1.2
    expect "同号端口段保持原端口 30001" "target:30001" "$CLI" tcp 10.10.1.1 30001 10.10.1.2
    expect_blocked "非白名单 IP 不能使用转发" "$CLI" tcp 10.10.1.1 8080 10.10.1.3
    expect "白名单 IP 可以访问本机服务" "relay:9999" "$CLI" tcp 10.10.1.1 9999 10.10.1.2
    expect_blocked "非白名单 IP 不能访问本机服务" "$CLI" tcp 10.10.1.1 9999 10.10.1.3
    expect "本机访问其他服务器的同号端口不会被劫持" "other:8080" "$RELAY" tcp 10.10.2.3 8080
    expect "本机访问自己的转发端口" "target:80" "$RELAY" tcp 10.10.1.1 8080
    expect "IPv6 白名单 TCP 可以访问本机" "relay6:9999" "$CLI" tcp 2001:db8:1::1 9999 2001:db8:1::2
    expect "IPv6 白名单 UDP 可以访问本机" "relay6:9999" "$CLI" udp 2001:db8:1::1 9999 2001:db8:1::2
    expect_blocked "IPv6 非白名单 TCP 被拦截" "$CLI" tcp 2001:db8:1::1 9999 2001:db8:1::3
    expect_blocked "IPv6 非白名单 UDP 被拦截" "$CLI" udp 2001:db8:1::1 9999 2001:db8:1::3

    # 前面的测试先证明无回程路由也能通过 masquerade 转发；再补路由验证普通转发流量。
    check "添加普通路由流量的回程路由" ip -n "$TGT" route add 10.10.1.0/24 via 10.10.2.1
    expect "客户端访问外部同号端口不会被劫持" "other:8080" "$CLI" tcp 10.10.2.3 8080 10.10.1.2
    expect "非白名单的普通路由 TCP 不受影响" "other:8080" "$CLI" tcp 10.10.2.3 8080 10.10.1.3
    expect "非白名单的普通路由 UDP 不受影响" "other:8080" "$CLI" udp 10.10.2.3 8080 10.10.1.3

    echo "== 白名单开关与删除 =="
    run_ok "关闭白名单" whitelist off
    expect "关闭后任意 IP 可以使用转发" "target:80" "$CLI" tcp 10.10.1.1 8080 10.10.1.3
    expect "关闭后任意 IP 可以访问本机服务" "relay:9999" "$CLI" tcp 10.10.1.1 9999 10.10.1.3
    expect "关闭后 IPv6 非白名单也可访问" "relay6:9999" "$CLI" tcp 2001:db8:1::1 9999 2001:db8:1::3
    run_ok "重新启用白名单" whitelist on
    expect_blocked "重新启用后非白名单 IP 被拦截" "$CLI" tcp 10.10.1.1 8080 10.10.1.3
    run_ok "删除端口段转发" del-forward 10000-10002
    expect_blocked "删除后不再转发" "$CLI" tcp 10.10.1.1 10001 10.10.1.2

    test_rollback

    echo "== 与其他表共存 =="
    legacy="$WORK/legacy.nft"
    printf '%s\n' \
        'table inet filter {' \
        '    chain input { type filter hook input priority 0; policy accept; }' \
        '}' \
        'table inet unified_nat {' \
        '}' > "$legacy"
    check "创建用户表和旧版本遗留表" ip netns exec "$RELAY" nft -f "$legacy"
    if run_rollback_driver <<< n > "$WORK/rollback.log" 2>&1; then
        fail "升级规则拒绝确认应回滚"
    else
        pass "升级规则拒绝确认返回失败"
    fi
    check "升级回滚恢复旧版本遗留表" ip netns exec "$RELAY" nft list table inet unified_nat
    run_ok "重新应用规则" apply
    check "保留用户自己的 inet filter 表" ip netns exec "$RELAY" nft list table inet filter
    if ip netns exec "$RELAY" nft list table inet unified_nat >/dev/null 2>&1; then
        fail "删除旧版本遗留的 inet unified_nat 表"
    else
        pass "删除旧版本遗留的 inet unified_nat 表"
    fi
    expect "共存时转发仍然正常" "target:80" "$CLI" tcp 10.10.1.1 8080 10.10.1.2

    echo ""
    echo "集成测试: 通过 $PASS，失败 $FAIL"
    [ "$FAIL" -eq 0 ]
}

main "$@"
