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
CLI=nfttest_cli
RELAY=nfttest_relay
TGT=nfttest_tgt
PASS=0
FAIL=0
PIDS=()
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
    local p ns
    for p in "${PIDS[@]}"; do
        kill "$p" 2>/dev/null
    done
    for ns in "$CLI" "$RELAY" "$TGT"; do
        ip netns del "$ns" 2>/dev/null
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
ports = [int(p) for p in sys.argv[3:]]

def tcp(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port))
    s.listen(16)
    while True:
        c, _ = s.accept()
        c.sendall(("%s:%d\n" % (tag, port)).encode())
        c.close()

def udp(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
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
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM)
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
    ip netns add "$CLI"
    ip netns add "$RELAY"
    ip netns add "$TGT"
    ip link add nfttest_c0 type veth peer name nfttest_r0
    ip link add nfttest_t0 type veth peer name nfttest_r1
    ip link set nfttest_c0 netns "$CLI"
    ip link set nfttest_r0 netns "$RELAY"
    ip link set nfttest_r1 netns "$RELAY"
    ip link set nfttest_t0 netns "$TGT"

    ip -n "$CLI" addr add 10.10.1.2/24 dev nfttest_c0
    ip -n "$CLI" addr add 10.10.1.3/24 dev nfttest_c0
    ip -n "$CLI" link set nfttest_c0 up
    ip -n "$CLI" link set lo up
    ip -n "$CLI" route add default via 10.10.1.1

    ip -n "$RELAY" addr add 10.10.1.1/24 dev nfttest_r0
    ip -n "$RELAY" addr add 10.10.2.1/24 dev nfttest_r1
    ip -n "$RELAY" link set nfttest_r0 up
    ip -n "$RELAY" link set nfttest_r1 up
    ip -n "$RELAY" link set lo up

    # 目标机故意不设默认路由：如果没有 masquerade，回包到不了客户端，转发测试会失败
    ip -n "$TGT" addr add 10.10.2.2/24 dev nfttest_t0
    ip -n "$TGT" addr add 10.10.2.3/24 dev nfttest_t0
    ip -n "$TGT" link set nfttest_t0 up
    ip -n "$TGT" link set lo up
}

start_servers() {
    ip netns exec "$TGT" python3 "$WORK/server.py" 10.10.2.2 target 80 20000 20001 20002 30000 30001 &
    PIDS+=("$!")
    ip netns exec "$TGT" python3 "$WORK/server.py" 10.10.2.3 other 8080 &
    PIDS+=("$!")
    ip netns exec "$RELAY" python3 "$WORK/server.py" 0.0.0.0 relay 9999 &
    PIDS+=("$!")
    sleep 1
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
    setup_network
    start_servers

    echo 1 > "$NFT_SH_ENABLED_FILE"
    : > "$NFT_SH_WHITELIST_FILE"
    : > "$NFT_SH_FORWARD_FILE"

    echo "== 输入校验与防失联 =="
    run_fail "拒绝无效 IP" add-ip 999.1.1.1
    run_fail "拒绝域名" add-ip example.com
    run_fail "白名单为空时，非交互模式拒绝应用（防失联）" apply
    run_ok   "添加白名单 10.10.1.2" add-ip 10.10.1.2
    run_ok   "添加 IPv6 CIDR" add-ip 2001:db8::1/32
    check    "CIDR 主机位已清零" grep -qx "2001:db8::/32" "$NFT_SH_WHITELIST_FILE"
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
    check "IPv6 白名单已加载" grep -q "2001:db8::/32" <<< "$listing"
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

    echo "== 白名单开关与删除 =="
    run_ok "关闭白名单" whitelist off
    expect "关闭后任意 IP 可以使用转发" "target:80" "$CLI" tcp 10.10.1.1 8080 10.10.1.3
    expect "关闭后任意 IP 可以访问本机服务" "relay:9999" "$CLI" tcp 10.10.1.1 9999 10.10.1.3
    run_ok "重新启用白名单" whitelist on
    expect_blocked "重新启用后非白名单 IP 被拦截" "$CLI" tcp 10.10.1.1 8080 10.10.1.3
    run_ok "删除端口段转发" del-forward 10000-10002
    expect_blocked "删除后不再转发" "$CLI" tcp 10.10.1.1 10001 10.10.1.2

    echo "== 与其他表共存 =="
    legacy="$WORK/legacy.nft"
    printf '%s\n' \
        'table inet filter {' \
        '    chain input { type filter hook input priority 0; policy accept; }' \
        '}' \
        'table inet unified_nat {' \
        '}' > "$legacy"
    check "创建用户表和旧版本遗留表" ip netns exec "$RELAY" nft -f "$legacy"
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
