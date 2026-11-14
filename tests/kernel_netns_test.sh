#!/bin/bash
# Real four-family forwarding tests. All addresses, routes and nft tables live
# in a disposable network/mount namespace. Jool must already be installed.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${NFT_KERNEL_ROLLBACK_TIMEOUT:=3}"
[[ "$NFT_KERNEL_ROLLBACK_TIMEOUT" =~ ^[1-9][0-9]?$ ]] && [ "$NFT_KERNEL_ROLLBACK_TIMEOUT" -le 60 ] || exit 2
export NFT_KERNEL_ROLLBACK_TIMEOUT
if [ "${1:-}" != --inside ]; then
    [ "$EUID" -eq 0 ] || { echo 'root required' >&2; exit 1; }
    for tool in unshare ip nft python3 jool; do command -v "$tool" >/dev/null; done
    modprobe jool
    exec unshare --mount --net --fork bash "$0" --inside "${1:-}"
fi
mount --make-rprivate /
mkdir -p /run/netns
mount -t tmpfs tmpfs /run/netns
WORK=$(mktemp -d)
CLI="nftkc_$$"; TGT="nftkt_$$"; N64="nftk64_$$"; N46="nftk46_$$"
PIDS=(); PASS=0; FAIL=0
cleanup() {
    local rc=$? p ns file
    if [ "$rc" -ne 0 ] || [ "$FAIL" -ne 0 ]; then
        nft list ruleset || true
        for file in "$WORK"/*.log; do [ ! -f "$file" ] || { echo "DIAGNOSTIC: $file"; cat "$file"; }; done
    fi
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    for ns in "$N64" "$N46" "$CLI" "$TGT"; do ip netns del "$ns" 2>/dev/null || true; done
    rm -rf -- "$WORK"
}
trap cleanup EXIT
for ns in "$CLI" "$TGT"; do ip netns add "$ns"; ip -n "$ns" link set lo up; done
ip link set lo up
ip link add kc type veth peer name cli
ip link set cli netns "$CLI"
ip link add kt type veth peer name tgt
ip link set tgt netns "$TGT"
ip addr add 10.201.1.1/24 dev kc
ip -6 addr add 2001:db8:201::1/64 dev kc nodad
ip addr add 10.201.2.1/24 dev kt
ip -6 addr add 2001:db8:202::1/64 dev kt nodad
ip link set kc up; ip link set kt up
ip -n "$CLI" addr add 10.201.1.2/24 dev cli
ip -n "$CLI" addr add 10.201.1.3/24 dev cli
ip -n "$CLI" addr add 10.201.1.4/24 dev cli
ip -n "$CLI" -6 addr add 2001:db8:201::2/64 dev cli nodad
ip -n "$CLI" -6 addr add 2001:db8:201::3/64 dev cli nodad
ip -n "$CLI" -6 addr add 2001:db8:201::4/64 dev cli nodad
ip -n "$CLI" link set cli up
ip -n "$CLI" route add default via 10.201.1.1
ip -n "$CLI" -6 route add default via 2001:db8:201::1
# No default route on the backend: replies require the intended SNAT path.
ip -n "$TGT" addr add 10.201.2.2/24 dev tgt
ip -n "$TGT" -6 addr add 2001:db8:202::2/64 dev tgt nodad
ip -n "$TGT" link set tgt up
sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1

cat > "$WORK/echo.py" <<'PY'
import socket, sys, threading
host = sys.argv[1]
family = socket.AF_INET6 if ':' in host else socket.AF_INET
def serve(proto, port):
    sock = socket.socket(family, proto)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, port))
    tag = ('%s:%d:' % (host, port)).encode()
    if proto == socket.SOCK_DGRAM:
        while True:
            data, addr = sock.recvfrom(65535)
            sock.sendto(tag + data, addr)
    else:
        sock.listen(16)
        while True:
            conn, _ = sock.accept()
            with conn:
                data = bytearray()
                while True:
                    part = conn.recv(65535)
                    if not part: break
                    data.extend(part)
                conn.sendall(tag + data)
for port in (20000, 20001, 20002, 35000, 35001, 35002, 35010, 35011, 35012, 36000, 36001, 36002):
    for proto in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        threading.Thread(target=serve, args=(proto, port), daemon=True).start()
threading.Event().wait()
PY
cat > "$WORK/query.py" <<'PY'
import socket, sys
proto, host, port, src, target, target_port, size = sys.argv[1:]
size = int(size)
payload = bytes((i % 251 for i in range(size)))
family = socket.AF_INET6 if ':' in host else socket.AF_INET
sock = socket.socket(family, socket.SOCK_STREAM if proto == 'tcp' else socket.SOCK_DGRAM)
sock.settimeout(2)
sock.bind((src, 0))
expected = ('%s:%s:' % (target, target_port)).encode() + payload
try:
    if proto == 'tcp':
        sock.connect((host, int(port)))
        sock.sendall(payload)
        sock.shutdown(socket.SHUT_WR)
        data = bytearray()
        while True:
            part = sock.recv(65535)
            if not part: break
            data.extend(part)
        assert data == expected
    else:
        for _ in range(2):
            sock.sendto(payload, (host, int(port)))
            data, peer = sock.recvfrom(65535)
            assert data == expected
            assert peer[:2] == (host, int(port))
except (OSError, AssertionError) as error:
    print('%s %s:%s from %s: %r' % (proto, host, port, src, error), file=sys.stderr)
    sys.exit(1)
PY
cat > "$WORK/udp_sessions.py" <<'PY'
import concurrent.futures, os, socket, threading
barrier = threading.Barrier(4)
rounds = int(os.environ.get('NFT_KERNEL_UDP_ROUNDS', '16'))
assert 1 <= rounds <= 1000
def client(src):
    v6 = ':' in src
    host = '2001:db8:201::1' if v6 else '10.201.1.1'
    target = '10.201.2.2' if v6 else '2001:db8:202::2'
    ports = (31000, 31010, 31012) if v6 else (32000, 32100, 32012)
    for seq in range(rounds):
        with socket.socket(socket.AF_INET6 if v6 else socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(3)
            sock.bind((src, 39001 + seq))
            barrier.wait(timeout=5)
            pending = {}
            for port in ports:
                payload = ('%s/%d/%d' % (src, port, seq)).encode()
                backend_port = 20002 if port in (31012, 32012) else 20000
                pending[('%s:%d:' % (target, backend_port)).encode() + payload] = port
                sock.sendto(payload, (host, port))
            while pending:
                try:
                    data, peer = sock.recvfrom(65535)
                except socket.timeout as error:
                    raise AssertionError('%s: missing UDP replies from ingress ports %s' % (src, list(pending.values()))) from error
                assert peer[:2] == (host, pending.pop(data)), (src, data, peer)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(client, ('10.201.1.2', '10.201.1.4', '2001:db8:201::2', '2001:db8:201::4')))
PY
for addr in 10.201.2.2 2001:db8:202::2; do
    ip netns exec "$TGT" python3 "$WORK/echo.py" "$addr" & PIDS+=("$!")
done

# Phase-0 reference setup, intentionally independent of the product generator.
probe_setup() {
    local ns link n host4 peer4 host6 peer6 pool6 pool4 proto
    for n in 64 46; do
        if [ "$n" = 64 ]; then
            ns="$N64"; link=x64; host4=198.18.241.1; peer4=198.18.241.2
            host6=fd73:6866:7400:1::1; peer6=fd73:6866:7400:1::2
            pool6=fd73:6866:7400:64::/96; pool4=198.18.241.64
        else
            ns="$N46"; link=x46; host4=198.18.241.5; peer4=198.18.241.6
            host6=fd73:6866:7400:2::1; peer6=fd73:6866:7400:2::2
            pool6=fd73:6866:7400:46::/96; pool4=198.18.241.128
        fi
        ip netns add "$ns"
        ip link add "$link" type veth peer name peer
        ip link set peer netns "$ns"
        ip addr add "$host4/30" dev "$link"
        ip -6 addr add "$host6/64" dev "$link" nodad
        ip link set "$link" up
        ip -n "$ns" addr add "$peer4/30" dev peer
        ip -n "$ns" -6 addr add "$peer6/64" dev peer nodad
        ip -n "$ns" link set peer up; ip -n "$ns" link set lo up
        ip -n "$ns" route add default via "$host4"
        ip -n "$ns" -6 route add default via "$host6"
        ip route add "$pool4/32" via "$peer4" dev "$link"
        ip -6 route add "$pool6" via "$peer6" dev "$link"
        ip netns exec "$ns" sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
        ip netns exec "$ns" nft -f - <<'NFT'
table inet untranslated_guard {
 chain forward { type filter hook forward priority filter; policy drop; }
}
NFT
        ip netns exec "$ns" jool instance add nft-sh --netfilter --pool6 "$pool6"
        for proto in tcp udp; do
            ip netns exec "$ns" jool -i nft-sh pool4 add "--$proto" "$pool4" 1024-65535 --force
            if [ "$n" = 46 ]; then
                ip netns exec "$ns" jool -i nft-sh bib add "--$proto" "$pool4#32000" 'fd73:6866:7400:a46::7d00#20000'
            fi
        done
    done
    nft -f - <<'NFT'
table inet unified {
 chain pre { type nat hook prerouting priority dstnat; policy accept;
  iifname "x46" ip6 daddr fd73:6866:7400:a46::7d00 tcp dport 20000 dnat ip6 to [2001:db8:202::2]:20000
  iifname "x46" ip6 daddr fd73:6866:7400:a46::7d00 udp dport 20000 dnat ip6 to [2001:db8:202::2]:20000
  meta nfproto ipv6 fib daddr type local tcp dport 30000 dnat ip6 to [2001:db8:202::2]:20000
  meta nfproto ipv6 fib daddr type local udp dport 30000 dnat ip6 to [2001:db8:202::2]:20000
  meta nfproto ipv6 fib daddr type local tcp dport 31000 dnat ip6 to [fd73:6866:7400:64::ac9:202]:20000
  meta nfproto ipv6 fib daddr type local udp dport 31000 dnat ip6 to [fd73:6866:7400:64::ac9:202]:20000
  meta nfproto ipv4 fib daddr type local tcp dport 32000 dnat ip to 198.18.241.128
  meta nfproto ipv4 fib daddr type local udp dport 32000 dnat ip to 198.18.241.128
  meta nfproto ipv4 fib daddr type local tcp dport 33000 dnat ip to 10.201.2.2:20000
  meta nfproto ipv4 fib daddr type local udp dport 33000 dnat ip to 10.201.2.2:20000
 }
 chain post { type nat hook postrouting priority srcnat; policy accept;
  ct status dnat ip6 daddr 2001:db8:202::2 masquerade
  ct status dnat ip daddr 10.201.2.2 masquerade
  iifname "x64" ip saddr 198.18.241.64 ip daddr 10.201.2.2 masquerade
 }
 chain forward { type filter hook forward priority filter; policy accept;
  ct state established,related accept
  ct status dnat ip saddr 10.201.1.2 accept
  ct status dnat ip6 saddr 2001:db8:201::2 accept
  iifname "x46" ip6 saddr fd73:6866:7400:46::/96 ip6 daddr 2001:db8:202::2 accept
  ct status dnat drop
 }
}
NFT
}

if [ "${2:-}" = --probe ]; then
    probe_setup
else
    export NFT_SH_WHITELIST_FILE="$WORK/whitelist"
    export NFT_SH_FORWARD_FILE="$WORK/forward"
    export NFT_SH_ENABLED_FILE="$WORK/enabled"
    export NFT_SH_PERSIST_DIR="$WORK/nftables.d"
    export NFT_SH_MAIN_CONF="$WORK/nftables.conf"
    export NFT_SH_SYSCTL_FILE="$WORK/forward.sysctl"
    export NFT_SH_TRANSLATE_DIR="$WORK/translate"
    export NFT_SH_LIBEXEC_DIR="$WORK/libexec"
    export NFT_SH_SYSTEMD_DIR="$WORK/systemd"
    export NFT_SH_FORCE=1
    export SSH_CONNECTION='10.201.1.2 50000 10.201.1.1 22'
    printf '10.201.1.2\n10.201.1.4\n2001:db8:201::2\n2001:db8:201::4\n' > "$NFT_SH_WHITELIST_FILE"
    cat > "$NFT_SH_FORWARD_FILE" <<'CONF'
ipv6|30000|2001:db8:202::2|20000
ipv6|31000|10.201.2.2|20000
ipv4|32000|2001:db8:202::2|20000
33000|10.201.2.2|20000
ipv6|30010-30012|2001:db8:202::2|20000-20002
ipv6|31010-31012|10.201.2.2|20000-20002
ipv4|32010-32012|2001:db8:202::2|20000-20002
ipv4|32100|2001:db8:202::2|20000
ipv6|34000-34002|2001:db8:202::2|20000-20002
34000-34002|10.201.2.2|20000-20002
CONF
    if [ "${2:-}" = --same-ports ]; then
        cat >> "$NFT_SH_FORWARD_FILE" <<'CONF'
ipv6|35000-35002|10.201.2.2|35000-35002
ipv4|35010-35012|2001:db8:202::2|35010-35012
ipv6|36000-36002|2001:db8:202::2|36000-36002
36000-36002|10.201.2.2|36000-36002
CONF
    fi
    printf '1\n' > "$NFT_SH_ENABLED_FILE"
    bash "$ROOT/nft.sh" apply
fi
sleep 1
expect() {
    local title="$1" want="$2"; shift 2
    local rc=0
    ip netns exec "$CLI" python3 "$WORK/query.py" "$@" || rc=$?
    if { [ "$want" = allow ] && [ "$rc" -eq 0 ]; } || { [ "$want" = deny ] && [ "$rc" -ne 0 ]; }; then
        echo "PASS: $title"; PASS=$((PASS + 1))
    else
        echo "FAIL: $title"; FAIL=$((FAIL + 1))
    fi
}
for proto in tcp udp; do
    expect "$proto IPv6 -> IPv6" allow "$proto" 2001:db8:201::1 30000 2001:db8:201::2 2001:db8:202::2 20000 99
    expect "$proto IPv6 -> IPv4" allow "$proto" 2001:db8:201::1 31000 2001:db8:201::2 10.201.2.2 20000 99
    expect "$proto IPv4 -> IPv6" allow "$proto" 10.201.1.1 32000 10.201.1.2 2001:db8:202::2 20000 99
    expect "$proto IPv4 -> IPv4 regression" allow "$proto" 10.201.1.1 33000 10.201.1.2 10.201.2.2 20000 99
    expect "$proto blocked IPv6 -> IPv4" deny "$proto" 2001:db8:201::1 31000 2001:db8:201::3 10.201.2.2 20000 99
    expect "$proto blocked IPv4 -> IPv6" deny "$proto" 10.201.1.1 32000 10.201.1.3 2001:db8:202::2 20000 99
done
if [ "${2:-}" != --probe ]; then
    if [ -z "$(ip netns pids nftsh64)$(ip netns pids nftsh46)" ] && [ -z "$(ss -Hlnut)" ]; then
        echo 'PASS: no userspace translator process or business listener'; PASS=$((PASS + 1))
    else echo 'FAIL: unexpected translator process/listener'; FAIL=$((FAIL + 1)); fi
    if ip netns exec "$CLI" python3 "$WORK/udp_sessions.py"; then
        echo 'PASS: concurrent UDP clients share source port across independent entries'; PASS=$((PASS + 1))
    else
        echo 'FAIL: concurrent UDP sessions mixed'; FAIL=$((FAIL + 1))
        cat /proc/net/stat/nf_conntrack 2>/dev/null || true
        for mode in 64 46; do ip netns exec "nftsh$mode" jool -i nft-sh stats display --csv || true; done
    fi
    if [ "${2:-}" = --concurrency ]; then
        printf 'Concurrency probe: %s passed, %s failed\n' "$PASS" "$FAIL"
        [ "$FAIL" -eq 0 ]; exit $?
    fi
    if [ "${2:-}" = --same-ports ]; then
        for proto in tcp udp; do
            for offset in 0 1 2; do
                expect "$proto same-number IPv6 -> IPv4 $offset" allow "$proto" 2001:db8:201::1 "$((35000 + offset))" 2001:db8:201::2 10.201.2.2 "$((35000 + offset))" 99
                expect "$proto same-number IPv4 -> IPv6 $offset" allow "$proto" 10.201.1.1 "$((35010 + offset))" 10.201.1.2 2001:db8:202::2 "$((35010 + offset))" 99
                expect "$proto same-number IPv6 -> IPv6 $offset" allow "$proto" 2001:db8:201::1 "$((36000 + offset))" 2001:db8:201::2 2001:db8:202::2 "$((36000 + offset))" 99
                expect "$proto same-number IPv4 -> IPv4 $offset" allow "$proto" 10.201.1.1 "$((36000 + offset))" 10.201.1.2 10.201.2.2 "$((36000 + offset))" 99
            done
        done
        printf 'Same-number ranges: %s passed, %s failed\n' "$PASS" "$FAIL"
        [ "$FAIL" -eq 0 ]; exit $?
    fi
    for proto in tcp udp; do
        for offset in 0 1 2; do
            expect "$proto IPv6 range v6 backend $offset" allow "$proto" 2001:db8:201::1 "$((30010 + offset))" 2001:db8:201::2 2001:db8:202::2 "$((20000 + offset))" 99
            expect "$proto IPv6 range v4 backend $offset" allow "$proto" 2001:db8:201::1 "$((31010 + offset))" 2001:db8:201::2 10.201.2.2 "$((20000 + offset))" 99
            expect "$proto IPv4 range v6 backend $offset" allow "$proto" 10.201.1.1 "$((32010 + offset))" 10.201.1.2 2001:db8:202::2 "$((20000 + offset))" 99
            expect "$proto same port IPv6 $offset" allow "$proto" 2001:db8:201::1 "$((34000 + offset))" 2001:db8:201::2 2001:db8:202::2 "$((20000 + offset))" 99
            expect "$proto same port IPv4 $offset" allow "$proto" 10.201.1.1 "$((34000 + offset))" 10.201.1.2 10.201.2.2 "$((20000 + offset))" 99
        done
        expect "$proto duplicate real IPv6 endpoint" allow "$proto" 10.201.1.1 32100 10.201.1.2 2001:db8:202::2 20000 99
        expect "$proto direct synthetic IPv6 denied" deny "$proto" fd73:6866:7400:64::ac9:202 20000 2001:db8:201::2 10.201.2.2 20000 99
        expect "$proto direct pool4 denied" deny "$proto" 198.18.241.128 32000 10.201.1.2 2001:db8:202::2 20000 99
    done
    # Local-origin DNAT must retain its own conntrack reply path too.
    trace_pid=""
    if [ "${NFT_KERNEL_DEBUG_LOCAL:-0}" = 1 ]; then
        nft -f - <<'NFT'
table inet kernel_trace {
 chain pre { type filter hook prerouting priority -301; policy accept; meta l4proto { tcp, udp } meta nftrace set 1; }
 chain out { type filter hook output priority -301; policy accept; meta l4proto { tcp, udp } meta nftrace set 1; }
}
NFT
        nft monitor trace > "$WORK/local.trace" & trace_pid=$!; PIDS+=("$trace_pid")
        sleep 0.1
    fi
    for entry in 'tcp 2001:db8:201::1 31000 2001:db8:201::1 10.201.2.2 20000 99' \
        'udp 10.201.1.1 32000 10.201.1.1 2001:db8:202::2 20000 99'; do
        read -r -a args <<< "$entry"
        if python3 "$WORK/query.py" "${args[@]}"; then PASS=$((PASS + 1)); echo 'PASS: local-origin cross-family'; else FAIL=$((FAIL + 1)); echo 'FAIL: local-origin cross-family'; fi
    done
    if [ -n "$trace_pid" ]; then
        kill "$trace_pid"; wait "$trace_pid" 2>/dev/null || true
        cat "$WORK/local.trace"
        nft list chain inet unified postrouting
        nft delete table inet kernel_trace
    fi
    bash "$ROOT/nft.sh" whitelist off >/dev/null
    expect 'whitelist off allows IPv6 client' allow udp 2001:db8:201::1 31000 2001:db8:201::3 10.201.2.2 20000 99
    expect 'whitelist off still denies direct synthetic address' deny udp fd73:6866:7400:64::ac9:202 20000 2001:db8:201::3 10.201.2.2 20000 99
    bash "$ROOT/nft.sh" whitelist on >/dev/null
    ip netns exec nftsh64 jool -i nft-sh global update manually-enabled false
    expect 'paused Jool cannot route untranslated packets' deny udp 2001:db8:201::1 31000 2001:db8:201::2 10.201.2.2 20000 99
    bash "$ROOT/nft.sh" apply >/dev/null
    expect 'apply repairs paused instance' allow udp 2001:db8:201::1 31000 2001:db8:201::2 10.201.2.2 20000 99
    ip netns exec nftsh46 jool -i nft-sh bib remove --udp '198.18.241.128#32000'
    expect 'missing static BIB fails closed' deny udp 10.201.1.1 32000 10.201.1.2 2001:db8:202::2 20000 99
    bash "$ROOT/nft.sh" apply >/dev/null
    expect 'apply repairs deleted static BIB' allow udp 10.201.1.1 32000 10.201.1.2 2001:db8:202::2 20000 99
    ip netns exec nftsh64 jool -i nft-sh pool4 remove --udp 198.18.241.64 1-65535
    ip netns exec nftsh64 jool -i nft-sh pool4 add --udp 198.18.241.64 40000-40000 --force
    expect 'one-port pool admits first client' allow udp 2001:db8:201::1 31000 2001:db8:201::2 10.201.2.2 20000 99
    expect 'exhausted pool refuses a second client' deny udp 2001:db8:201::1 31000 2001:db8:201::4 10.201.2.2 20000 99
    expect 'pool exhaustion leaves native IPv6 available' allow tcp 2001:db8:201::1 30000 2001:db8:201::2 2001:db8:202::2 20000 99
    bash "$ROOT/nft.sh" apply >/dev/null
    expect 'apply restores modified pool and second client' allow udp 2001:db8:201::1 31000 2001:db8:201::4 10.201.2.2 20000 99
    ip -6 route del fd73:6866:7400:64::/96
    expect 'missing translation route fails closed' deny udp 2001:db8:201::1 31000 2001:db8:201::2 10.201.2.2 20000 99
    bash "$ROOT/nft.sh" apply >/dev/null
    expect 'apply repairs missing translation route' allow udp 2001:db8:201::1 31000 2001:db8:201::2 10.201.2.2 20000 99
    # Fail once during the second instance, after the first was already rebuilt.
    # The unmodified backend must then be rebuilt from the running declaration.
    mkdir "$WORK/failbin"
    REAL_JOOL=$(command -v jool)
    export REAL_JOOL NFT_KERNEL_FAIL_ONCE="$WORK/fail-once"
    cat > "$WORK/failbin/jool" <<'SH'
#!/bin/bash
if [ "$1 ${2:-}" = 'file handle' ] && [ -e "$NFT_KERNEL_FAIL_ONCE" ] && grep -qF ':46::/96' "$3"; then
    rm -f "$NFT_KERNEL_FAIL_ONCE"
    echo 'Injected one-time second-instance failure' >&2
    exit 42
fi
exec "$REAL_JOOL" "$@"
SH
    chmod +x "$WORK/failbin/jool"
    touch "$NFT_KERNEL_FAIL_ONCE"
    cp "$NFT_SH_FORWARD_FILE" "$WORK/forward.before-failure"
    if PATH="$WORK/failbin:$PATH" bash "$ROOT/nft.sh" add-forward --listen-family ipv4 32500 2001:db8:202::2 20002 > "$WORK/failure.log" 2>&1; then
        echo 'FAIL: injected backend failure should abort'; FAIL=$((FAIL + 1))
    else echo 'PASS: injected backend failure aborts'; PASS=$((PASS + 1)); fi
    if cmp -s "$NFT_SH_FORWARD_FILE" "$WORK/forward.before-failure"; then
        echo 'PASS: failed mutation restores declarations'; PASS=$((PASS + 1))
    else echo 'FAIL: failed mutation did not restore declarations'; FAIL=$((FAIL + 1)); cat "$WORK/failure.log"; fi
    expect 'rollback restores NAT64 path after partial setup' allow tcp 2001:db8:201::1 31000 2001:db8:201::2 10.201.2.2 20000 99
    expect 'rollback restores static BIB after partial setup' allow udp 10.201.1.1 32000 10.201.1.2 2001:db8:202::2 20000 99

    cat > "$WORK/rollback-driver.sh" <<'SH'
#!/bin/bash
source "$1"
INTERACTIVE=1; CLI_MODE=1; ROLLBACK_TIMEOUT="${NFT_KERNEL_ROLLBACK_TIMEOUT:-3}"
begin_action || exit 1
trap end_action EXIT
printf '%s\n' "$SNAPSHOT_DIR" > "$2/driver.snapshot"
fwd_validate 32700 10.201.2.2 20002 ipv6 && fwd_append || exit 1
CONFIRM_ALWAYS=1
apply_all_rules
SH
    mkfifo "$WORK/confirm.fifo"
    exec {confirm_fd}<>"$WORK/confirm.fifo"
    bash "$WORK/rollback-driver.sh" "$ROOT/nft.sh" "$WORK" < "$WORK/confirm.fifo" > "$WORK/rollback.log" 2>&1 &
    driver=$!; PIDS+=("$driver")
    ready=0
    for ((i = 0; i < 1200; i++)); do
        if grep -q '确认正常请在' "$WORK/rollback.log"; then ready=1; break; fi
        kill -0 "$driver" 2>/dev/null || break
        sleep 0.05
    done
    if [ "$ready" = 1 ]; then
        snap=$(cat "$WORK/driver.snapshot")
        kill -TERM "$driver"; wait "$driver" 2>/dev/null || true
        # Bash may finish the rollback synchronously when TERM interrupts read.
        # Admission is valid only after that older transaction has completed.
        cat > "$WORK/transaction-probe.sh" <<'SH'
#!/bin/bash
source "$1"
trap end_action EXIT
if begin_action; then
    [ ! -d "$2" ] || [ -e "$2/completed" ] || exit 9
    exit 0
fi
if [ -d "$2" ] && [ ! -e "$2/completed" ]; then exit 10; fi
exit 11
SH
        gate_rc=0
        bash "$WORK/transaction-probe.sh" "$ROOT/nft.sh" "$snap" > "$WORK/concurrent-rollback.log" 2>&1 || gate_rc=$?
        if [ "$gate_rc" = 10 ]; then
            echo 'PASS: pending rollback blocks newer transaction after disconnect'; PASS=$((PASS + 1))
        elif [ "$gate_rc" = 0 ]; then
            echo 'PASS: completed rollback permits a new transaction'; PASS=$((PASS + 1))
        else echo 'FAIL: transaction admitted before rollback completion'; FAIL=$((FAIL + 1)); cat "$WORK/concurrent-rollback.log"; fi
        for ((i = 0; i < (NFT_KERNEL_ROLLBACK_TIMEOUT + 45) * 10; i++)); do [ -d "$snap" ] || break; sleep 0.1; done
        if [ ! -d "$snap" ] && ! grep -qF '32700' "$NFT_SH_FORWARD_FILE"; then
            echo 'PASS: disconnected control process rolls back kernel resources'; PASS=$((PASS + 1))
        else echo 'FAIL: disconnected control process rollback'; FAIL=$((FAIL + 1)); cat "$WORK/rollback.log"; fi
    else echo 'FAIL: kernel mutation did not reach confirmation'; FAIL=$((FAIL + 1)); cat "$WORK/rollback.log"; fi
    exec {confirm_fd}>&-
    expect 'NAT64 works after disconnected rollback' allow udp 2001:db8:201::1 31000 2001:db8:201::2 10.201.2.2 20000 99
    expect 'static BIB works after disconnected rollback' allow tcp 10.201.1.1 32000 10.201.1.2 2001:db8:202::2 20000 99
fi
for size in 8192 60000; do
    expect "UDP v6 -> v4 $size bytes" allow udp 2001:db8:201::1 31000 2001:db8:201::2 10.201.2.2 20000 "$size"
    expect "UDP v4 -> v6 $size bytes" allow udp 10.201.1.1 32000 10.201.1.2 2001:db8:202::2 20000 "$size"
done
ip link set kc mtu 1280; ip link set kt mtu 1280
ip -n "$CLI" link set cli mtu 1280; ip -n "$TGT" link set tgt mtu 1280
for proto in tcp udp; do
    expect "$proto IPv6 -> IPv4 at MTU 1280" allow "$proto" 2001:db8:201::1 31000 2001:db8:201::2 10.201.2.2 20000 8192
    expect "$proto IPv4 -> IPv6 at MTU 1280" allow "$proto" 10.201.1.1 32000 10.201.1.2 2001:db8:202::2 20000 8192
done
if [ "${2:-}" != --probe ]; then
    if bash "$ROOT/nft.sh" del-forward 34000-34002 > "$WORK/ambiguous.log" 2>&1; then
        echo 'FAIL: ambiguous dual-family removal'; FAIL=$((FAIL + 1))
    else echo 'PASS: ambiguous removal requires family'; PASS=$((PASS + 1)); fi
    for port in 31000 31010-31012; do bash "$ROOT/nft.sh" del-forward --listen-family ipv6 "$port" >/dev/null; done
    for port in 32000 32010-32012 32100; do bash "$ROOT/nft.sh" del-forward --listen-family ipv4 "$port" >/dev/null; done
    if ! ip link show nftsh64 >/dev/null 2>&1 && ! ip link show nftsh46 >/dev/null 2>&1 &&
        ! nft list table inet nft_sh_transition >/dev/null 2>&1; then
        echo 'PASS: deleting last cross-family entry removes translator resources'; PASS=$((PASS + 1))
    else echo 'FAIL: translator resources remain'; FAIL=$((FAIL + 1)); fi
    expect 'native IPv6 survives translator removal' allow tcp 2001:db8:201::1 30000 2001:db8:201::2 2001:db8:202::2 20000 99
    expect 'native IPv4 survives translator removal' allow udp 10.201.1.1 33000 10.201.1.2 10.201.2.2 20000 99
fi
printf 'Kernel forwarding: %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then nft list ruleset; fi
[ "$FAIL" -eq 0 ]
