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
unset SSH_CONNECTION SSH_CLIENT

# shellcheck source=../nft.sh
source "$ROOT/nft.sh"

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
no "端口数量不一致"   parse_forward_line '1-3|1.2.3.4|1-5'
no "域名目标"         parse_forward_line '8080|example.com|80'
no "注释行"           parse_forward_line '# 8080|1.2.3.4|80'
no "空行"             parse_forward_line '   '

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
    # 模拟 sudo：父进程有 SSH_CONNECTION，脚本自己的环境里没有（依赖 Linux 的 /proc）
    got=$(env SSH_CONNECTION="198.51.100.20 40000 10.0.0.1 22" bash -c \
        'env -u SSH_CONNECTION -u SSH_CLIENT bash -c "source \"\$1\"; get_ssh_connection" _ "$1"' _ "$ROOT/nft.sh")
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
    if [ -e "$S/fail" ]; then
        echo "Error: simulated failure" >&2
        exit 1
    fi
    cp "$2" "$S/last.nft"
    while read -r a b c d; do
        if [ "$a $b $c" = "delete table inet" ]; then
            rm -f "$S/table_$d"
        fi
    done < "$2"
    if grep -q '^table inet unified {' "$2"; then
        cp "$2" "$S/table_unified"
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
CLI_MODE=0

echo ""
echo "单元测试: 通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
