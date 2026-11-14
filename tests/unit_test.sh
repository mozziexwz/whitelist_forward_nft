#!/bin/bash
# 纯 bash 单元测试：不需要 root，也不需要 nftables（Windows 的 Git Bash 也能运行）
#   bash tests/unit_test.sh
# 测试里用到的函数和变量来自下面 source 的 nft.sh:
# shellcheck disable=SC2034,SC2154
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export NFT_SH_WHITELIST_FILE="$WORK/whitelist.txt"
export NFT_SH_FORWARD_FILE="$WORK/forward.conf"
export NFT_SH_ENABLED_FILE="$WORK/enabled"
export NFT_SH_TRANSLATE_DIR="$WORK/translate"
export NFT_SH_LIBEXEC_DIR="$WORK/libexec"
export NFT_SH_SYSTEMD_DIR="$WORK/systemd"
export NFT_SH_SYSCTL_FILE="$WORK/forward.sysctl"
unset SSH_CONNECTION SSH_CLIENT

# shellcheck source=../nft.sh
source "$ROOT/nft.sh"

# Windows Git Bash has no flock; concurrency is checked on real Linux separately.
if ! command -v flock >/dev/null 2>&1; then flock() { return 0; }; fi

# 不依赖本机实际监听的端口，测试结果在任何机器上都一样
FAKE_LISTEN=""
get_listening_ports() {
    [ -n "$FAKE_LISTEN" ] && printf '%s\n' "$FAKE_LISTEN"
    return 0
}

# 只看环境变量，不沿父进程查找：否则通过 SSH 运行测试时会读到真实的连接
# （父进程查找本身在下面单独测试）
get_ssh_connection() {
    if [ -n "${SSH_CONNECTION:-}" ]; then
        printf '%s' "$SSH_CONNECTION"
    elif [ -n "${SSH_CLIENT:-}" ]; then
        awk '{print $1, $2, "-", $3}' <<< "$SSH_CLIENT"
    fi
}

PASS=0
FAIL=0

eq() {   # eq 描述 期望 实际
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  期望: %s\n  实际: %s\n' "$1" "$2" "$3"
    fi
}

ok() {   # ok 描述 命令...（命令应成功）
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
    fi
}

no() {   # no 描述 命令...（命令应失败）
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc（应当失败）"
    else
        PASS=$((PASS + 1))
    fi
}

has() {  # has 描述 文本 子串
    if [[ "$2" == *"$3"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  未找到: %s\n' "$1" "$3"
    fi
}

lacks() {  # lacks 描述 文本 子串
    if [[ "$2" == *"$3"* ]]; then
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  不应出现: %s\n' "$1" "$3"
    else
        PASS=$((PASS + 1))
    fi
}

# ---------------------------------------------------------------- IP 校验
for ip in 1.2.3.4 0.0.0.0 255.255.255.255 10.0.0.1 192.168.100.200; do
    ok "合法 IPv4 $ip" is_valid_ipv4 "$ip"
done
for ip in 999.1.1.1 256.1.1.1 1.2.3 1.2.3.4.5 01.2.3.4 "1.2.3.4 " a.b.c.d "" ...; do
    no "非法 IPv4 '$ip'" is_valid_ipv4 "$ip"
done
for ip in :: ::1 2001:db8::1 fe80::1:2:3:4 1:2:3:4:5:6:7:8 1:2:3:4:5:6:7:: ::2:3:4:5:6:7:8 2001:DB8::A; do
    ok "合法 IPv6 $ip" is_valid_ipv6 "$ip"
done
for ip in 1:2:3:4:5:6:7:8:9 2001:db8::1::2 12345::1 :1::2 1::2: deadbeef 1.2.3.4 ::ffff:1.2.3.4 fe80::1%eth0 ::: 1:2:3:4:5:6:7:8::; do
    no "非法 IPv6 '$ip'" is_valid_ipv6 "$ip"
done

# ---------------------------------------------------------------- 规范化
eq "IPv4 单个"        "1.2.3.4"              "$(normalize_ip_entry 1.2.3.4)"
eq "IPv4 首尾空白"    "1.2.3.4"              "$(normalize_ip_entry $' 1.2.3.4 \r')"
eq "IPv4 /32"         "1.2.3.4"              "$(normalize_ip_entry 1.2.3.4/32)"
eq "IPv4 主机位清零"  "1.2.3.0/24"           "$(normalize_ip_entry 1.2.3.77/24)"
eq "IPv4 /0"          "0.0.0.0/0"            "$(normalize_ip_entry 8.8.8.8/0)"
eq "IPv4 /31"         "10.0.0.6/31"          "$(normalize_ip_entry 10.0.0.7/31)"
eq "IPv4 前缀前导零"  "10.0.0.0/8"           "$(normalize_ip_entry 10.1.2.3/08)"
eq "IPv6 压缩小写"    "2001:db8::1"          "$(normalize_ip_entry 2001:0DB8:0:0:0:0:0:0001)"
eq "IPv6 主机位清零"  "2001:db8::/32"        "$(normalize_ip_entry 2001:db8:1234::1/32)"
eq "IPv6 非整组前缀"  "2001:db8:0:ff00::/56" "$(normalize_ip_entry 2001:db8:0:ffab::1/56)"
eq "IPv6 /128"        "::1"                  "$(normalize_ip_entry ::1/128)"
eq "IPv6 全零"        "::/0"                 "$(normalize_ip_entry 2001:db8::/0)"
eq "IPv6 只压缩最长的 0 段" "1:0:0:2::3"    "$(normalize_ip_entry 1:0:0:2:0:0:0:3)"
eq "IPv6 单个 0 不压缩" "1:0:2:3:4:5:6:7"   "$(normalize_ip_entry 1:0:2:3:4:5:6:7)"
no "IPv4 前缀越界"    normalize_ip_entry 1.2.3.4/33
no "IPv6 前缀越界"    normalize_ip_entry ::1/129
no "域名"             normalize_ip_entry example.com
no "空前缀"           normalize_ip_entry 1.2.3.4/
no "多个斜杠"         normalize_ip_entry 1.2.3.4/24/5
no "空字符串"         normalize_ip_entry ""

# ---------------------------------------------------------------- 网段包含
ok "1.2.3.4 属于 1.2.3.0/24"          ip_in_cidr 1.2.3.4 1.2.3.0/24
no "1.2.4.4 不属于 1.2.3.0/24"        ip_in_cidr 1.2.4.4 1.2.3.0/24
ok "任意地址属于 0.0.0.0/0"           ip_in_cidr 9.9.9.9 0.0.0.0/0
ok "精确匹配"                         ip_in_cidr 1.2.3.4 1.2.3.4
no "精确不匹配"                       ip_in_cidr 1.2.3.5 1.2.3.4
ok "IPv6 前缀内"                      ip_in_cidr 2001:db8::5 2001:db8::/32
no "IPv6 前缀外"                      ip_in_cidr 2001:db9::5 2001:db8::/32
ok "IPv6 非整组前缀内"                ip_in_cidr 2001:db8:0:ff12::1 2001:db8:0:ff00::/56
no "IPv6 非整组前缀外"                ip_in_cidr 2001:db8:0:fe12::1 2001:db8:0:ff00::/56

# ---------------------------------------------------------------- 端口
eq "前导零端口"       "8080"        "$(normalize_port 08080)"
eq "端口 65535"       "65535"       "$(normalize_port 65535)"
no "端口 0"           normalize_port 0
no "端口 65536"       normalize_port 65536
no "端口非数字"       normalize_port 80a
eq "端口段"           "10000 10010" "$(parse_port_spec 10000-10010)"
eq "端口段前导零"     "8 20"        "$(parse_port_spec 008-020)"
eq "端口段带空格"     "1 2"         "$(parse_port_spec ' 1-2 ')"
no "起始大于结束"     parse_port_spec 20-10
no "起始等于结束"     parse_port_spec 20-20
no "端口段越界"       parse_port_spec 60000-70000
no "端口段缺结束"     parse_port_spec 100-

# ---------------------------------------------------------------- 转发配置行
eq "单端口行"         "8080 8080 1.2.3.4 80 80"           "$(parse_forward_line '8080|1.2.3.4|80')"
eq "CRLF 行"          "8080 8080 1.2.3.4 80 80"           "$(parse_forward_line $'8080|1.2.3.4|80\r')"
eq "端口段行"         "10000 10002 1.2.3.4 20000 20002"   "$(parse_forward_line '10000-10002|1.2.3.4|20000-20002')"
no "多余字段"         parse_forward_line '8080|1.2.3.4|x|80'
no "末尾多余分隔符"   parse_forward_line '8080|1.2.3.4|80|'
no "配置中的回环目标" parse_forward_line '8080|127.0.0.1|80'
no "配置中的组播目标" parse_forward_line '8080|239.1.1.1|80'
no "端口数量不一致"   parse_forward_line '1-3|1.2.3.4|1-5'
no "域名目标"         parse_forward_line '8080|example.com|80'
no "注释行"           parse_forward_line '# 8080|1.2.3.4|80'
no "空行"             parse_forward_line '   '

eq "IPv6 入口及目标规范化" "8080 8080 2001:db8::10 80 80 ipv6" "$(parse_forward_line 'ipv6|08080|2001:0DB8::10|0080')"
eq "IPv6 入站到 IPv4" "8080 8080 192.0.2.10 80 80 ipv6" "$(parse_forward_line 'ipv6|8080|192.0.2.10|80')"
eq "IPv4 入站到 IPv6" "8080 8080 fd12::10 80 80 ipv4" "$(parse_forward_line 'ipv4|8080|fd12::10|80')"
no "旧格式不推测 IPv6 入口" parse_forward_line '8080|2001:db8::10|80'
no "无效地址族" parse_forward_line 'both|8080|192.0.2.10|80'
for target in :: ::1 fe80::1 ff02::1 ::ffff:192.0.2.10 'fd12::10%eth0' '2001:db8::/64' '[2001:db8::10]'; do
    no "拒绝不支持的 IPv6 目标 $target" validate_target_ip "$target"
done
printf '8080|192.0.2.10|80\nipv6|8080|2001:db8::10|80\n' > "$NFT_SH_FORWARD_FILE"
no "双族同端口删除需要地址族" fwd_index_by_local 8080
eq "明确 IPv6 删除选择正确条目" "2" "$(fwd_index_by_local 8080 ipv6)"
ok "允许双族相同入口端口" precheck_forwards
ok "IPv6 同族重叠能识别" forward_conflict 8080 8080 ipv6
no "IPv4 不与单独 IPv6 规则冲突" forward_conflict 9090 9090 ipv4
printf 'ipv6|10000-10002|2001:db8::10|20000-20002\n' > "$NFT_SH_FORWARD_FILE"
rules=$(build_ruleset)
has "原生 IPv6 DNAT 使用地址族" "$rules" 'dnat ip6 to [2001:db8::10]'
has "IPv6 异号端口段顺序映射" "$rules" '10002 : 20002'
has "IPv6 本机流量排除回环" "$rules" 'ip6 daddr != ::1 fib daddr type local'
has "IPv6 SNAT 只限定 DNAT" "$rules" 'ct status dnat ip6 daddr 2001:db8::10'
translation_settings
eq "NAT64 合成目的地址" "fd73:6866:7400:64::c000:20a" "$(translation_synth6 192.0.2.10)"
printf 'ipv4|32000-32002|2001:db8::10|20000-20002\nipv4|32100|2001:db8::10|20000\n' > "$NFT_SH_FORWARD_FILE"
json=$(translation_json 46)
has "静态映射覆盖段末端" "$json" '198.18.241.128#32002'
has "相同真实目标使用不同虚拟端点" "$json" 'fd73:6866:7400:a46::7d64#20000'
rules=$(build_ruleset)
has "跨族先改为内部 IPv4 服务端点" "$rules" 'dnat ip to 198.18.241.128'
has "转换后再同族改为真实 IPv6 目标" "$rules" 'dnat ip6 to 2001:db8::10'
has "直接访问转换 veth 默认丢弃" "$rules" 'oifname "nftsh46" counter drop'
has "入口按原始 IPv4 来源过滤" "$rules" 'ip saddr @allowed_ips'
has "转换目标绑定到本项目原入口端口" "$rules" 'ct original proto-dst 32000-32002'

printf '8080|1.2.3.4|80\n\n# note\nbad line\n9090|1.2.3.5|90' > "$NFT_SH_FORWARD_FILE"
eq "末行无换行也能读到"   "2"          "$(list_forwards | wc -l | tr -d ' ')"
eq "无效行检测"           "bad line"   "$(invalid_forward_lines)"
eq "按本地端口找序号"     "2"          "$(fwd_index_by_local 9090)"
no "找不到的本地端口"     fwd_index_by_local 7070
ok "按序号删除转发"       fwd_remove_index 2
eq "只删除目标行，注释和无效行保留" "8080|1.2.3.4|80||# note|bad line|" "$(tr '\n' '|' < "$NFT_SH_FORWARD_FILE")"
no "序号超出范围"         fwd_remove_index 5
eq "删除失败时文件不变"   "1" "$(list_forwards | wc -l | tr -d ' ')"

# ---------------------------------------------------------------- 白名单读取
printf '# comment\n\n1.2.3.4\r\n 10.0.0.0/8 \nbad-entry\n2001:db8::1' > "$NFT_SH_WHITELIST_FILE"
eq "白名单规范化读取" "1.2.3.4 10.0.0.0/8 2001:db8::1" "$(load_whitelist_normalized 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
has "无效条目给出警告" "$(load_whitelist_normalized 2>&1 >/dev/null)" "bad-entry"
ok "网段内的 SSH IP 被放行"   whitelist_allows 10.20.30.40
ok "IPv6 SSH IP 被放行"      whitelist_allows 2001:db8::1
no "白名单外的 SSH IP"        whitelist_allows 11.0.0.1
no "IPv4 不会匹配 IPv6 条目"  whitelist_allows 32.1.13.184

# ---------------------------------------------------------------- 白名单增删
: > "$NFT_SH_WHITELIST_FILE"
ok "添加 CIDR"            wl_add 1.2.3.77/24
eq "保存规范化结果"       "1.2.3.0/24" "$(cat "$NFT_SH_WHITELIST_FILE")"
no "重复添加（等价写法）" wl_add 1.2.3.0/24
no "添加无效 IP"          wl_add 999.1.1.1
no "添加域名"             wl_add example.com
ok "添加 10.0.0.1"        wl_add 10.0.0.1
ok "添加 10.0.0.10"       wl_add 10.0.0.10
ok "删除 10.0.0.1"        wl_remove 10.0.0.1
eq "不会误删相似条目"     "1.2.3.0/24 10.0.0.10" "$(load_whitelist | tr '\n' ' ' | sed 's/ $//')"
ok "按等价写法删除"       wl_remove 1.2.3.99/24
no "删除不存在的条目"     wl_remove 8.8.8.8
printf '10.0.0.10\ngarbage' > "$NFT_SH_WHITELIST_FILE"
ok "可以删除无效条目"     wl_remove garbage
ok "末尾无换行时追加"     wl_add 5.6.7.8
eq "追加不会粘到上一行"   "10.0.0.10 5.6.7.8" "$(load_whitelist | tr '\n' ' ' | sed 's/ $//')"

# ---------------------------------------------------------------- SSH 检测
eq "SSH 来源 IP"          "203.0.113.9"  "$(SSH_CONNECTION='203.0.113.9 50000 10.0.0.1 22' get_current_ssh_ip)"
eq "IPv4 映射地址"        "203.0.113.9"  "$(SSH_CONNECTION='::ffff:203.0.113.9 50000 10.0.0.1 22' get_current_ssh_ip)"
eq "IPv6 去掉 zone"       "fe80::1"      "$(SSH_CONNECTION='fe80::1%eth0 50000 fe80::2 22' get_current_ssh_ip)"
eq "只有 SSH_CLIENT"      "203.0.113.9"  "$(SSH_CLIENT='203.0.113.9 50000 22' get_current_ssh_ip)"
has "SSH 服务端口"        "$(SSH_CONNECTION='203.0.113.9 50000 10.0.0.1 2222' get_ssh_ports)" "2222"
if [ "$(uname -s)" = "Linux" ] && [ -r "/proc/$$/environ" ]; then
    # 模拟 sudo：父进程有 SSH_CONNECTION，脚本自己的环境里没有（依赖 Linux 的 /proc）。
    # 中间那层 bash 要用命令替换去调用，否则 bash 会直接 exec 最后一条命令，这层父进程就不存在了
    got=$(env SSH_CONNECTION="198.51.100.20 40000 10.0.0.1 22" bash -c \
        'out=$(env -u SSH_CONNECTION -u SSH_CLIENT bash -c "source \"\$1\"; get_ssh_connection" _ "$1"); printf "%s" "$out"' \
        _ "$ROOT/nft.sh")
    eq "sudo 后沿父进程找到 SSH 连接" "198.51.100.20 40000 10.0.0.1 22" "$got"
fi

# ---------------------------------------------------------------- 转发校验
printf '10000-10002|192.0.2.10|20000-20002\n' > "$NFT_SH_FORWARD_FILE"
no "与已有端口段重叠"     fwd_validate 10001 192.0.2.10 80
no "端口数量不一致"       fwd_validate 40000-40002 192.0.2.10 50000-50005
no "目标是回环地址"       fwd_validate 40000 127.0.0.1 80
no "目标是组播地址"       fwd_validate 40000 239.1.1.1 80
no "目标是域名"           fwd_validate 40000 example.com 80
no "端口越界"             fwd_validate 60000-70000 192.0.2.10 60000-70000
export SSH_CONNECTION='203.0.113.9 50000 10.0.0.1 2222'
no "拒绝转发 SSH 端口"    fwd_validate 2222 192.0.2.10 22
no "拒绝包含 SSH 端口的段" fwd_validate 2000-3000 192.0.2.10 2000-3000
unset SSH_CONNECTION
ok "合法单端口"           fwd_validate 8080 192.0.2.10 80
eq "校验结果"             "8080 8080 192.0.2.10 80 80" "$FWD_LS $FWD_LE $FWD_TIP $FWD_TS $FWD_TE"
ok "前导零端口段"         fwd_validate 030000-030001 192.0.2.11 30000-30001
eq "前导零端口段结果"     "30000 30001 30000 30001" "$FWD_LS $FWD_LE $FWD_TS $FWD_TE"

# ---------------------------------------------------------------- 生成规则（白名单启用）
echo 1 > "$NFT_SH_ENABLED_FILE"
printf '203.0.113.5\n198.51.100.7/24\n2001:db8::/32\n' > "$NFT_SH_WHITELIST_FILE"
printf '8080|192.0.2.10|80\n10000-10002|192.0.2.10|20000-20002\n30000-30001|192.0.2.11|30000-30001\n70000|1.2.3.4|80\n' > "$NFT_SH_FORWARD_FILE"
rules=$(build_ruleset 2>"$WORK/err")
errs=$(cat "$WORK/err")

has "幂等加载: add table"     "$rules" "add table inet unified"
has "幂等加载: delete table"  "$rules" "delete table inet unified"
has "IPv4 白名单元素"         "$rules" "elements = { 203.0.113.5, 198.51.100.0/24 }"
has "IPv6 白名单元素"         "$rules" "elements = { 2001:db8::/32 }"
has "端口映射表"              "$rules" "map fwd_ports_2 {"
has "映射 10000"              "$rules" "10000 : 20000,"
has "映射 10001"              "$rules" "10001 : 20001,"
has "映射最后一项无逗号"      "$rules" $'10002 : 20002\n'
has "单端口 DNAT"             "$rules" 'fib daddr type local tcp dport 8080 counter dnat ip to 192.0.2.10:80 comment "nft.sh 8080"'
has "UDP 单端口 DNAT"         "$rules" 'fib daddr type local udp dport 8080 counter dnat ip to 192.0.2.10:80 comment "nft.sh 8080"'
has "prerouting 只处理 IPv4"  "$rules" 'meta nfproto ipv4 fib daddr type local tcp dport 8080'
has "本机访问不劫持出站"      "$rules" 'ip daddr != 127.0.0.0/8 fib daddr type local tcp dport 8080 counter dnat ip to 192.0.2.10:80'
has "端口段走映射表"          "$rules" 'fib daddr type local udp dport 10000-10002 counter dnat ip to 192.0.2.10 : udp dport map @fwd_ports_2'
has "同号端口段保持原端口"    "$rules" 'fib daddr type local tcp dport 30000-30001 counter dnat ip to 192.0.2.11 comment'
has "masquerade 限定 DNAT"    "$rules" 'ct status dnat ip daddr 192.0.2.10 tcp dport 20000-20002 counter masquerade'
has "input 默认拒绝"          "$rules" "type filter hook input priority filter; policy drop;"
has "ICMPv6 匹配扩展头"       "$rules" "meta l4proto icmpv6 accept"
has "forward 默认放行"        "$rules" "type filter hook forward priority filter; policy accept;"
has "只拦截 DNAT 新连接"      "$rules" "ct status dnat drop"
lacks "不再生成 dnat to（inet 表必须写 dnat ip to）" "$rules" "dnat to "
lacks "同号端口段不生成映射表" "$rules" "map fwd_ports_3"
lacks "不删除 inet filter"    "$rules" "inet filter"
has "无效转发行给出警告"      "$errs" "70000|1.2.3.4|80"
eq "规则数量: 3 条转发 × 2 协议 × 3 个链" "18" "$(grep -c 'comment "nft.sh' <<< "$rules")"
eq "花括号配对" "$(tr -cd '{' <<< "$rules" | wc -c)" "$(tr -cd '}' <<< "$rules" | wc -c)"

# ---------------------------------------------------------------- 生成规则（白名单关闭）
echo 0 > "$NFT_SH_ENABLED_FILE"
rules=$(build_ruleset 2>/dev/null)
has "关闭时 input 放行"       "$rules" "type filter hook input priority filter; policy accept;"
lacks "关闭时不拦截转发"      "$rules" "ct status dnat drop"
has "关闭时仍保留转发"        "$rules" "dnat ip to 192.0.2.10:80"

# ---------------------------------------------------------------- 空配置
: > "$NFT_SH_WHITELIST_FILE"
: > "$NFT_SH_FORWARD_FILE"
rules=$(build_ruleset 2>/dev/null)
lacks "空白名单不生成 elements" "$rules" "elements"
lacks "无转发不生成 DNAT"       "$rules" "dnat"

mkdir "$WORK/preview"
ok "print-rules 不需要 root 或 nft" env \
    NFT_SH_WHITELIST_FILE="$WORK/preview/whitelist" \
    NFT_SH_FORWARD_FILE="$WORK/preview/forward" \
    NFT_SH_ENABLED_FILE="$WORK/preview/enabled" \
    bash "$ROOT/nft.sh" print-rules
eq "规则预览不创建配置文件" "0" "$(find "$WORK/preview" -type f | wc -l | tr -d ' ')"
rm -f "$NFT_SH_ENABLED_FILE"
ok "未初始化时白名单默认启用" is_whitelist_enabled

# ---------------------------------------------------------------- 快照与确认判断
echo 1 > "$NFT_SH_ENABLED_FILE"
printf '1.2.3.4\n5.6.7.8\n' > "$NFT_SH_WHITELIST_FILE"
begin_action
ok "快照目录已创建"           test -d "$SNAPSHOT_DIR"
snap="$SNAPSHOT_DIR"
wl_remove 5.6.7.8 >/dev/null
ok "检测到白名单被删减"       whitelist_shrank
INTERACTIVE=1
: > "$SNAPSHOT_DIR/had_table"
ok "删减白名单需要确认"       needs_confirmation
restore_config_files "$SNAPSHOT_DIR"
eq "配置可以从快照恢复"       "1.2.3.4 5.6.7.8" "$(load_whitelist | tr '\n' ' ' | sed 's/ $//')"
wl_add 9.9.9.9 >/dev/null
no "只新增白名单不需要确认"   needs_confirmation
rm -f "$SNAPSHOT_DIR/had_table"
ok "首次应用需要确认"         needs_confirmation
INTERACTIVE=0
no "非交互时不提问"           needs_confirmation
end_action
no "快照目录已清理"           test -d "$snap"

rm -f "$NFT_SH_WHITELIST_FILE"
begin_action
printf '1.2.3.4\n' > "$NFT_SH_WHITELIST_FILE"
restore_config_files "$SNAPSHOT_DIR"
no "恢复快照会删除原本不存在的配置" test -e "$NFT_SH_WHITELIST_FILE"
end_action
: > "$NFT_SH_WHITELIST_FILE"

# ---------------------------------------------------------------- 非交互时拒绝危险操作
no "非交互默认拒绝"           confirm_danger "继续?"
ok "NFT_SH_FORCE=1 时放行"    env NFT_SH_FORCE=1 bash -c 'source "$1"; confirm_danger x' _ "$ROOT/nft.sh"
FAKE_LISTEN="8443"
no "本机已有服务监听的端口：非交互模式拒绝" fwd_validate 8443 192.0.2.10 443
FAKE_LISTEN=""

# ---------------------------------------------------------------- 应用流程（用模拟的 nft 命令）
FAKE_BIN="$WORK/fakebin"
export FAKE_NFT_STATE="$WORK/nftstate"
mkdir -p "$FAKE_BIN" "$FAKE_NFT_STATE"
cat > "$FAKE_BIN/nft" <<'EOF'
#!/bin/bash
# 模拟 nft：记录调用；"已加载"的表以文件形式保存在 $FAKE_NFT_STATE/table_<名称>
S="$FAKE_NFT_STATE"
if [ "${1:-}" = "-c" ]; then
    echo '-c (readonly precheck)' >> "$S/calls"
    [ ! -e "$S/fail_precheck" ]
    exit $?
fi
echo "$*" >> "$S/calls"
case "${1:-} ${2:-}" in
    "list tables")
        for f in "$S"/table_*; do
            [ -e "$f" ] && echo "table inet ${f##*/table_}"
        done
        exit 0
        ;;
    "list table")
        [ -f "$S/table_$4" ] || exit 1
        cat "$S/table_$4"
        exit 0
        ;;
    "delete table")
        rm -f "$S/table_$4"
        exit 0
        ;;
esac
if [ "${1:-}" = "-f" ]; then
    input="$2"
    if [ "$input" = "-" ]; then
        input=$(mktemp "$S/stdin.XXXXXX") || exit 1
        trap 'rm -f "$input"' EXIT
        cat > "$input"
    fi
    if [ -e "$S/fail" ]; then
        echo "Error: simulated failure" >&2
        exit 1
    fi
    cp "$input" "$S/last.nft"
    while read -r a b c d; do
        if [ "$a $b $c" = "delete table inet" ]; then
            rm -f "$S/table_$d"
        fi
    done < "$input"
    if grep -q '^table inet unified {' "$input"; then
        cp "$input" "$S/table_unified"
    fi
    exit 0
fi
exit 1
EOF
printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/systemctl"
chmod +x "$FAKE_BIN/nft" "$FAKE_BIN/systemctl"
PATH="$FAKE_BIN:$PATH"
hash -r

NFT_PERSIST_DIR="$WORK/nftables.d"
NFT_PERSIST_FILE="$NFT_PERSIST_DIR/unified.nft"
NFT_INCLUDE_LINE="include \"$NFT_PERSIST_FILE\""
SYSCTL_FILE="$WORK/sysctl-forward.conf"
detect_nft_main_conf() { echo "$WORK/nftables.conf"; }
ip_forward_enabled() { return 0; }

INTERACTIVE=0
echo 1 > "$NFT_SH_ENABLED_FILE"
printf '203.0.113.5\n' > "$NFT_SH_WHITELIST_FILE"
printf '8080|192.0.2.10|80\n' > "$NFT_SH_FORWARD_FILE"
printf 'flush ruleset\n' > "$WORK/nftables.conf"
: > "$FAKE_NFT_STATE/table_unified_nat"     # 旧版本遗留的表
: > "$FAKE_NFT_STATE/table_filter"          # 用户自己的表

begin_action
ok "应用成功"                         apply_all_rules
end_action
ok "unified 表已加载"                 test -f "$FAKE_NFT_STATE/table_unified"
ok "旧版本遗留表已删除"               test ! -e "$FAKE_NFT_STATE/table_unified_nat"
ok "用户自己的 inet filter 表保留"    test -e "$FAKE_NFT_STATE/table_filter"
has "删旧表和建新表在同一个事务里"    "$(cat "$FAKE_NFT_STATE/last.nft")" "delete table inet unified_nat"
ok "持久化文件已写入"                 test -f "$NFT_PERSIST_FILE"
lacks "持久化文件不含删除旧表的命令"  "$(cat "$NFT_PERSIST_FILE")" "unified_nat"
eq "include 行已添加"                 "1" "$(grep -cxF "$NFT_INCLUDE_LINE" "$WORK/nftables.conf")"
begin_action
apply_all_rules >/dev/null 2>&1
end_action
eq "重复应用不会重复添加 include 行"  "1" "$(grep -cxF "$NFT_INCLUDE_LINE" "$WORK/nftables.conf")"

cp "$NFT_PERSIST_FILE" "$WORK/persist.before"
: > "$FAKE_NFT_STATE/fail"
begin_action
wl_add 198.51.100.9 >/dev/null
no "nft 加载失败时返回失败"           apply_all_rules
end_action
rm -f "$FAKE_NFT_STATE/fail"
eq "加载失败后白名单恢复原样"         "203.0.113.5" "$(load_whitelist | tr '\n' ' ' | sed 's/ $//')"
ok "加载失败后持久化文件不变"         cmp -s "$WORK/persist.before" "$NFT_PERSIST_FILE"

export SSH_CONNECTION="203.0.113.5 50000 10.0.0.1 22"
: > "$FAKE_NFT_STATE/calls"
begin_action
wl_remove 203.0.113.5 >/dev/null
no "非交互模式拒绝删除当前 SSH 来源 IP" apply_all_rules
end_action
eq "被拒绝后白名单恢复原样"           "203.0.113.5" "$(load_whitelist | tr '\n' ' ' | sed 's/ $//')"
lacks "被拒绝时没有加载任何规则"      "$(cat "$FAKE_NFT_STATE/calls")" "-f "
export NFT_SH_FORCE=1
begin_action
wl_remove 203.0.113.5 >/dev/null
ok "设置 NFT_SH_FORCE=1 后可以强制执行" apply_all_rules
end_action
unset NFT_SH_FORCE SSH_CONNECTION

: > "$NFT_SH_WHITELIST_FILE"
: > "$NFT_SH_FORWARD_FILE"
echo 1 > "$NFT_SH_ENABLED_FILE"
ok "命令行 add-ip"                    run_cli add-ip 203.0.113.7
ok "命令行 add-forward"               run_cli add-forward 10000-10001 192.0.2.10 20000-20001
eq "转发已写入配置"                   "10000-10001|192.0.2.10|20000-20001" "$(cat "$NFT_SH_FORWARD_FILE")"
has "持久化规则包含端口映射"          "$(cat "$NFT_PERSIST_FILE")" "10001 : 20001"
no "命令行重复添加转发"               run_cli add-forward 10001 192.0.2.10 80
ok "命令行 del-forward"               run_cli del-forward 10000-10001
eq "删除后没有转发"                   "0" "$(list_forwards | wc -l | tr -d ' ')"
ok "命令行 whitelist off"             run_cli whitelist off
eq "白名单开关已关闭"                 "0" "$(cat "$NFT_SH_ENABLED_FILE")"
has "关闭后 input 放行"               "$(cat "$NFT_PERSIST_FILE")" "policy accept;"
no "命令行缺少参数"                   run_cli add-ip
no "命令行未知命令"                   run_cli no-such-command
no "白名单命令拒绝多余参数"           run_cli whitelist off extra

# 重新应用 / 导入不能绕过 SSH 端口和重叠检查（FORCE 也不允许抢占 SSH）。
printf '2222|192.0.2.10|80\n' > "$NFT_SH_FORWARD_FILE"
export SSH_CONNECTION='203.0.113.7 50000 10.0.0.1 2222' NFT_SH_FORCE=1
: > "$FAKE_NFT_STATE/calls"
no "重新应用拒绝配置中的 SSH 转发"    run_cli apply
lacks "拒绝 SSH 转发时不加载规则"     "$(cat "$FAKE_NFT_STATE/calls")" "-f "
unset SSH_CONNECTION NFT_SH_FORCE
printf '10000-10002|192.0.2.10|20000-20002\n10001|192.0.2.11|80\n' > "$NFT_SH_FORWARD_FILE"
no "重新应用拒绝重叠的转发配置"       run_cli apply
: > "$NFT_SH_FORWARD_FILE"

saved_ensure=$(declare -f ensure_ip_forward)
ensure_ip_forward() { return 1; }
: > "$FAKE_NFT_STATE/calls"
no "开启 IP 转发失败时添加命令失败"   run_cli add-forward 8080 192.0.2.10 80
eq "开启 IP 转发失败不保存转发"       "" "$(cat "$NFT_SH_FORWARD_FILE")"
lacks "开启 IP 转发失败不加载规则"    "$(cat "$FAKE_NFT_STATE/calls")" "-f "
eval "$saved_ensure"

# 持久化失败必须可见，替换失败不能截断上次可用的文件。
cp "$NFT_PERSIST_FILE" "$WORK/persist.before"
mv() { return 1; }
no "持久化替换失败返回错误"           persist_rules "$FAKE_NFT_STATE/last.nft"
unset -f mv
ok "替换失败保留旧持久化文件"         cmp -s "$WORK/persist.before" "$NFT_PERSIST_FILE"
saved_persist="$NFT_PERSIST_FILE"
mkdir "$WORK/persist-directory"
NFT_PERSIST_FILE="$WORK/persist-directory"
if out=$(run_cli apply 2>&1); then rc=0; else rc=$?; fi
eq "应用时持久化失败返回非零"         "1" "$rc"
lacks "持久化失败不显示应用成功"      "$out" "✓ 规则已应用"
eq "持久化目标为目录时不把临时文件移入" "0" "$(find "$NFT_PERSIST_FILE" -type f | wc -l | tr -d ' ')"
NFT_PERSIST_FILE="$saved_persist"
mkdir "$WORK/conf-directory"
detect_nft_main_conf() { echo "$WORK/conf-directory"; }
no "主配置无法写入时持久化失败"       persist_rules "$FAKE_NFT_STATE/last.nft"
detect_nft_main_conf() { echo "$WORK/nftables.conf"; }

printf '#!/bin/bash\nexit 1\n' > "$FAKE_BIN/cp"
chmod +x "$FAKE_BIN/cp"
hash -r
no "快照失败时拒绝修改配置"           run_cli add-ip 198.51.100.99
rm -f "$FAKE_BIN/cp"
hash -r
no "快照失败没有添加新 IP"            grep -qF '198.51.100.99' "$NFT_SH_WHITELIST_FILE"

# 后台保护不可用时必须在 nft 加载前退出。
saved_schedule=$(declare -f schedule_rollback_guard)
schedule_rollback_guard() { return 1; }
INTERACTIVE=1
begin_action
CONFIRM_ALWAYS=1
echo 1 > "$NFT_SH_ENABLED_FILE"
: > "$FAKE_NFT_STATE/calls"
no "后台保护无法启动时拒绝应用"       apply_all_rules
lacks "后台保护失败时未加载规则"      "$(cat "$FAKE_NFT_STATE/calls")" "-f "
end_action
eval "$saved_schedule"

# 确认、拒绝、真正的 read 超时、后台超时与迟到的确认。
begin_action
ok "输入 y 确认"                     confirm_or_rollback <<< y
ok "确认标记已写入"                  test -e "$SNAPSHOT_DIR/confirmed"
end_action
begin_action
wl_add 198.51.100.9 >/dev/null
no "输入 n 回滚"                     confirm_or_rollback <<< n
no "拒绝后配置已恢复"                grep -qF '198.51.100.9' "$NFT_SH_WHITELIST_FILE"
end_action
begin_action
wl_add 198.51.100.9 >/dev/null
ROLLBACK_TIMEOUT=1
no "未按回车的 y 超时仍回滚"         confirm_or_rollback < <(release_action_lock; printf y; sleep 2)
no "超时后配置已恢复"                grep -qF '198.51.100.9' "$NFT_SH_WHITELIST_FILE"
end_action
ROLLBACK_TIMEOUT=60
begin_action
wl_add 198.51.100.9 >/dev/null
snap="$SNAPSHOT_DIR"
rollback_guard "$snap" 0
no "后台回滚恢复配置"                grep -qF '198.51.100.9' "$NFT_SH_WHITELIST_FILE"
no "后台回滚后清理快照"              test -d "$snap"
no "后台回滚后的 y 不能算确认成功"   confirm_or_rollback <<< y
end_action
INTERACTIVE=0

# 安全读取归档成员：只接受唯一的普通文件，完全不展开路径和链接。
mkdir -p "$WORK/archive/directory"
printf 'payload\n' > "$WORK/archive/member"
tar -czf "$WORK/member.tar.gz" -C "$WORK/archive" member
ok "读取普通归档成员"                read_backup_member "$WORK/member.tar.gz" member "$WORK/member.out"
eq "归档成员内容"                    "payload" "$(cat "$WORK/member.out")"
tar -czf "$WORK/duplicate.tar.gz" -C "$WORK/archive" member member
no "拒绝同名的多个归档成员"          read_backup_member "$WORK/duplicate.tar.gz" member "$WORK/member.out"
tar -czf "$WORK/directory.tar.gz" -C "$WORK/archive" directory
no "拒绝把归档目录当作配置文件"      read_backup_member "$WORK/directory.tar.gz" directory "$WORK/member.out"
if [ "$(uname -s)" = Linux ]; then
    ln -s "$NFT_SH_WHITELIST_FILE" "$WORK/archive/link"
    tar -czf "$WORK/link.tar.gz" -C "$WORK/archive" link
    no "拒绝归档符号链接"            read_backup_member "$WORK/link.tar.gz" link "$WORK/member.out"
    ln "$WORK/archive/member" "$WORK/archive/hardlink"
    tar -czf "$WORK/hardlink.tar.gz" -C "$WORK/archive" member hardlink
    no "拒绝归档硬链接"              read_backup_member "$WORK/hardlink.tar.gz" hardlink "$WORK/member.out"
fi

# 使用旧版本相同的归档路径，验证正常导入和 SSH 防护。
printf '203.0.113.7\n' > "$NFT_SH_WHITELIST_FILE"
printf '8080|192.0.2.10|80\n' > "$NFT_SH_FORWARD_FILE"
echo 0 > "$NFT_SH_ENABLED_FILE"
tar -czf "$WORK/backup.tar.gz" -C / "${NFT_SH_WHITELIST_FILE#/}" "${NFT_SH_FORWARD_FILE#/}" "${NFT_SH_ENABLED_FILE#/}"
: > "$NFT_SH_FORWARD_FILE"
begin_action
ok "导入正常的旧格式备份"            import_config <<< "$WORK/backup.tar.gz"
end_action
eq "备份中的转发已恢复"              '8080|192.0.2.10|80' "$(cat "$NFT_SH_FORWARD_FILE")"
printf '2222|192.0.2.10|80\n' > "$NFT_SH_FORWARD_FILE"
tar -czf "$WORK/ssh-backup.tar.gz" -C / "${NFT_SH_FORWARD_FILE#/}"
printf '8080|192.0.2.10|80\n' > "$NFT_SH_FORWARD_FILE"
export SSH_CONNECTION='203.0.113.7 50000 10.0.0.1 2222'
begin_action
no "导入备份不能抢占 SSH 端口"       import_config <<< "$WORK/ssh-backup.tar.gz"
end_action
eq "导入被拒绝后原配置保留"          '8080|192.0.2.10|80' "$(cat "$NFT_SH_FORWARD_FILE")"
unset SSH_CONNECTION
printf 'invalid\n' > "$NFT_SH_ENABLED_FILE"
printf '198.51.100.55\n' > "$NFT_SH_WHITELIST_FILE"
tar -czf "$WORK/bad-flag.tar.gz" -C / "${NFT_SH_WHITELIST_FILE#/}" "${NFT_SH_ENABLED_FILE#/}"
printf '203.0.113.7\n' > "$NFT_SH_WHITELIST_FILE"
echo 1 > "$NFT_SH_ENABLED_FILE"
begin_action
no "导入无效白名单开关时拒绝整份备份" import_config <<< "$WORK/bad-flag.tar.gz"
end_action
eq "无效开关不会关闭白名单"          "1" "$(cat "$NFT_SH_ENABLED_FILE")"
eq "无效备份不会部分覆盖白名单"      '203.0.113.7' "$(cat "$NFT_SH_WHITELIST_FILE")"
CLI_MODE=0

# Deployment is data, never executable shell input; only known unique keys.
mkdir -p "$TRANSLATE_DIR"
printf 'id=nftsh\nipv4=198.18.241\nipv6=fd73:6866:7400\n' > "$WORK/deployment.valid"
ok "读取完整部署数据" translation_settings "$WORK/deployment.valid"
printf 'id=nftsh\nid=other\nipv4=198.18.241\nipv6=fd73:6866:7400\n' > "$WORK/deployment.bad"
no "拒绝重复部署键" translation_settings "$WORK/deployment.bad"
printf 'id=$(touch %s)\nipv4=198.18.241\nipv6=fd73:6866:7400\n' "$WORK/executed" > "$WORK/deployment.bad"
no "部署值不能执行命令" translation_settings "$WORK/deployment.bad"
no "部署数据没有执行 shell 内容" test -e "$WORK/executed"
printf 'unknown=value\nid=nftsh\nipv4=198.18.241\nipv6=fd73:6866:7400\n' > "$WORK/deployment.bad"
no "拒绝未知部署键" translation_settings "$WORK/deployment.bad"
no "不恢复动态接口索引" managed_forwarding_sysctl net/ipv6/conf/eth0/ifindex
ok "恢复受管 IPv6 forwarding" managed_forwarding_sysctl net/ipv6/conf/eth0/forwarding
ok "恢复上联 RA 设置" managed_forwarding_sysctl net/ipv6/conf/eth0/accept_ra
ok "支持验收版本 Jool 4.1.15" translation_version_supported 4.1.15.0
ok "支持同系列后续版本" translation_version_supported 4.1.16
no "拒绝未通过分片验收的旧 Jool" translation_version_supported 4.1.13.0
no "拒绝未经验证的新主版本" translation_version_supported 5.0.0
no "拒绝无效模块版本" translation_version_supported '4.1.foo'
if [ "$(type -t flock)" = file ]; then
    begin_action
    no "拒绝并发配置事务" bash -c 'source "$1"; trap end_action EXIT; begin_action' _ "$ROOT/nft.sh"
    end_action
    ok "事务结束后释放文件锁" bash -c 'source "$1"; trap end_action EXIT; begin_action' _ "$ROOT/nft.sh"
    begin_action
    pending_snapshot="$SNAPSHOT_DIR"
    printf '%s\n' "$pending_snapshot" > "$FORWARD_FILE.lock"
    release_action_lock
    SNAPSHOT_DIR=""
    no "断连后回滚未完成时拒绝新事务" bash -c 'source "$1"; trap end_action EXIT; begin_action' _ "$ROOT/nft.sh"
    touch "$pending_snapshot/completed"
    ok "回滚完成后允许新事务" bash -c 'source "$1"; trap end_action EXIT; begin_action' _ "$ROOT/nft.sh"
    remove_snapshot_dir "$pending_snapshot"
fi

echo ""
echo "单元测试: 通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
