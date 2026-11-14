#!/bin/bash
# 真实 Docker 端口映射 / 容器出站 / WireGuard 联测。需要 root、Docker、wg、python3。
# 只用于没有部署本脚本表的一次性测试机；退出时恢复规则并删除测试资源。
# shellcheck disable=SC2034,SC2154
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d /var/tmp/nft-coexist.XXXXXX)
TAG=$$
NET="nft-coexist-$TAG" BOX="nft-coexist-$TAG"
NS1="nft-coexist-a-$TAG" NS2="nft-coexist-b-$TAG"
NS3="nft-coexist-c-$TAG"
V1="nca$TAG" R1="nra$TAG" V2="ncb$TAG" R2="nrb$TAG" WG="nwg$TAG"
V3="ncc$TAG" R3="nrc$TAG"
BASE="" NET_CREATED=0 BOX_CREATED=0 NS1_CREATED=0 NS2_CREATED=0 WG_CREATED=0
NS3_CREATED=0
PASS=0 FAIL=0 SERVER=""
OLD_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward)
cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ] || [ "$FAIL" -ne 0 ]; then
        [ "$BOX_CREATED" -eq 0 ] || docker logs "$BOX" 2>&1 || true
        [ ! -f "$WORK/http.log" ] || cat "$WORK/http.log"
    fi
    if [ -n "$BASE" ] && [ -d "$BASE" ]; then restore_snapshot "$BASE"; fi
    iptables -D DOCKER-USER -i "$WG" -m comment --comment "$NET" -j ACCEPT 2>/dev/null || true
    iptables -D DOCKER-USER -o "$WG" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$NET" -j ACCEPT 2>/dev/null || true
    [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true
    [ "$WG_CREATED" -eq 0 ] || ip link del "$WG"
    [ "$NS1_CREATED" -eq 0 ] || ip netns del "$NS1"
    [ "$NS2_CREATED" -eq 0 ] || ip netns del "$NS2"
    [ "$NS3_CREATED" -eq 0 ] || ip netns del "$NS3"
    ip link del "$R1" 2>/dev/null || true
    ip link del "$R2" 2>/dev/null || true
    ip link del "$R3" 2>/dev/null || true
    [ "$BOX_CREATED" -eq 0 ] || docker rm -f "$BOX" >/dev/null
    [ "$NET_CREATED" -eq 0 ] || docker network rm "$NET" >/dev/null
    sysctl -w "net.ipv4.ip_forward=$OLD_FORWARD" >/dev/null
    rm -rf -- "$WORK"
}
trap cleanup EXIT
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "FAIL: $desc"; fi
}
[ "$EUID" -eq 0 ] || exit 1
for cmd in nft docker wg iptables python3; do command -v "$cmd" >/dev/null || exit 1; done
docker info >/dev/null
for prefix in 198.18.238.0/24 198.19.237.0/24 10.239.31.0/24; do
    [ -z "$(ip route show exact "$prefix")" ] || { echo "测试网段已使用: $prefix"; exit 1; }
done
export NFT_SH_WHITELIST_FILE="$WORK/whitelist" NFT_SH_FORWARD_FILE="$WORK/forward"
export NFT_SH_ENABLED_FILE="$WORK/enabled" NFT_SH_PERSIST_DIR="$WORK/nftables.d"
export NFT_SH_MAIN_CONF="$WORK/nftables.conf" NFT_SH_SYSCTL_FILE="$WORK/sysctl.conf"
mkdir "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/systemctl"
chmod +x "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH"
# shellcheck source=../nft.sh
source "$ROOT/nft.sh"
for table in "$NFT_TABLE" "${LEGACY_TABLES[@]}"; do
    if nft_table_exists "$table"; then echo "已有 inet $table，拒绝覆盖"; exit 1; fi
done
begin_action
BASE="$SNAPSHOT_DIR"
mkdir "$WORK/fixture"
cp "$ROOT/tests/echo_server.py" "$WORK/fixture/echo_server.py"
docker network create --subnet 172.30.237.0/24 "$NET" >/dev/null
NET_CREATED=1
docker run -d --name "$BOX" --network "$NET" --ip 172.30.237.2 \
    -p 46880:8080 -p 46990:9090/udp -v "$WORK/fixture:/fixture:ro" \
    "${NFT_TEST_DOCKER_IMAGE:-python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e}" \
    python3 /fixture/echo_server.py --bind 0.0.0.0 --tcp 8080 --udp 9090 --body nft-docker >/dev/null
BOX_CREATED=1
ip netns add "$NS1"; NS1_CREATED=1
ip netns add "$NS2"; NS2_CREATED=1
ip link add "$R1" type veth peer name "$V1"
ip link set "$V1" netns "$NS1"
ip addr add 198.18.238.1/29 dev "$R1"; ip link set "$R1" up
ip -n "$NS1" addr add 198.18.238.2/29 dev "$V1"
ip -n "$NS1" addr add 198.18.238.3/29 dev "$V1"
ip -n "$NS1" link set "$V1" up; ip -n "$NS1" link set lo up
ip -n "$NS1" route add default via 198.18.238.1
ip link add "$R2" type veth peer name "$V2"
ip link set "$V2" netns "$NS2"
ip addr add 198.18.238.5/30 dev "$R2"; ip link set "$R2" up
ip -n "$NS2" addr add 198.18.238.6/30 dev "$V2"
ip -n "$NS2" link set "$V2" up; ip -n "$NS2" link set lo up
ip -n "$NS2" route add default via 198.18.238.5
ip netns add "$NS3"; NS3_CREATED=1
ip link add "$R3" type veth peer name "$V3"
ip link set "$V3" netns "$NS3"
ip addr add 198.19.237.1/24 dev "$R3"; ip link set "$R3" up
ip -n "$NS3" addr add 198.19.237.2/24 dev "$V3"
ip -n "$NS3" link set "$V3" up; ip -n "$NS3" link set lo up
ip -n "$NS3" route add default via 198.19.237.1
sysctl -w net.ipv4.ip_forward=1 >/dev/null
umask 077
for peer in host a b; do wg genkey > "$WORK/$peer.key"; wg pubkey < "$WORK/$peer.key" > "$WORK/$peer.pub"; done
ip link add "$WG" type wireguard; WG_CREATED=1
ip addr add 10.239.31.1/24 dev "$WG"
# 通过标准输入传递密钥，兼容对临时文件路径有访问限制的 wg/ip 执行环境。
(
    set -o pipefail
    cat "$WORK/host.key" | wg set "$WG" private-key /dev/stdin listen-port 51859 \
        peer "$(cat "$WORK/a.pub")" allowed-ips 10.239.31.2/32 \
        peer "$(cat "$WORK/b.pub")" allowed-ips 10.239.31.3/32
)
ip link set "$WG" up
setup_peer() {
    local ns="$1" peer="$2" inner="$3" endpoint="$4"
    ip -n "$ns" link add wg0 type wireguard
    ip -n "$ns" addr add "$inner/32" dev wg0
    (
        set -o pipefail
        cat "$WORK/$peer.key" | ip netns exec "$ns" wg set wg0 private-key /dev/stdin peer "$(cat "$WORK/host.pub")" \
            endpoint "$endpoint:51859" allowed-ips 10.239.31.0/24,198.19.237.0/24 persistent-keepalive 1
    )
    ip -n "$ns" link set wg0 up
    ip -n "$ns" route add 10.239.31.0/24 dev wg0
    ip -n "$ns" route add 198.19.237.0/24 dev wg0
}
setup_peer "$NS1" a 10.239.31.2 198.18.238.1
setup_peer "$NS2" b 10.239.31.3 198.18.238.5
# Docker 的默认 FORWARD 策略另行放行本次 WG 测试流量，测试结束删除这两条带标记的规则。
iptables -I DOCKER-USER -i "$WG" -m comment --comment "$NET" -j ACCEPT
iptables -I DOCKER-USER -o "$WG" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$NET" -j ACCEPT
python3 - <<'PY' > "$WHITELIST_FILE"
import ipaddress
nets=[ipaddress.ip_network("0.0.0.0/0")]
for excluded in ("198.18.238.0/24", "10.239.31.0/24"):
    ex=ipaddress.ip_network(excluded)
    nets=[part for net in nets for part in (net.address_exclude(ex) if ex.subnet_of(net) else [net])]
for net in nets: print(net)
print("198.18.238.2\n198.18.238.6\n10.239.31.2\n::/0")
PY
printf '48080|172.30.237.2|8080\n48090|172.30.237.2|9090\n' > "$FORWARD_FILE"
echo 1 > "$WHITELIST_ENABLED_FILE"
apply_all_rules > "$WORK/apply.log" 2>&1 || { cat "$WORK/apply.log"; exit 1; }
ip netns exec "$NS3" python3 "$ROOT/tests/echo_server.py" --bind 198.19.237.2 --tcp 48080 --udp 48081 --body nft-external > "$WORK/http.log" 2>&1 &
SERVER=$!
cat > "$WORK/client.py" <<'PY'
import socket,sys
host,port,src,proto=sys.argv[1],int(sys.argv[2]),sys.argv[3],sys.argv[4]
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM if proto=="tcp" else socket.SOCK_DGRAM);s.settimeout(2);s.bind((src,0))
if proto=="udp":
    s.sendto(b"nft-udp",(host,port));print(s.recvfrom(100)[0].decode())
else:
    s.connect((host,port));s.sendall(b"GET / HTTP/1.0\r\nHost: test\r\n\r\n");data=b""
    while True:
        chunk=s.recv(4096)
        if not chunk:break
        data+=chunk
    print(data.split(b"\r\n\r\n",1)[1].decode().strip())
PY
query() { local ns="$1"; shift; ip netns exec "$ns" python3 "$WORK/client.py" "$@" 2>/dev/null; }
expect() {
    local desc="$1" expected="$2" got
    shift 2
    got=$(query "$@") || got=""
    if [ "$got" != "$expected" ]; then
        printf '  期望=%q 实际=%q\n' "$expected" "$got"
    fi
    check "$desc" test "$got" = "$expected"
}
sleep 1
expect "外部 HTTP 服务本身正常" nft-external "$NS3" 198.19.237.2 48080 198.19.237.2 tcp
expect "Docker 发布 TCP 端口允许白名单" nft-docker "$NS1" 198.18.238.1 46880 198.18.238.2 tcp
expect "Docker 发布 TCP 端口拦截非白名单" "" "$NS1" 198.18.238.1 46880 198.18.238.3 tcp
expect "Docker 发布 UDP 端口允许白名单" nft-udp "$NS1" 198.18.238.1 46990 198.18.238.2 udp
expect "Docker 发布 UDP 端口拦截非白名单" "" "$NS1" 198.18.238.1 46990 198.18.238.3 udp
expect "本脚本 TCP 转发到真实容器" nft-docker "$NS1" 198.18.238.1 48080 198.18.238.2 tcp
expect "本脚本 UDP 转发到真实容器" nft-udp "$NS1" 198.18.238.1 48090 198.18.238.2 udp
body=$(docker exec "$BOX" python3 -c 'import urllib.request; print(urllib.request.urlopen("http://198.19.237.2:48080",timeout=3).read().decode().strip())' 2>/dev/null) || body=""
check "容器访问外部同号端口不被劫持" test "$body" = nft-external
expect "WireGuard 白名单客户端访问 Docker 映射端口" nft-docker "$NS1" 10.239.31.1 46880 10.239.31.2 tcp
expect "WireGuard 非白名单客户端被映射端口拦截" "" "$NS2" 10.239.31.1 46880 10.239.31.3 tcp
expect "WireGuard 白名单客户端使用 UDP 转发" nft-udp "$NS1" 10.239.31.1 48090 10.239.31.2 udp
expect "非白名单 WireGuard 普通路由流量不被误拦" nft-external "$NS2" 198.19.237.2 48080 10.239.31.3 tcp
handshakes=$(wg show "$WG" latest-handshakes | awk '$2 > 0 {n++} END {print n+0}')
check "两个真实 WireGuard 对等端都已握手" test "$handshakes" = 2
echo "Docker/WireGuard 联测: 通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
