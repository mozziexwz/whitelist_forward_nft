#!/bin/bash
#
# NFTables 白名单防火墙 + 端口转发 一体化管理脚本
#
#   - 白名单：启用后只有白名单 IP 能访问本机和转发端口
#   - 端口转发：单端口 / 端口段，TCP+UDP，本地端口段与目标端口段一一对应
#   - 规则一次性原子加载：要么全部生效，要么保持原样，不会只生效一半
#   - 防失联：应用前检查当前 SSH 来源 IP；修改白名单后限时确认，超时自动回滚
#
# 不带参数运行进入交互菜单；运行 "bash nft.sh help" 查看命令行用法。

VERSION="2.0.0"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# 配置文件（可用环境变量覆盖，主要用于测试）
WHITELIST_FILE="${NFT_SH_WHITELIST_FILE:-/etc/nftables_whitelist.txt}"
FORWARD_FILE="${NFT_SH_FORWARD_FILE:-/etc/port_forward_nft.conf}"
WHITELIST_ENABLED_FILE="${NFT_SH_ENABLED_FILE:-/etc/nftables_whitelist_enabled}"

# nftables 表名与持久化（路径同样可用环境变量覆盖，供测试使用，避免改动测试机的 /etc）
NFT_TABLE="unified"
NFT_PERSIST_DIR="${NFT_SH_PERSIST_DIR:-/etc/nftables.d}"
NFT_PERSIST_FILE="$NFT_PERSIST_DIR/unified.nft"
NFT_INCLUDE_LINE="include \"$NFT_PERSIST_FILE\""
NFT_MAIN_CONF="${NFT_SH_MAIN_CONF:-}"     # 为空时自动检测
SYSCTL_FILE="${NFT_SH_SYSCTL_FILE:-/etc/sysctl.d/99-nft-sh-forward.conf}"

# 旧版本脚本用过的表，应用规则时一并删除；其他程序和用户自己的表（如 inet filter）不会被改动
LEGACY_TABLES=(whitelist_filter port_forward unified_filter unified_nat)

# 修改白名单后等待确认的秒数，超时自动回滚
ROLLBACK_TIMEOUT=60

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"

IPV4_RE='^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$'

# 运行状态
INTERACTIVE=0       # 能否向用户提问（标准输入是终端）
CLI_MODE=0          # 是否以命令行参数方式运行
SNAPSHOT_DIR=""     # 本次操作开始前的快照（失败时恢复配置、超时回滚规则）
ROLLBACK_PENDING=0  # 已安排后台回滚任务，快照目录由它负责清理
CONFIRM_ALWAYS=0    # 本次应用一定要求确认（重新应用规则 / 导入配置）
FWD_LS="" FWD_LE="" FWD_TIP="" FWD_TS="" FWD_TE=""   # fwd_validate 的校验结果

# ============================================================================
# 通用工具
# ============================================================================

info()  { echo -e "${GREEN}$*${NC}"; }
warn()  { echo -e "${YELLOW}$*${NC}"; }
error() { echo -e "${RED}$*${NC}"; }

# 去掉首尾空白和 Windows 换行符
trim() {
    local s="${1//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# join_by ", " a b c  ->  a, b, c
join_by() {
    local sep="$1" out="" x
    shift
    for x in "$@"; do
        out+="${out:+$sep}$x"
    done
    printf '%s' "$out"
}

# 向文件追加一行；文件末尾没有换行符时先补上，避免和上一行粘在一起
append_line() {
    local file="$1" line="$2"
    if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
        printf '\n' >> "$file"
    fi
    printf '%s\n' "$line" >> "$file"
}

# 危险操作的二次确认。非交互运行时默认拒绝，设置 NFT_SH_FORCE=1 才会继续
confirm_danger() {
    local ans
    if [ "$INTERACTIVE" -eq 1 ]; then
        echo -ne "${RED}$1 [y/N]: ${NC}"
        read -r ans
        [[ "$ans" =~ ^[Yy]$ ]]
        return
    fi
    if [ "${NFT_SH_FORCE:-0}" = "1" ]; then
        warn "已设置 NFT_SH_FORCE=1，继续执行"
        return 0
    fi
    error "非交互模式下已取消（确认无误可设置环境变量 NFT_SH_FORCE=1 强制执行）"
    return 1
}

# ============================================================================
# IP 地址校验与计算
# ============================================================================

is_valid_ipv4() {
    [[ "$1" =~ $IPV4_RE ]]
}

# 只接受标准写法（含 :: 压缩），不接受 zone（%eth0）和内嵌 IPv4 写法
is_valid_ipv6() {
    local ip="$1" rest dbl g n=0
    [[ "$ip" =~ ^[0-9a-fA-F:]{2,39}$ ]] || return 1
    [[ "$ip" == *:::* ]] && return 1
    rest="${ip//::/}"
    dbl=$(( (${#ip} - ${#rest}) / 2 ))
    [ "$dbl" -le 1 ] || return 1
    # 单个冒号不能出现在开头或结尾
    if [[ "$ip" == :* && "$ip" != ::* ]] || [[ "$ip" == *: && "$ip" != *:: ]]; then
        return 1
    fi
    local IFS=:
    for g in $ip; do
        [ -z "$g" ] && continue
        [ "${#g}" -le 4 ] || return 1
        n=$((n + 1))
    done
    if [ "$dbl" -eq 1 ]; then
        [ "$n" -le 7 ]
    else
        [ "$n" -eq 8 ]
    fi
}

ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int_to_ipv4() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# 把（已校验的）IPv6 地址展开成 8 个十进制分组，空格分隔
ipv6_to_groups() {
    local ip="$1" head tail i
    local -a h=() t=() g=()
    if [[ "$ip" == *::* ]]; then
        head="${ip%%::*}"
        tail="${ip#*::}"
    else
        head="$ip"
        tail=""
    fi
    [ -n "$head" ] && IFS=: read -r -a h <<< "$head"
    [ -n "$tail" ] && IFS=: read -r -a t <<< "$tail"
    g=("${h[@]}")
    for ((i = ${#h[@]} + ${#t[@]}; i < 8; i++)); do
        g+=(0)
    done
    g+=("${t[@]}")
    for i in "${!g[@]}"; do
        g[i]=$((16#${g[i]}))
    done
    echo "${g[*]}"
}

# 8 个十进制分组 -> 压缩后的 IPv6 文本（最长的连续 0 段用 :: 表示）
groups_to_ipv6() {
    local -a g=("$@")
    local i best_s=-1 best_l=0 cur_s=-1 cur_l=0 out=""
    for ((i = 0; i < 8; i++)); do
        if [ "${g[i]}" -eq 0 ]; then
            [ "$cur_s" -lt 0 ] && cur_s=$i
            cur_l=$((cur_l + 1))
            if [ "$cur_l" -gt "$best_l" ]; then
                best_s=$cur_s
                best_l=$cur_l
            fi
        else
            cur_s=-1
            cur_l=0
        fi
    done
    [ "$best_l" -lt 2 ] && best_s=-1
    for ((i = 0; i < 8; i++)); do
        if [ "$i" -eq "$best_s" ]; then
            out+="::"
            i=$((i + best_l - 1))
            continue
        fi
        if [ -n "$out" ] && [[ "$out" != *: ]]; then
            out+=":"
        fi
        out+=$(printf '%x' "${g[i]}")
    done
    echo "$out"
}

# 校验并规范化白名单条目（IP 或 CIDR）：清零 CIDR 主机位、去掉 /32 和 /128、IPv6 统一小写压缩
# 合法则输出规范化结果，非法返回 1
normalize_ip_entry() {
    local entry ip len="" n mask i bits out
    local -a g
    entry=$(trim "$1")
    ip="${entry%%/*}"
    if [[ "$entry" == */* ]]; then
        len="${entry#*/}"
        [[ "$len" =~ ^[0-9]{1,3}$ ]] || return 1
        len=$((10#$len))
    fi

    if is_valid_ipv4 "$ip"; then
        if [ -z "$len" ] || [ "$len" -eq 32 ]; then
            echo "$ip"
            return 0
        fi
        [ "$len" -le 32 ] || return 1
        n=$(ipv4_to_int "$ip")
        mask=$(( len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
        echo "$(int_to_ipv4 $(( n & mask )))/$len"
        return 0
    fi

    if is_valid_ipv6 "$ip"; then
        read -r -a g <<< "$(ipv6_to_groups "$ip")"
        if [ -n "$len" ]; then
            [ "$len" -le 128 ] || return 1
            for ((i = 0; i < 8; i++)); do
                bits=$(( len - i * 16 ))
                if [ "$bits" -le 0 ]; then
                    g[i]=0
                elif [ "$bits" -lt 16 ]; then
                    g[i]=$(( g[i] & ((0xFFFF << (16 - bits)) & 0xFFFF) ))
                fi
            done
        fi
        out=$(groups_to_ipv6 "${g[@]}")
        if [ -n "$len" ] && [ "$len" -lt 128 ]; then
            echo "$out/$len"
        else
            echo "$out"
        fi
        return 0
    fi
    return 1
}

# 判断 IP 是否属于某个条目（单个 IP 或 CIDR，均为规范化后的形式，地址族相同）
ip_in_cidr() {
    local ip="$1" net="${2%%/*}" len i bits mask a b
    local -a ga gb
    if [[ "$ip" == *:* ]]; then
        len=128
        [[ "$2" == */* ]] && len="${2#*/}"
        read -r -a ga <<< "$(ipv6_to_groups "$ip")"
        read -r -a gb <<< "$(ipv6_to_groups "$net")"
        for ((i = 0; i < 8; i++)); do
            bits=$(( len - i * 16 ))
            [ "$bits" -le 0 ] && break
            [ "$bits" -gt 16 ] && bits=16
            mask=$(( (0xFFFF << (16 - bits)) & 0xFFFF ))
            [ $(( ga[i] & mask )) -eq $(( gb[i] & mask )) ] || return 1
        done
        return 0
    fi
    len=32
    [[ "$2" == */* ]] && len="${2#*/}"
    a=$(ipv4_to_int "$ip")
    b=$(ipv4_to_int "$net")
    mask=$(( len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
    [ $(( a & mask )) -eq $(( b & mask )) ]
}

# 转发目标：只允许普通 IPv4 单播地址
validate_target_ip() {
    local ip="$1" first
    if ! is_valid_ipv4 "$ip"; then
        error "错误: 目标IP \"$ip\" 无效（只支持 IPv4 地址，不支持域名和 IPv6）"
        return 1
    fi
    first="${ip%%.*}"
    if [ "$first" -eq 0 ] || [ "$first" -eq 127 ] || [ "$first" -ge 224 ]; then
        error "错误: 目标IP不能是 0.x.x.x、127.x.x.x、组播或保留地址"
        return 1
    fi
    return 0
}

# ============================================================================
# 端口
# ============================================================================

# 校验端口号（1-65535），输出去掉前导零的十进制值（避免 08080 被当成八进制）
normalize_port() {
    local p
    p=$(trim "$1")
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    p="${p#"${p%%[!0]*}"}"          # 去掉前导零
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    p=$((10#$p))
    if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
        return 1
    fi
    echo "$p"
}

# 解析 "端口" 或 "起始-结束"，输出 "起始 结束"（单端口时两者相同）
parse_port_spec() {
    local spec a b
    spec=$(trim "$1")
    if [[ "$spec" == *-* ]]; then
        a=$(normalize_port "${spec%%-*}") || return 1
        b=$(normalize_port "${spec#*-}") || return 1
        [ "$a" -lt "$b" ] || return 1
    else
        a=$(normalize_port "$spec") || return 1
        b=$a
    fi
    echo "$a $b"
}

# "起始 结束" -> "8080" 或 "10000-10010"
port_spec() {
    if [ "$1" -eq "$2" ]; then
        echo "$1"
    else
        echo "$1-$2"
    fi
}

# 本机 SSH 服务端口（sshd 配置 + 当前连接的服务端口），都取不到时按 22 处理
get_ssh_ports() {
    local ports=""
    if command -v sshd >/dev/null 2>&1; then
        ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}')
    fi
    ports+=$'\n'$(get_ssh_connection | awk '{print $4}')
    ports=$(printf '%s\n' "$ports" | grep -E '^[0-9]+$' | sort -un)
    [ -n "$ports" ] || ports=22
    printf '%s\n' "$ports"
}

# 本机正在对外监听的 TCP/UDP 端口（忽略只监听在回环地址上的服务）
get_listening_ports() {
    command -v ss >/dev/null 2>&1 || return 0
    ss -lntu 2>/dev/null | awk 'NR > 1 {
        addr = $5
        if (addr ~ /^127\./ || addr ~ /^\[::1\]/) next
        n = split(addr, a, ":")
        print a[n]
    }' | grep -E '^[0-9]+$' | sort -un
}

# 检查本地端口是否和 SSH / 本机已有服务冲突；返回 1 表示不能继续
check_local_ports() {
    local s="$1" e="$2" hit
    hit=$(get_ssh_ports | awk -v s="$s" -v e="$e" '$1 >= s && $1 <= e' | tr '\n' ' ')
    if [ -n "$hit" ]; then
        error "错误: 本地端口包含 SSH 端口 ${hit}，转发后将无法再通过 SSH 登录本机，已拒绝"
        return 1
    fi
    hit=$(get_listening_ports | awk -v s="$s" -v e="$e" '$1 >= s && $1 <= e' | head -n 10 | tr '\n' ' ')
    if [ -n "$hit" ]; then
        warn "注意: 本机已有服务在监听端口 ${hit}"
        warn "      转发后外部访问这些端口会被转到目标服务器，本机上的服务将无法再从外部访问"
        confirm_danger "仍然继续?" || return 1
    fi
    return 0
}

# ============================================================================
# 配置文件读取
# ============================================================================

# 初始化配置文件
init_files() {
    [ -f "$WHITELIST_FILE" ] || touch "$WHITELIST_FILE"
    [ -f "$FORWARD_FILE" ] || touch "$FORWARD_FILE"
    # 默认白名单启用
    [ -f "$WHITELIST_ENABLED_FILE" ] || echo "1" > "$WHITELIST_ENABLED_FILE"
}

# 获取白名单开关状态
is_whitelist_enabled() {
    local file="${1:-$WHITELIST_ENABLED_FILE}"
    [ -f "$file" ] && [ "$(trim "$(head -n 1 "$file")")" = "1" ]
}

# 读取白名单原始条目（去掉空行、注释和首尾空白；末尾没有换行的最后一行也能读到）
load_whitelist() {
    local file="${1:-$WHITELIST_FILE}" line
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(trim "$line")
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue
        printf '%s\n' "$line"
    done < "$file"
}

# 读取白名单并规范化；无效条目跳过，并在 stderr 给出警告
load_whitelist_normalized() {
    local file="${1:-$WHITELIST_FILE}" e n
    while IFS= read -r e; do
        if n=$(normalize_ip_entry "$e"); then
            printf '%s\n' "$n"
        else
            echo -e "${YELLOW}警告: 白名单条目 \"$e\" 不是有效的 IP/CIDR，已跳过${NC}" >&2
        fi
    done < <(load_whitelist "$file")
}

# 白名单是否放行某个 IP
whitelist_allows() {
    local ip="$1" e
    while IFS= read -r e; do
        if [[ "$ip" == *:* ]]; then
            [[ "$e" == *:* ]] || continue
        else
            [[ "$e" == *:* ]] && continue
        fi
        ip_in_cidr "$ip" "$e" && return 0
    done < <(load_whitelist_normalized "$WHITELIST_FILE" 2>/dev/null)
    return 1
}

# 解析一行转发配置 "本地端口|目标IP|目标端口"（端口可以是 起始-结束）
# 合法则输出 "本地起始 本地结束 目标IP 目标起始 目标结束"
parse_forward_line() {
    local line lp tip tp extra l t ls le ts te
    line=$(trim "$1")
    [ -z "$line" ] && return 1
    [[ "$line" == \#* ]] && return 1
    IFS='|' read -r lp tip tp extra <<< "$line"
    [ -z "$extra" ] || return 1
    tip=$(trim "$tip")
    is_valid_ipv4 "$tip" || return 1
    l=$(parse_port_spec "$lp") || return 1
    t=$(parse_port_spec "$tp") || return 1
    read -r ls le <<< "$l"
    read -r ts te <<< "$t"
    [ $((le - ls)) -eq $((te - ts)) ] || return 1
    echo "$ls $le $tip $ts $te"
}

# 输出所有合法的转发条目，每行 "本地起始 本地结束 目标IP 目标起始 目标结束"
list_forwards() {
    local file="${1:-$FORWARD_FILE}" line
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        parse_forward_line "$line"
    done < "$file"
}

# 输出转发配置里格式无效的行（忽略空行和注释）
invalid_forward_lines() {
    local file="${1:-$FORWARD_FILE}" line t
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        t=$(trim "$line")
        [ -z "$t" ] && continue
        [[ "$t" == \#* ]] && continue
        parse_forward_line "$t" >/dev/null || printf '%s\n' "$t"
    done < "$file"
}

# 新的本地端口范围是否和已有转发重叠；重叠时输出已有的那条并返回 0
forward_conflict() {
    local s="$1" e="$2" ls le tip ts te
    while read -r ls le tip ts te; do
        if [ "$s" -le "$le" ] && [ "$e" -ge "$ls" ]; then
            echo "本地 $(port_spec "$ls" "$le") → $tip:$(port_spec "$ts" "$te")"
            return 0
        fi
    done < <(list_forwards)
    return 1
}

# ============================================================================
# SSH 连接检测
# ============================================================================

# 当前 SSH 连接信息 "客户端IP 客户端端口 服务端IP 服务端端口"
# sudo / su 会清掉 SSH_CONNECTION，此时沿父进程向上查找
get_ssh_connection() {
    local conn="${SSH_CONNECTION:-}" pid="$$" i
    if [ -z "$conn" ]; then
        for ((i = 0; i < 32; i++)); do
            pid=$(awk '/^PPid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null)
            if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
                break
            fi
            conn=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n 1)
            [ -n "$conn" ] && break
        done
    fi
    if [ -z "$conn" ] && [ -n "${SSH_CLIENT:-}" ]; then
        # SSH_CLIENT 只有 "客户端IP 客户端端口 服务端端口"
        conn=$(awk '{print $1, $2, "-", $3}' <<< "$SSH_CLIENT")
    fi
    printf '%s' "$conn"
}

# 获取当前 SSH 来源 IP（规范化后），检测不到时输出为空
get_current_ssh_ip() {
    local ip
    ip=$(get_ssh_connection | awk '{print $1}')
    ip="${ip%%\%*}"                         # 去掉 IPv6 的 %网卡 后缀
    if [[ "$ip" == ::ffff:* ]] && is_valid_ipv4 "${ip#::ffff:}"; then
        ip="${ip#::ffff:}"                  # IPv4 映射地址
    fi
    normalize_ip_entry "$ip" 2>/dev/null
}

# ============================================================================
# 生成 nftables 规则
# ============================================================================

nft_table_exists() {
    nft list table inet "$1" >/dev/null 2>&1
}

# 当前存在的旧版本表 -> 删除命令
legacy_table_deletes() {
    local t
    for t in "${LEGACY_TABLES[@]}"; do
        if nft_table_exists "$t"; then
            echo "delete table inet $t"
        fi
    done
}

# 把多条 nft 命令作为一个事务执行
nft_run_batch() {
    local f rc
    f=$(mktemp) || return 1
    printf '%s\n' "$1" > "$f"
    nft -f "$f"
    rc=$?
    rm -f "$f"
    return $rc
}

emit_set() {
    local name="$1" type="$2"
    shift 2
    printf '\tset %s {\n\t\ttype %s\n\t\tflags interval\n\t\tauto-merge\n' "$name" "$type"
    if [ $# -gt 0 ]; then
        printf '\t\telements = { %s }\n' "$(join_by ', ' "$@")"
    fi
    printf '\t}\n'
}

emit_chain() {
    local name="$1" header="$2" rule
    shift 2
    printf '\tchain %s {\n\t\t%s\n' "$name" "$header"
    for rule in "$@"; do
        printf '\t\t%s\n' "$rule"
    done
    printf '\t}\n'
}

# 根据配置文件生成完整规则。文件可以重复加载：先删除旧的 unified 表再整体重建，
# 整个文件由 nft -f 一次性原子执行
build_ruleset() {
    local e i proto lspec tspec target cmt line policy="accept"
    local ls le tip ts te
    local -a v4=() v6=() f_ls=() f_le=() f_tip=() f_ts=() f_te=() f_map=()
    local -a pre=() outp=() post=() in_rules=() fw_rules=()

    is_whitelist_enabled && policy="drop"

    while IFS= read -r e; do
        if [[ "$e" == *:* ]]; then
            v6+=("$e")
        else
            v4+=("$e")
        fi
    done < <(load_whitelist_normalized)

    while IFS= read -r line; do
        echo -e "${YELLOW}警告: 转发配置 \"$line\" 格式无效，已跳过${NC}" >&2
    done < <(invalid_forward_lines)

    while read -r ls le tip ts te; do
        f_ls+=("$ls"); f_le+=("$le"); f_tip+=("$tip"); f_ts+=("$ts"); f_te+=("$te")
    done < <(list_forwards)

    echo "#!/usr/sbin/nft -f"
    echo "# Generated by nft.sh $VERSION. Do not edit: changes are overwritten on the next apply."
    echo "add table inet $NFT_TABLE"
    echo "delete table inet $NFT_TABLE"
    echo "table inet $NFT_TABLE {"
    emit_set allowed_ips ipv4_addr "${v4[@]}"
    emit_set allowed_ips_v6 ipv6_addr "${v6[@]}"

    # 本地端口段和目标端口段起点不同：用映射表把每个端口一一对应
    # （直接写 dnat to IP:起始-结束 只会从目标范围里挑一个端口，不是一一对应）
    for i in "${!f_ls[@]}"; do
        f_map[i]=""
        if [ "${f_ls[i]}" -ne "${f_le[i]}" ] && [ "${f_ls[i]}" -ne "${f_ts[i]}" ]; then
            f_map[i]="fwd_ports_$((i + 1))"
            printf '\tmap %s {\n\t\ttype inet_service : inet_service\n\t\telements = {\n' "${f_map[i]}"
            awk -v ls="${f_ls[i]}" -v le="${f_le[i]}" -v ts="${f_ts[i]}" 'BEGIN {
                for (p = ls; p <= le; p++)
                    printf "\t\t\t%d : %d%s\n", p, ts + p - ls, (p < le ? "," : "")
            }'
            printf '\t\t}\n\t}\n'
        fi
    done

    for i in "${!f_ls[@]}"; do
        lspec=$(port_spec "${f_ls[i]}" "${f_le[i]}")
        tspec=$(port_spec "${f_ts[i]}" "${f_te[i]}")
        cmt="comment \"nft.sh $lspec\""
        for proto in tcp udp; do
            if [ "${f_ls[i]}" -eq "${f_le[i]}" ]; then
                target="${f_tip[i]}:${f_ts[i]}"
            elif [ -z "${f_map[i]}" ]; then
                target="${f_tip[i]}"        # 端口段号码相同：不写端口，保持原端口
            else
                target="${f_tip[i]} : $proto dport map @${f_map[i]}"
            fi
            # 只转发发往本机地址的流量，不会劫持容器 / VPN 客户端经过本机访问外网的流量
            pre+=("meta nfproto ipv4 fib daddr type local $proto dport $lspec counter dnat ip to $target $cmt")
            # 本机访问自己的转发端口同样生效；本机访问其他服务器的同号端口不受影响
            outp+=("ip daddr != 127.0.0.0/8 fib daddr type local $proto dport $lspec counter dnat ip to $target $cmt")
            # 只对 DNAT 过的连接做 masquerade，保证目标服务器的回包经过本机
            post+=("ct status dnat ip daddr ${f_tip[i]} $proto dport $tspec counter masquerade $cmt")
        done
    done

    emit_chain prerouting "type nat hook prerouting priority dstnat; policy accept;" "${pre[@]}"
    emit_chain output_nat "type nat hook output priority -100; policy accept;" "${outp[@]}"
    emit_chain postrouting "type nat hook postrouting priority srcnat; policy accept;" "${post[@]}"

    if [ "$policy" = "drop" ]; then
        in_rules=(
            "ct state established,related accept"
            "ct state invalid drop"
            "iif \"lo\" accept"
            "meta l4proto icmpv6 accept"
            "ip6 saddr fe80::/10 udp dport 546 accept"
            "ip saddr @allowed_ips accept"
            "ip6 saddr @allowed_ips_v6 accept"
        )
        # 只拦截 DNAT（端口转发 / 容器端口映射）的新连接；容器、VPN 的其他转发流量不受影响
        fw_rules=(
            "ct state established,related accept"
            "ct state invalid drop"
            "ct status dnat ip saddr @allowed_ips accept"
            "ct status dnat ip6 saddr @allowed_ips_v6 accept"
            "ct status dnat drop"
        )
    fi
    emit_chain input "type filter hook input priority filter; policy $policy;" "${in_rules[@]}"
    emit_chain forward "type filter hook forward priority filter; policy accept;" "${fw_rules[@]}"
    echo "}"
}

# ============================================================================
# 快照与回滚（防失联）
# ============================================================================

remove_snapshot_dir() {
    case "$1" in
        */nft-sh.*) rm -rf -- "$1" ;;
    esac
}

# 记录操作前的状态：三个配置文件 + 当前生效的 unified 表
begin_action() {
    local i=0 f
    end_action
    CONFIRM_ALWAYS=0
    SNAPSHOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nft-sh.XXXXXX") || {
        SNAPSHOT_DIR=""
        return 1
    }
    for f in "$WHITELIST_FILE" "$FORWARD_FILE" "$WHITELIST_ENABLED_FILE"; do
        i=$((i + 1))
        printf '%s\n' "$f" > "$SNAPSHOT_DIR/cfg.$i.path"
        if [ -f "$f" ]; then
            cp -p "$f" "$SNAPSHOT_DIR/cfg.$i"
        else
            : > "$SNAPSHOT_DIR/cfg.$i"
        fi
    done
    {
        echo "add table inet $NFT_TABLE"
        echo "delete table inet $NFT_TABLE"
        if nft list table inet "$NFT_TABLE" 2>/dev/null; then
            : > "$SNAPSHOT_DIR/had_table"
        fi
    } > "$SNAPSHOT_DIR/live.nft"
}

end_action() {
    if [ -n "$SNAPSHOT_DIR" ] && [ "$ROLLBACK_PENDING" -ne 1 ]; then
        remove_snapshot_dir "$SNAPSHOT_DIR"
    fi
    SNAPSHOT_DIR=""
    ROLLBACK_PENDING=0
}

# 把配置文件恢复成快照里的内容
restore_config_files() {
    local snap="$1" p target
    for p in "$snap"/cfg.*.path; do
        [ -f "$p" ] || continue
        target=$(head -n 1 "$p")
        [ -n "$target" ] && cat "${p%.path}" > "$target"
    done
}

# 恢复快照：实时规则 + 配置文件。旧规则恢复失败时删除本脚本的表，保证不会把人锁在外面
restore_snapshot() {
    local snap="$1" rc=0
    if ! nft -f "$snap/live.nft" 2>/dev/null; then
        nft delete table inet "$NFT_TABLE" 2>/dev/null
        rc=1
    fi
    restore_config_files "$snap"
    return $rc
}

# 在独立于当前 SSH 会话的后台安排回滚：即使连接断开、脚本被终止，也会按时回滚
schedule_rollback_guard() {
    local snap="$1" delay="$2" self="$1/nft.sh"
    if [ ! -f "$SCRIPT_PATH" ] || ! cp -f "$SCRIPT_PATH" "$self" 2>/dev/null || [ ! -s "$self" ]; then
        return 1
    fi
    if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ] &&
        systemd-run --quiet --unit="nft-sh-rollback-$$-$RANDOM" --on-active="$delay" \
            /bin/bash "$self" __rollback_guard "$snap" 0 >/dev/null 2>&1; then
        return 0
    fi
    if command -v setsid >/dev/null 2>&1; then
        setsid /bin/bash "$self" __rollback_guard "$snap" "$delay" </dev/null >/dev/null 2>&1 &
        return 0
    fi
    return 1
}

# 后台回滚任务本体（由 schedule_rollback_guard 启动）
rollback_guard() {
    local snap="$1" delay="${2:-0}"
    case "$snap" in
        */nft-sh.*) ;;
        *) return 1 ;;
    esac
    [ -d "$snap" ] || return 0
    if [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ]; then
        sleep "$delay"
    fi
    if [ ! -e "$snap/confirmed" ] && [ ! -e "$snap/rolled_back" ]; then
        : > "$snap/rolled_back"
        restore_snapshot "$snap"
        if command -v logger >/dev/null 2>&1; then
            logger -t nft.sh "change was not confirmed in time, firewall rules rolled back"
        fi
    fi
    remove_snapshot_dir "$snap"
}

# 本次操作是否删除了白名单条目
whitelist_shrank() {
    local removed
    removed=$(LC_ALL=C comm -23 \
        <(load_whitelist_normalized "$SNAPSHOT_DIR/cfg.1" 2>/dev/null | LC_ALL=C sort -u) \
        <(load_whitelist_normalized "$WHITELIST_FILE" 2>/dev/null | LC_ALL=C sort -u))
    [ -n "$removed" ]
}

# 是否需要用户确认（可能导致失联的改动才需要）
needs_confirmation() {
    [ "$INTERACTIVE" -eq 1 ] || return 1
    is_whitelist_enabled || return 1
    [ -n "$SNAPSHOT_DIR" ] || return 1
    [ "$CONFIRM_ALWAYS" -eq 1 ] && return 0
    [ -e "$SNAPSHOT_DIR/had_table" ] || return 0                 # 首次应用
    is_whitelist_enabled "$SNAPSHOT_DIR/cfg.3" || return 0       # 白名单刚被启用
    whitelist_shrank && return 0                                 # 白名单有条目被删除
    return 1
}

# 规则已生效后等待确认，超时或拒绝则回滚
confirm_or_rollback() {
    local snap="$SNAPSHOT_DIR" ans="" answered=0
    if schedule_rollback_guard "$snap" $((ROLLBACK_TIMEOUT + 5)); then
        ROLLBACK_PENDING=1
    else
        warn "（无法创建后台回滚任务：如果当前 SSH 连接意外断开，规则不会自动回滚）"
    fi
    echo ""
    warn "规则已生效。请不要关闭当前窗口，另开一个 SSH 窗口测试能否正常登录。"
    echo -ne "${YELLOW}确认正常请在 ${ROLLBACK_TIMEOUT} 秒内输入 y 并回车，超时或输入其他内容将自动回滚: ${NC}"
    # 超时时 read 会保留已输入但没按回车的内容，所以必须以 read 成功返回为准
    if read -r -t "$ROLLBACK_TIMEOUT" ans; then
        answered=1
    else
        echo ""
    fi
    if [ "$answered" -eq 1 ] && [[ "$ans" =~ ^[Yy]$ ]] && [ ! -e "$snap/rolled_back" ]; then
        : > "$snap/confirmed"
        return 0
    fi
    : > "$snap/rolled_back"
    if restore_snapshot "$snap"; then
        warn "已回滚：防火墙规则和配置都恢复到了修改前的状态"
    else
        error "恢复旧规则失败，已删除本脚本的防火墙表以保证可以登录，请检查后重新应用规则"
    fi
    return 1
}

# ============================================================================
# 持久化
# ============================================================================

# nftables 开机加载的主配置文件（Debian/Ubuntu 为 /etc/nftables.conf，RHEL 系为 /etc/sysconfig/nftables.conf）
detect_nft_main_conf() {
    local conf="$NFT_MAIN_CONF"
    if [ -z "$conf" ] && command -v systemctl >/dev/null 2>&1; then
        conf=$(systemctl show -p ExecStart nftables 2>/dev/null | grep -oE -e '-f [^ ;]+' | head -n 1 | awk '{print $2}')
    fi
    [ -n "$conf" ] || conf="/etc/nftables.conf"
    echo "$conf"
}

persist_rules() {
    local rules="$1" conf
    if ! mkdir -p "$NFT_PERSIST_DIR" || ! cat "$rules" > "$NFT_PERSIST_FILE"; then
        error "✗ 写入 $NFT_PERSIST_FILE 失败，规则在重启后不会保留"
        return 1
    fi
    conf=$(detect_nft_main_conf)
    if [ -f "$conf" ]; then
        if ! grep -qxF "$NFT_INCLUDE_LINE" "$conf"; then
            append_line "$conf" "$NFT_INCLUDE_LINE"
        fi
    else
        mkdir -p "$(dirname "$conf")"
        printf '#!/usr/sbin/nft -f\n%s\n' "$NFT_INCLUDE_LINE" > "$conf"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl enable nftables >/dev/null 2>&1; then
            warn "提示: 设置 nftables 开机自启失败，重启后规则可能不会自动加载"
        fi
    else
        warn "提示: 未检测到 systemd，请自行确保开机时加载 $conf"
    fi
    return 0
}

# 从 nftables 主配置中删除本脚本添加的 include 行；返回 0 表示主配置已不再引用持久化文件
remove_include_line() {
    local conf tmp
    conf=$(detect_nft_main_conf)
    [ -f "$conf" ] || return 0
    if grep -qxF "$NFT_INCLUDE_LINE" "$conf"; then
        tmp=$(mktemp) || return 1
        grep -vxF "$NFT_INCLUDE_LINE" "$conf" > "$tmp"
        cat "$tmp" > "$conf"
        rm -f "$tmp"
    fi
    ! grep -qF "$NFT_PERSIST_FILE" "$conf"
}

# ============================================================================
# 应用规则
# ============================================================================

# 应用前检查：白名单启用时，不能把当前 SSH 来源 IP 挡在外面
precheck_lockout() {
    local ssh_ip count ans
    is_whitelist_enabled || return 0
    ssh_ip=$(get_current_ssh_ip)
    if [ -n "$ssh_ip" ]; then
        whitelist_allows "$ssh_ip" && return 0
        error "警告: 当前 SSH 来源 IP $ssh_ip 不在白名单中！"
        error "应用后当前连接不会断开，但之后新的 SSH 连接都会被拒绝。"
        if [ "$INTERACTIVE" -eq 1 ]; then
            echo -ne "是否先把 $ssh_ip 加入白名单? [Y/n]: "
            read -r ans
            if [[ ! "$ans" =~ ^[Nn]$ ]] && wl_add "$ssh_ip"; then
                return 0
            fi
        fi
        confirm_danger "仍然继续应用规则?"
        return
    fi
    count=$(load_whitelist_normalized 2>/dev/null | wc -l)
    if [ "$count" -eq 0 ]; then
        error "警告: 白名单已启用但为空，应用后所有新连接（包括 SSH）都会被拒绝！"
        confirm_danger "仍然继续应用规则?"
        return
    fi
    return 0
}

ip_forward_enabled() {
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]
}

# 应用完整规则（原子操作），成功后写入持久化配置
apply_all_rules() {
    local rules live err wl_count fw_count
    echo -e "${YELLOW}正在应用防火墙和转发规则...${NC}"

    if ! precheck_lockout; then
        [ -n "$SNAPSHOT_DIR" ] && restore_config_files "$SNAPSHOT_DIR"
        warn "已取消，配置和防火墙规则都没有改动"
        return 1
    fi

    rules=$(mktemp) || return 1
    live=$(mktemp) || { rm -f "$rules"; return 1; }
    build_ruleset > "$rules"
    { legacy_table_deletes; cat "$rules"; } > "$live"

    if ! err=$(nft -f "$live" 2>&1); then
        error "✗ 规则应用失败，防火墙保持原样，没有做任何改动。nft 输出:"
        printf '%s\n' "$err" | head -n 20
        if [ -n "$SNAPSHOT_DIR" ]; then
            restore_config_files "$SNAPSHOT_DIR"
            warn "配置文件已恢复为修改前的内容"
        fi
        rm -f "$rules" "$live"
        return 1
    fi

    if needs_confirmation && ! confirm_or_rollback; then
        rm -f "$rules" "$live"
        return 1
    fi

    persist_rules "$rules"
    rm -f "$rules" "$live"

    wl_count=$(load_whitelist_normalized 2>/dev/null | wc -l)
    fw_count=$(list_forwards | wc -l)
    if is_whitelist_enabled; then
        echo -e "${GREEN}✓ 规则已应用 - 白名单${GREEN}[启用]${GREEN}（${wl_count} 条），转发 ${fw_count} 条（TCP+UDP）${NC}"
    else
        echo -e "${GREEN}✓ 规则已应用 - 白名单${RED}[关闭]${GREEN}，转发 ${fw_count} 条（TCP+UDP）${NC}"
    fi
    if [ "$fw_count" -gt 0 ] && ! ip_forward_enabled; then
        warn "注意: IPv4 转发 (net.ipv4.ip_forward) 未开启，端口转发不会生效，请在菜单中选择 7 开启"
    fi
    return 0
}

# ============================================================================
# 白名单操作
# ============================================================================

# 添加白名单条目（只改配置文件，不应用规则）
wl_add() {
    local raw entry e
    raw=$(trim "$1")
    if ! entry=$(normalize_ip_entry "$raw"); then
        error "错误: \"$raw\" 不是有效的 IP 或 CIDR（例: 1.2.3.4、1.2.3.0/24、2001:db8::/32，不支持域名）"
        return 1
    fi
    while IFS= read -r e; do
        if [ "$e" = "$entry" ]; then
            warn "已存在: $entry"
            return 1
        fi
    done < <(load_whitelist_normalized 2>/dev/null)
    append_line "$WHITELIST_FILE" "$entry"
    if [ "$entry" != "$raw" ]; then
        info "✓ 已添加: $entry（已规范化，原输入 $raw）"
    else
        info "✓ 已添加: $entry"
    fi
}

# 删除白名单条目（按 IP/CIDR 匹配，规范化后比较），只改配置文件
wl_remove() {
    local target norm_target line t found=0 tmp
    target=$(trim "$1")
    norm_target=$(normalize_ip_entry "$target") || norm_target="$target"
    tmp=$(mktemp) || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        t=$(trim "$line")
        if [ -n "$t" ] && { [ "$t" = "$target" ] || [ "$(normalize_ip_entry "$t")" = "$norm_target" ]; }; then
            found=1
            continue
        fi
        printf '%s\n' "$line"
    done < "$WHITELIST_FILE" > "$tmp"
    if [ "$found" -eq 0 ]; then
        rm -f "$tmp"
        error "白名单中不存在: $target"
        return 1
    fi
    cat "$tmp" > "$WHITELIST_FILE"
    rm -f "$tmp"
    info "✓ 已删除: $target"
}

# 显示白名单
show_whitelist() {
    local status count=0 line
    if is_whitelist_enabled; then
        status="${GREEN}[已启用]${NC}"
    else
        status="${RED}[已关闭]${NC}"
    fi
    echo -e "${BLUE}当前白名单 $status${NC}"
    echo "=========================================="
    while IFS= read -r line; do
        count=$((count + 1))
        if normalize_ip_entry "$line" >/dev/null; then
            echo -e "${GREEN}[$count]${NC} $line"
        else
            echo -e "${GREEN}[$count]${NC} $line ${RED}(格式无效，不会生效)${NC}"
        fi
    done < <(load_whitelist)
    if [ "$count" -eq 0 ]; then
        warn "(白名单为空)"
    fi
    echo "=========================================="
}

menu_add_ip() {
    local ip
    echo ""
    echo -ne "输入IP/CIDR: "
    read -r ip
    ip=$(trim "$ip")
    [ -n "$ip" ] || return 0
    wl_add "$ip" && apply_all_rules
}

menu_remove_ip() {
    local input ip
    echo ""
    show_whitelist
    echo -ne "输入序号或IP: "
    read -r input
    input=$(trim "$input")
    [ -n "$input" ] || return 0
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        ip=$(load_whitelist | sed -n "$((10#$input))p" 2>/dev/null)
        if [ -z "$ip" ]; then
            error "无效序号"
            return 1
        fi
    else
        ip="$input"
    fi
    wl_remove "$ip" && apply_all_rules
}

# 切换白名单开关（启用时的 SSH IP 检查和限时确认由 apply_all_rules 统一处理）
toggle_whitelist() {
    local confirm wl_count
    echo -e "\n${BLUE}【白名单开关】${NC}"
    if is_whitelist_enabled; then
        echo -e "当前状态: ${GREEN}已启用${NC}"
        warn "关闭后所有IP均可访问本机及转发端口（不受限制）"
        echo -ne "${RED}确认关闭白名单? [y/N]: ${NC}"
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "0" > "$WHITELIST_ENABLED_FILE"
            apply_all_rules && info "✓ 白名单已关闭 - 所有IP均可访问"
        fi
    else
        echo -e "当前状态: ${RED}已关闭${NC}"
        wl_count=$(load_whitelist_normalized 2>/dev/null | wc -l)
        echo -e "白名单中有 ${WHITE}${wl_count}${NC} 个有效条目"
        echo -ne "${YELLOW}确认启用白名单? [Y/n]: ${NC}"
        read -r confirm
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
            echo "1" > "$WHITELIST_ENABLED_FILE"
            apply_all_rules && info "✓ 白名单已启用"
        fi
    fi
}

# ============================================================================
# 端口转发操作
# ============================================================================

# 启用IP转发（写入 /etc/sysctl.d，新旧发行版重启后都能生效）
enable_ip_forward() {
    local conflict
    echo -e "${YELLOW}正在启用IPv4转发...${NC}"
    if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        error "✗ 启用失败（部分容器类 VPS 不允许修改内核参数）"
        return 1
    fi
    if mkdir -p "$(dirname "$SYSCTL_FILE")" &&
        printf '# Written by nft.sh: port forwarding needs IPv4 forwarding\nnet.ipv4.ip_forward = 1\n' > "$SYSCTL_FILE"; then
        info "✓ IPv4转发已启用，并写入 $SYSCTL_FILE（重启后仍然生效）"
    else
        warn "IPv4转发已临时启用，但写入 $SYSCTL_FILE 失败，重启后会失效"
    fi
    conflict=$(grep -lsE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*0' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null | grep -vxF "$SYSCTL_FILE" | tr '\n' ' ')
    if [ -n "$conflict" ]; then
        warn "注意: 这些文件把 net.ipv4.ip_forward 设为 0，可能导致重启后转发失效，请检查: $conflict"
    fi
    return 0
}

# 添加转发前确保已开启 IPv4 转发
ensure_ip_forward() {
    local ans
    ip_forward_enabled && return 0
    warn "IPv4转发 (net.ipv4.ip_forward) 尚未开启，不开启的话端口转发不会生效"
    if [ "$INTERACTIVE" -eq 1 ] && [ "$CLI_MODE" -eq 0 ]; then
        echo -ne "现在开启? [Y/n]: "
        read -r ans
        [[ "$ans" =~ ^[Nn]$ ]] && return 0
    fi
    enable_ip_forward
}

# 校验转发参数：本地端口[-端口] 目标IP 目标端口[-端口]
# 成功时结果保存在 FWD_LS FWD_LE FWD_TIP FWD_TS FWD_TE
fwd_validate() {
    local l t conflict
    FWD_TIP=$(trim "$2")
    validate_target_ip "$FWD_TIP" || return 1
    if ! l=$(parse_port_spec "$1"); then
        error "错误: 无效的本地端口 \"$(trim "$1")\"（范围 1-65535；端口段写成 起始-结束，且起始小于结束）"
        return 1
    fi
    if ! t=$(parse_port_spec "$3"); then
        error "错误: 无效的目标端口 \"$(trim "$3")\"（范围 1-65535；端口段写成 起始-结束，且起始小于结束）"
        return 1
    fi
    read -r FWD_LS FWD_LE <<< "$l"
    read -r FWD_TS FWD_TE <<< "$t"
    if [ $((FWD_LE - FWD_LS)) -ne $((FWD_TE - FWD_TS)) ]; then
        error "错误: 端口数量必须相同（本地 $((FWD_LE - FWD_LS + 1)) 个 vs 目标 $((FWD_TE - FWD_TS + 1)) 个）"
        return 1
    fi
    if conflict=$(forward_conflict "$FWD_LS" "$FWD_LE"); then
        error "错误: 本地端口与已有转发重叠: $conflict"
        return 1
    fi
    check_local_ports "$FWD_LS" "$FWD_LE"
}

fwd_append() {
    local lspec tspec
    lspec=$(port_spec "$FWD_LS" "$FWD_LE")
    tspec=$(port_spec "$FWD_TS" "$FWD_TE")
    append_line "$FORWARD_FILE" "$lspec|$FWD_TIP|$tspec"
    info "✓ 已添加转发: 本地 $lspec → $FWD_TIP:$tspec [TCP+UDP]"
}

# 删除第 N 条（按 list_forwards 的顺序）转发，只改配置文件
fwd_remove_index() {
    local target="$1" n=0 line tmp removed=""
    tmp=$(mktemp) || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if parse_forward_line "$line" >/dev/null; then
            n=$((n + 1))
            if [ "$n" -eq "$target" ]; then
                removed=$(trim "$line")
                continue
            fi
        fi
        printf '%s\n' "$line"
    done < "$FORWARD_FILE" > "$tmp"
    if [ -z "$removed" ]; then
        rm -f "$tmp"
        error "无效序号"
        return 1
    fi
    cat "$tmp" > "$FORWARD_FILE"
    rm -f "$tmp"
    info "✓ 已删除转发: $removed"
}

# 按本地端口（段）查找转发的序号
fwd_index_by_local() {
    local want n=0 ls le
    want=$(parse_port_spec "$1") || return 1
    while read -r ls le _; do
        n=$((n + 1))
        if [ "$ls $le" = "$want" ]; then
            echo "$n"
            return 0
        fi
    done < <(list_forwards)
    return 1
}

show_forwards() {
    local n=0 ls le tip ts te
    while read -r ls le tip ts te; do
        n=$((n + 1))
        echo -e "${GREEN}[$n]${NC} [TCP+UDP] 本地:$(port_spec "$ls" "$le") → $tip:$(port_spec "$ts" "$te")"
    done < <(list_forwards)
    if [ "$n" -eq 0 ]; then
        warn "(无转发规则)"
    fi
}

# 显示确认信息并添加（菜单用）
fwd_confirm_and_apply() {
    local confirm
    echo -e "\n${YELLOW}确认添加:${NC}"
    echo -e "  本地端口 ${GREEN}$(port_spec "$FWD_LS" "$FWD_LE")${NC} → 目标 ${GREEN}$FWD_TIP:$(port_spec "$FWD_TS" "$FWD_TE")${NC}  [TCP+UDP]"
    if is_whitelist_enabled; then
        echo -e "  ${RED}注意: 只有白名单IP才能访问此转发${NC}"
    fi
    echo -ne "确认? [Y/n]: "
    read -r confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && return 0
    fwd_append
    ensure_ip_forward
    apply_all_rules
}

# 添加单个端口转发
add_forward_single() {
    local target_ip target_port local_port
    echo -e "\n${BLUE}【添加单端口转发】${NC}"
    echo -ne "${YELLOW}目标IP: ${NC}"
    read -r target_ip
    echo -ne "${YELLOW}目标端口: ${NC}"
    read -r target_port
    echo -ne "${YELLOW}本地端口: ${NC}"
    read -r local_port
    if [[ "$target_port" == *-* ]] || [[ "$local_port" == *-* ]]; then
        error "错误: 端口段请使用菜单 5（添加端口段转发）"
        return 1
    fi
    fwd_validate "$local_port" "$target_ip" "$target_port" || return 1
    fwd_confirm_and_apply
}

# 添加端口段转发
add_forward_range() {
    local target_ip ts te ls le
    echo -e "\n${BLUE}【添加端口段转发】${NC}"
    echo -ne "${YELLOW}目标IP: ${NC}"
    read -r target_ip
    echo -ne "${YELLOW}目标起始端口: ${NC}"
    read -r ts
    echo -ne "${YELLOW}目标结束端口: ${NC}"
    read -r te
    echo -ne "${YELLOW}本地起始端口: ${NC}"
    read -r ls
    echo -ne "${YELLOW}本地结束端口: ${NC}"
    read -r le
    fwd_validate "$(trim "$ls")-$(trim "$le")" "$target_ip" "$(trim "$ts")-$(trim "$te")" || return 1
    fwd_confirm_and_apply
}

# 删除端口转发
delete_forward() {
    local n rule_num
    n=$(list_forwards | wc -l)
    if [ "$n" -eq 0 ]; then
        error "无转发规则"
        return 0
    fi
    echo -e "\n${BLUE}【当前转发规则】${NC}"
    show_forwards
    echo -ne "\n${YELLOW}删除序号 (0取消): ${NC}"
    read -r rule_num
    rule_num=$(trim "$rule_num")
    [ "$rule_num" = "0" ] && return 0
    if ! [[ "$rule_num" =~ ^[0-9]{1,6}$ ]] || [ $((10#$rule_num)) -lt 1 ] || [ $((10#$rule_num)) -gt "$n" ]; then
        error "无效序号（请输入 1-$n）"
        return 1
    fi
    fwd_remove_index $((10#$rule_num)) && apply_all_rules
}

# ============================================================================
# 清除 / 导入 / 导出
# ============================================================================

clear_all_rules() {
    local clear_choice confirm batch
    echo -e "\n${BLUE}【清除规则】${NC}"
    echo -e "${GREEN}1.${NC} 清除所有白名单IP"
    echo -e "${GREEN}2.${NC} 清除所有转发端口"
    echo -e "${GREEN}3.${NC} 清除全部（白名单+转发+本脚本的防火墙表）"
    echo -e "${GREEN}0.${NC} 取消"
    echo -ne "${YELLOW}选择: ${NC}"
    read -r clear_choice

    case "$(trim "$clear_choice")" in
        1)
            if is_whitelist_enabled; then
                error "注意: 白名单处于启用状态，清空后将拒绝所有新连接（包括 SSH）"
            fi
            echo -ne "${RED}确认清除所有白名单IP? [y/N]: ${NC}"
            read -r confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                : > "$WHITELIST_FILE"
                apply_all_rules && info "✓ 已清除所有白名单IP"
            fi
            ;;
        2)
            echo -ne "${RED}确认清除所有转发端口? [y/N]: ${NC}"
            read -r confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                : > "$FORWARD_FILE"
                apply_all_rules && info "✓ 已清除所有转发端口"
            fi
            ;;
        3)
            warn "将删除本脚本的防火墙表（白名单保护和端口转发全部失效，本机对所有IP开放），"
            warn "并清空白名单和转发配置。系统中其他程序或你自己的 nftables 表不受影响。"
            echo -ne "${RED}确认清除全部? [y/N]: ${NC}"
            read -r confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || return 0
            batch=$(
                nft_table_exists "$NFT_TABLE" && echo "delete table inet $NFT_TABLE"
                legacy_table_deletes
            )
            if [ -n "$batch" ] && ! nft_run_batch "$batch"; then
                error "✗ 删除防火墙表失败，没有做任何改动"
                return 1
            fi
            : > "$WHITELIST_FILE"
            : > "$FORWARD_FILE"
            if remove_include_line; then
                rm -f "$NFT_PERSIST_FILE"
            else
                # 主配置里仍有其他行引用该文件：保留一个空的可加载版本，避免开机加载失败
                printf 'add table inet %s\ndelete table inet %s\n' "$NFT_TABLE" "$NFT_TABLE" > "$NFT_PERSIST_FILE"
            fi
            info "✓ 已清除全部规则"
            ;;
        0|"") return 0 ;;
        *) error "无效选择" ;;
    esac
}

export_config() {
    local backup f
    local -a members=()
    backup="$PWD/nftables_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    for f in "$WHITELIST_FILE" "$FORWARD_FILE" "$WHITELIST_ENABLED_FILE"; do
        [ -f "$f" ] && members+=("${f#/}")
    done
    if [ ${#members[@]} -eq 0 ]; then
        error "没有可导出的配置"
        return 1
    fi
    if tar -czf "$backup" -C / "${members[@]}"; then
        info "✓ 已导出: $backup"
    else
        rm -f "$backup"
        error "✗ 导出失败"
        return 1
    fi
}

# 导入配置：只读取本脚本的三个配置文件，内容逐条校验后再写入
import_config() {
    local backup_file tmpd src total valid found=0 wl_ok=0 wl_bad=0 fw_ok=0 fw_bad=0
    local ls le tip ts te
    echo -ne "备份文件路径: "
    read -r backup_file
    backup_file=$(trim "$backup_file")
    if [ ! -f "$backup_file" ]; then
        error "文件不存在"
        return 1
    fi
    tmpd=$(mktemp -d) || return 1
    # 只解出这三个文件，压缩包里的其他内容一律忽略（防止覆盖系统文件）。
    # 缺少其中某个文件时 tar 会报错，但其余文件仍会解出，所以不检查返回值
    tar -xzf "$backup_file" -C "$tmpd" \
        "${WHITELIST_FILE#/}" "${FORWARD_FILE#/}" "${WHITELIST_ENABLED_FILE#/}" 2>/dev/null

    src="$tmpd/${WHITELIST_FILE#/}"
    if [ -f "$src" ] && [ ! -L "$src" ]; then
        found=1
        total=$(load_whitelist "$src" | wc -l)
        load_whitelist_normalized "$src" 2>/dev/null | awk '!seen[$0]++' > "$WHITELIST_FILE"
        valid=$(load_whitelist_normalized "$src" 2>/dev/null | wc -l)
        wl_ok=$(load_whitelist | wc -l)
        wl_bad=$((total - valid))
    fi

    src="$tmpd/${FORWARD_FILE#/}"
    if [ -f "$src" ] && [ ! -L "$src" ]; then
        found=1
        list_forwards "$src" | while read -r ls le tip ts te; do
            echo "$(port_spec "$ls" "$le")|$tip|$(port_spec "$ts" "$te")"
        done > "$FORWARD_FILE"
        fw_ok=$(list_forwards | wc -l)
        fw_bad=$(invalid_forward_lines "$src" | wc -l)
    fi

    src="$tmpd/${WHITELIST_ENABLED_FILE#/}"
    if [ -f "$src" ] && [ ! -L "$src" ]; then
        found=1
        if is_whitelist_enabled "$src"; then
            echo "1" > "$WHITELIST_ENABLED_FILE"
        else
            echo "0" > "$WHITELIST_ENABLED_FILE"
        fi
    fi
    rm -rf "$tmpd"

    if [ "$found" -eq 0 ]; then
        error "备份文件中没有本脚本的配置（需要使用菜单 11 导出的 .tar.gz 文件）"
        return 1
    fi
    info "已读取备份: 白名单 ${wl_ok} 条，转发 ${fw_ok} 条"
    if [ $((wl_bad + fw_bad)) -gt 0 ]; then
        warn "跳过了 ${wl_bad} 条无效白名单、${fw_bad} 条无效转发"
    fi
    CONFIRM_ALWAYS=1
    apply_all_rules
}

# ============================================================================
# 状态显示
# ============================================================================

kernel_warning() {
    local rel major minor
    rel=$(uname -r)
    major="${rel%%.*}"
    minor="${rel#*.}"
    minor="${minor%%[!0-9]*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && [[ "$minor" =~ ^[0-9]+$ ]]; then
        if [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -lt 2 ]; }; then
            echo "当前内核 $rel 低于 5.2，可能不支持 inet 表的 NAT，端口转发规则可能应用失败"
        fi
    fi
}

show_all_rules() {
    local wl_count fw_count others kwarn
    [ "$CLI_MODE" -eq 1 ] || clear 2>/dev/null
    echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           当前防火墙和转发规则                     ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"

    echo -e "\n${BLUE}═══ 白名单 ═══${NC}"
    show_whitelist

    echo -e "\n${BLUE}═══ 端口转发 ═══${NC}"
    show_forwards

    echo -e "\n${BLUE}═══ 系统状态 ═══${NC}"
    if ip_forward_enabled; then
        echo -e "IPv4转发: ${GREEN}✓ 已启用${NC}"
    else
        echo -e "IPv4转发: ${RED}✗ 未启用${NC}"
    fi
    if nft_table_exists "$NFT_TABLE"; then
        echo -e "防火墙表: ${GREEN}✓ 已加载 (inet $NFT_TABLE)${NC}"
    else
        echo -e "防火墙表: ${RED}✗ 未加载（选择 8 应用规则）${NC}"
    fi
    fw_count=$(list_forwards | wc -l)
    echo -e "转发条目: ${WHITE}${fw_count} 条${NC}（每条均为 TCP+UDP）"
    wl_count=$(load_whitelist_normalized 2>/dev/null | wc -l)
    echo -e "白名单IP: ${WHITE}${wl_count} 个${NC}"
    others=$(nft list tables 2>/dev/null | grep -vxF "table inet $NFT_TABLE" | sed 's/^table //' | tr '\n' ' ')
    if [ -n "$others" ]; then
        echo -e "其他nftables表: ${WHITE}${others}${NC}（不受本脚本管理，其中的规则同样生效）"
    fi
    kwarn=$(kernel_warning)
    if [ -n "$kwarn" ]; then
        error "警告: $kwarn"
    fi

    if is_whitelist_enabled; then
        echo -e "\n${RED}重要: 白名单已启用 - 只有白名单IP才能访问VPS（包括转发端口）${NC}"
    else
        echo -e "\n${YELLOW}提示: 白名单已关闭 - 所有IP均可访问（转发端口无限制）${NC}"
    fi
}

# ============================================================================
# 交互菜单
# ============================================================================

check_nftables() {
    if ! command -v nft &> /dev/null; then
        error "✗ nftables 未安装"
        echo "请先安装: apt-get install nftables（Debian/Ubuntu）或 dnf install nftables（RHEL 系）"
        exit 1
    fi
}

main_menu() {
    local choice wl_status kwarn
    kwarn=$(kernel_warning)
    while true; do
        clear 2>/dev/null

        if is_whitelist_enabled; then
            wl_status="${GREEN}[白名单: 启用]${NC}"
        else
            wl_status="${RED}[白名单: 关闭]${NC}"
        fi

        echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║   nftable白名单IP+端口转发脚本         ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
        echo -e "  状态: $wl_status   版本: $VERSION"
        if [ -n "$kwarn" ]; then
            echo -e "  ${RED}警告: $kwarn${NC}"
        fi
        echo ""
        echo -e "${BLUE}【白名单管理】${NC}"
        echo -e "${GREEN}1.${NC} 添加IP到白名单"
        echo -e "${GREEN}2.${NC} 删除白名单IP"
        echo -e "${GREEN}3.${NC} 启用/关闭白名单"
        echo ""
        echo -e "${BLUE}【端口转发】${NC}"
        echo -e "${GREEN}4.${NC} 添加单端口转发"
        echo -e "${GREEN}5.${NC} 添加端口段转发"
        echo -e "${GREEN}6.${NC} 删除端口转发"
        echo -e "${GREEN}7.${NC} 启用IP转发(sysctl)"
        echo ""
        echo -e "${BLUE}【系统】${NC}"
        echo -e "${GREEN}8.${NC} 应用所有规则"
        echo -e "${GREEN}9.${NC} 查看所有规则"
        echo -e "${GREEN}10.${NC} 清除所有规则"
        echo -e "${GREEN}11.${NC} 导出配置"
        echo -e "${GREEN}12.${NC} 导入配置"
        echo -e "${GREEN}0.${NC} 退出"
        echo ""
        echo -ne "选择 [0-12]: "
        if ! read -r choice; then
            echo ""
            exit 0
        fi
        choice=$(trim "$choice")

        # 会修改配置或规则的操作，先记录快照，失败或超时可以恢复
        case "$choice" in
            1|2|3|4|5|6|8|10|12) begin_action ;;
        esac

        case "$choice" in
            1) menu_add_ip ;;
            2) menu_remove_ip ;;
            3) toggle_whitelist ;;
            4) add_forward_single ;;
            5) add_forward_range ;;
            6) delete_forward ;;
            7) enable_ip_forward ;;
            8) CONFIRM_ALWAYS=1; apply_all_rules ;;
            9) show_all_rules ;;
            10) clear_all_rules ;;
            11) export_config ;;
            12) import_config ;;
            0) echo ""; exit 0 ;;
            *) error "无效选择" ;;
        esac
        end_action

        echo ""
        echo -n "按回车继续..."
        read -r _ || exit 0
    done
}

# 初始化向导
initial_setup() {
    local current_ip answer
    clear 2>/dev/null
    echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              初始化向导                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"
    echo ""

    current_ip=$(get_current_ssh_ip)
    if [ -n "$current_ip" ]; then
        echo -e "检测到你的SSH连接IP: ${GREEN}$current_ip${NC}"
        echo ""
        warn "强烈建议将此IP添加到白名单！"
        echo -ne "是否添加? [Y/n]: "
        read -r answer
        if [[ ! "$answer" =~ ^[Nn]$ ]]; then
            wl_add "$current_ip"
            echo ""
        fi
    else
        warn "未检测到SSH连接IP"
        echo "请在菜单中选择 1 手动添加你的IP地址"
        echo ""
    fi

    echo -e "${RED}重要提示:${NC}"
    echo "1. 白名单默认启用，应用规则后只有白名单IP才能访问VPS"
    echo "2. 端口转发也受白名单限制（白名单启用时）"
    echo "3. 修改白名单后需要在 ${ROLLBACK_TIMEOUT} 秒内确认，否则自动回滚，防止把自己锁在外面"
    echo "4. 如果你的公网IP经常变化，建议添加整个网段（如 1.2.3.0/24）"
    echo "5. 请确保至少添加一个可信IP"
    echo ""
    echo -n "按回车继续..."
    read -r _
}

# ============================================================================
# 命令行模式
# ============================================================================

usage() {
    local me
    me=$(basename "$0")
    cat <<EOF
nft.sh $VERSION - nftables 白名单防火墙 + 端口转发管理脚本

用法:
  $me                                     进入交互菜单
  $me status                              查看白名单、转发和系统状态
  $me apply                               按配置文件重新应用全部规则
  $me add-ip <IP/CIDR>                    添加白名单（如 1.2.3.4、1.2.3.0/24、2001:db8::/32）
  $me del-ip <IP/CIDR>                    删除白名单
  $me whitelist on|off                    启用 / 关闭白名单
  $me add-forward <本地端口> <目标IP> <目标端口>
                                          添加 TCP+UDP 转发，端口可以写成段，如 10000-10010
  $me del-forward <本地端口>              删除转发（按本地端口或端口段）
  $me ip-forward                          开启 IPv4 转发
  $me print-rules                         只打印将要应用的 nftables 规则，不做任何修改
  $me help | version

说明:
  - 在 SSH 终端中修改白名单后，需要在 ${ROLLBACK_TIMEOUT} 秒内确认，否则自动回滚
  - 非交互运行（如 cron）时，可能导致失联的操作会被拒绝；确认无误可设置 NFT_SH_FORCE=1
EOF
}

run_cli() {
    local cmd="$1" rc=0 idx
    shift
    CLI_MODE=1
    case "$cmd" in
        status)
            show_all_rules
            ;;
        print-rules)
            build_ruleset
            ;;
        apply)
            begin_action
            CONFIRM_ALWAYS=1
            apply_all_rules
            rc=$?
            ;;
        add-ip|del-ip)
            if [ $# -ne 1 ]; then
                usage >&2
                return 2
            fi
            begin_action
            if [ "$cmd" = "add-ip" ]; then
                wl_add "$1" && apply_all_rules
            else
                wl_remove "$1" && apply_all_rules
            fi
            rc=$?
            ;;
        whitelist)
            case "${1:-}" in
                on|off)
                    begin_action
                    if [ "$1" = "on" ]; then
                        echo "1" > "$WHITELIST_ENABLED_FILE"
                    else
                        echo "0" > "$WHITELIST_ENABLED_FILE"
                    fi
                    apply_all_rules
                    rc=$?
                    ;;
                *)
                    usage >&2
                    return 2
                    ;;
            esac
            ;;
        add-forward)
            if [ $# -ne 3 ]; then
                usage >&2
                return 2
            fi
            begin_action
            if fwd_validate "$1" "$2" "$3"; then
                fwd_append
                ensure_ip_forward
                apply_all_rules
                rc=$?
            else
                rc=1
            fi
            ;;
        del-forward)
            if [ $# -ne 1 ]; then
                usage >&2
                return 2
            fi
            begin_action
            if idx=$(fwd_index_by_local "$1"); then
                fwd_remove_index "$idx" && apply_all_rules
                rc=$?
            else
                error "没有找到本地端口为 $1 的转发"
                rc=1
            fi
            ;;
        ip-forward)
            enable_ip_forward
            rc=$?
            ;;
        *)
            usage >&2
            return 2
            ;;
    esac
    end_action
    return $rc
}

# ============================================================================
# 主程序
# ============================================================================

main() {
    case "${1:-}" in
        __rollback_guard)
            rollback_guard "${2:-}" "${3:-0}"
            exit $?
            ;;
        help|-h|--help)
            usage
            exit 0
            ;;
        version|-v|--version)
            echo "nft.sh $VERSION"
            exit 0
            ;;
    esac

    if [ "$EUID" -ne 0 ]; then
        error "错误: 请使用root权限运行（例如: sudo bash $0）"
        exit 1
    fi
    [ -t 0 ] && INTERACTIVE=1

    check_nftables
    init_files
    trap end_action EXIT

    if [ $# -gt 0 ]; then
        run_cli "$@"
        exit $?
    fi

    # 首次运行向导
    if [ -z "$(load_whitelist)" ]; then
        initial_setup
    fi

    main_menu
}

# 被 source 时只加载函数（供测试使用），直接运行时才执行主程序
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
fi
