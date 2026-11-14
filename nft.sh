#!/bin/bash
#
# NFTables 白名单防火墙 + 端口转发 一体化管理脚本
#
#   - 白名单：启用后只有白名单 IP 能访问本机和转发端口
#   - 端口转发：单端口 / 端口段，TCP+UDP，本地端口段与目标端口段一一对应
#   - nft 规则在单个事务中加载；跨族内核资源按阶段保护，失败恢复
#   - 防失联：应用前检查当前 SSH 来源 IP；修改白名单后限时确认，超时自动回滚
#
# 不带参数运行进入交互菜单；运行 "bash nft.sh help" 查看命令行用法。

VERSION="2.1.0"

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
TRANSLATE_DIR="${NFT_SH_TRANSLATE_DIR:-/etc/nft-sh}"
TRANSLATE_DEPLOY="$TRANSLATE_DIR/deployment.conf"
LIBEXEC_DIR="${NFT_SH_LIBEXEC_DIR:-/usr/local/libexec/nft-sh}"
SYSTEMD_DIR="${NFT_SH_SYSTEMD_DIR:-/etc/systemd/system}"
XL_ID="" XL4="" XL6=""
ACTION_LOCK_FD=""
ROLLBACK_CONTEXT_KEYS=(WHITELIST_FILE FORWARD_FILE WHITELIST_ENABLED_FILE NFT_TABLE
    NFT_PERSIST_DIR NFT_PERSIST_FILE NFT_INCLUDE_LINE NFT_MAIN_CONF SYSCTL_FILE
    TRANSLATE_DIR TRANSLATE_DEPLOY LIBEXEC_DIR SYSTEMD_DIR NFT_SH_LOCK_FILE
    NFT_SH_XLATE_ID NFT_SH_XLATE_V4 NFT_SH_XLATE_V6)

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
FWD_FAMILY="ipv4"

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

# 转发目标：IPv4 单播或全局/ULA IPv6 字面量；不允许回环、链路本地和映射地址。
validate_target_ip() {
    local ip="$1" first normalized
    if [[ "$ip" == *:* ]]; then
        [[ "$ip" != *'/'* && "$ip" != *'%'* && "$ip" != *'['* && "$ip" != *']'* ]] || return 1
        normalized=$(normalize_ip_entry "$ip") || return 1
        first="${normalized%%:*}"
        [[ "$first" =~ ^[0-9a-f]+$ ]] || return 1
        # 2000::/3 (including documentation addresses for isolated tests), fc00::/7.
        if (( (16#$first & 0xe000) == 0x2000 || (16#$first & 0xfe00) == 0xfc00 )); then
            return 0
        fi
        error "错误: IPv6 目标只支持全局单播和 ULA 地址"
        return 1
    fi
    if ! is_valid_ipv4 "$ip"; then
        error "错误: 目标IP \"$ip\" 无效（需要 IPv4 或 IPv6 字面量，不支持域名）"
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
    [ ! -f "$file" ] || [ "$(trim "$(head -n 1 "$file")")" = "1" ]
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
    local line lp tip tp extra l t ls le ts te family="" fields
    line=$(trim "$1")
    [ -z "$line" ] && return 1
    [[ "$line" == \#* ]] && return 1
    fields="${line//[^|]/}"
    case "${#fields}" in
        2) IFS='|' read -r lp tip tp extra <<< "$line" ;;
        3) IFS='|' read -r family lp tip tp extra <<< "$line"
           case "$family" in ipv4|ipv6) ;; *) return 1 ;; esac ;;
        *) return 1 ;;
    esac
    [[ -n "$lp" && -n "$tip" && -n "$tp" ]] || return 1
    [ -z "$extra" ] || return 1
    tip=$(trim "$tip")
    validate_target_ip "$tip" >/dev/null || return 1
    # A three-field legacy record always remains IPv4 -> IPv4.
    if [[ -z "$family" && "$tip" == *:* ]]; then return 1; fi
    tip=$(normalize_ip_entry "$tip") || return 1
    l=$(parse_port_spec "$lp") || return 1
    t=$(parse_port_spec "$tp") || return 1
    read -r ls le <<< "$l"
    read -r ts te <<< "$t"
    [ $((le - ls)) -eq $((te - ts)) ] || return 1
    printf '%s %s %s %s %s%s\n' "$ls" "$le" "$tip" "$ts" "$te" "${family:+ $family}"
}

# 输出所有合法条目：本地起始 本地结束 目标IP 目标起始 目标结束 入站族
list_forwards() {
    local file="${1:-$FORWARD_FILE}" line parsed ls le tip ts te family
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        parsed=$(parse_forward_line "$line") || continue
        read -r ls le tip ts te family <<< "$parsed"
        printf '%s %s %s %s %s %s\n' "$ls" "$le" "$tip" "$ts" "$te" "${family:-ipv4}"
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
    local s="$1" e="$2" want="${3:-ipv4}" ls le tip ts te family
    while read -r ls le tip ts te family; do
        [ "$want" = "$family" ] || continue
        if [ "$s" -le "$le" ] && [ "$e" -ge "$ls" ]; then
            echo "本地 $(port_spec "$ls" "$le") → $tip:$(port_spec "$ts" "$te")"
            return 0
        fi
    done < <(list_forwards)
    return 1
}

# ============================================================================
# Jool kernel translation. Control commands exit; no userspace data relay.
# ============================================================================

translation_settings() {
    local file="${1:-$TRANSLATE_DEPLOY}" key value
    local -A seen=()
    if [ -d "$TRANSLATE_DIR" ] && [ ! -x "$TRANSLATE_DIR" ]; then
        error '无法读取内核转换部署目录，请使用具备读取权限的用户预览' >&2; return 1
    fi
    if [ -e "$file" ] && [ ! -r "$file" ]; then error "无法读取 $file" >&2; return 1; fi
    XL_ID="${NFT_SH_XLATE_ID:-nftsh}"
    XL4="${NFT_SH_XLATE_V4:-198.18.241}"
    XL6="${NFT_SH_XLATE_V6:-fd73:6866:7400}"
    if [ -f "$file" ]; then
        while IFS='=' read -r key value || [ -n "$key" ]; do
            case "$key" in id|ipv4|ipv6|'') ;; *) return 1 ;; esac
            if [ -n "$key" ]; then
                [ -z "${seen[$key]:-}" ] || return 1
                seen[$key]=1
            fi
            case "$key" in
                id) XL_ID="$value" ;;
                ipv4) XL4="$value" ;;
                ipv6) XL6="$value" ;;
                '') ;;
                *) error "无效的内核转换部署参数: $key" >&2; return 1 ;;
            esac
        done < "$file"
        [ "${#seen[@]}" -eq 3 ] || return 1
    fi
    [[ "$XL_ID" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,7}$ ]] || return 1
    is_valid_ipv4 "$XL4.1" || return 1
    if ! ip_in_cidr "$XL4.1" 10.0.0.0/8 && ! ip_in_cidr "$XL4.1" 172.16.0.0/12 &&
        ! ip_in_cidr "$XL4.1" 192.168.0.0/16 && ! ip_in_cidr "$XL4.1" 198.18.0.0/15; then return 1; fi
    [[ "$XL6" =~ ^[fF][cCdD][0-9a-fA-F]{2}:[0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}$ ]] || return 1
    return 0
}

translation_needed() {
    local ls le tip ts te family result=1
    while read -r ls le tip ts te family; do
        if [[ "$family" = ipv6 && "$tip" != *:* ]] || [[ "$family" = ipv4 && "$tip" == *:* ]]; then
            result=0
        fi
    done < <(list_forwards "${1:-$FORWARD_FILE}")
    return "$result"
}

translation_mode_needed() {
    local ls le tip ts te family result=1
    while read -r ls le tip ts te family; do
        if { [ "$1" = 64 ] && [[ "$family" = ipv6 && "$tip" != *:* ]]; } ||
            { [ "$1" = 46 ] && [[ "$family" = ipv4 && "$tip" == *:* ]]; }; then result=0; fi
    done < <(list_forwards)
    return "$result"
}

translation_synth6() {
    local value
    value=$(ipv4_to_int "$1") || return 1
    printf '%s:64::%x:%x\n' "$XL6" "$((value >> 16))" "$((value & 65535))"
}

translation_alias6() { printf '%s:a46::%x\n' "$XL6" "$1"; }

# Called only from build_ruleset; append to its dynamically scoped rule arrays.
build_translation_rules() {
    local idx="$1" mode link synth alias p rule_target source_check=""
    translation_settings || { error '无效的内核转换部署配置' >&2; return 1; }
    if [ "${f_family[idx]}" = ipv6 ]; then mode=64; else mode=46; fi
    link="$XL_ID$mode"
    if [ "$policy" = drop ]; then
        if [ "$mode" = 64 ]; then source_check='ip6 saddr @allowed_ips_v6'; else source_check='ip saddr @allowed_ips'; fi
    fi
    if [ "$mode" = 64 ]; then
        synth=$(translation_synth6 "${f_tip[idx]}") || return 1
        for p in tcp udp; do
            if [ "${f_ls[idx]}" -eq "${f_le[idx]}" ]; then rule_target="[$synth]:${f_ts[idx]}"
            elif [ -n "${f_map[idx]}" ]; then rule_target="[$synth] : $p dport map @${f_map[idx]}"
            else rule_target="$synth"; fi
            pre+=("meta nfproto ipv6 fib daddr type local $p dport $lspec counter dnat ip6 to $rule_target $cmt")
            outp+=("ip6 daddr != ::1 fib daddr type local $p dport $lspec counter dnat ip6 to $rule_target $cmt")
            xguards+=("oifname \"$link\" ip6 daddr $synth $p dport $tspec ct status dnat ct original proto-dst $lspec $source_check counter accept")
            xguards+=("iifname \"$link\" ip saddr $XL4.64 ip daddr ${f_tip[idx]} $p dport $tspec counter accept")
            # Two ingress ports may resolve to the same synthetic endpoint.
            # Allocate distinct source endpoints before Jool, after the host's
            # original-source whitelist check, so reply tuples cannot collapse.
            xpost+=("oifname \"$link\" ct status dnat ip6 daddr $synth $p dport $tspec counter masquerade fully-random $cmt")
            xpost+=("iifname \"$link\" ip saddr $XL4.64 ip daddr ${f_tip[idx]} $p dport $tspec counter masquerade $cmt")
        done
    else
        alias=$(translation_alias6 "${f_ls[idx]}")
        for p in tcp udp; do
            pre+=("iifname \"$link\" ip6 saddr $XL6:46::/96 ip6 daddr $alias $p dport $tspec counter dnat ip6 to ${f_tip[idx]} $cmt")
            pre+=("meta nfproto ipv4 fib daddr type local $p dport $lspec counter dnat ip to $XL4.128 $cmt")
            outp+=("ip daddr != 127.0.0.0/8 fib daddr type local $p dport $lspec counter dnat ip to $XL4.128 $cmt")
            xguards+=("oifname \"$link\" ip daddr $XL4.128 $p dport $lspec ct status dnat ct original proto-dst $lspec $source_check counter accept")
            xguards+=("iifname \"$link\" ip6 saddr $XL6:46::/96 ct status dnat ct original ip6 daddr $alias ip6 daddr ${f_tip[idx]} $p dport $tspec counter accept")
            xpost+=("oifname \"$link\" fib saddr type local ct status dnat ip daddr $XL4.128 $p dport $lspec counter masquerade $cmt")
            xpost+=("iifname \"$link\" ip6 saddr $XL6:46::/96 ct status dnat ct original ip6 daddr $alias ip6 daddr ${f_tip[idx]} $p dport $tspec counter masquerade fully-random $cmt")
        done
    fi
}

translation_guards() {
    local mode link
    translation_needed || return 0
    translation_settings || return 1
    # These remain present even with no cross-family entries: stale internal
    # routes cannot become an open gateway after deleting the final entry.
    for mode in 64 46; do
        link="$XL_ID$mode"
        if translation_mode_needed "$mode"; then
            if [ "$mode" = 64 ]; then
                xguards+=("oifname \"$link\" ip6 daddr $XL6:64::/96 ct status dnat ct state established,related accept")
                xguards+=("oifname \"$link\" ip daddr $XL4.64 ct state established,related accept")
                xguards+=("iifname \"$link\" ip6 saddr $XL6:64::/96 ct state established,related accept")
            else
                xguards+=("oifname \"$link\" ip daddr $XL4.128 ct status dnat ct state established,related accept")
                xguards+=("oifname \"$link\" ip6 daddr $XL6:46::/96 ct state established,related accept")
                xguards+=("iifname \"$link\" ip saddr $XL4.128 ct state established,related accept")
            fi
        fi
        xguards+=("iifname \"$link\" counter drop" "oifname \"$link\" counter drop")
    done
    xguards+=("ip daddr $XL4.0/24 counter drop" "ip6 daddr $XL6::/48 counter drop"
        "ip saddr $XL4.0/24 counter drop" "ip6 saddr $XL6::/48 counter drop")
    # Run after OUTPUT's DNAT reroute and postrouting SNAT, when oif is final.
    output_guards+=("ip daddr $XL4.64 oifname != \"${XL_ID}64\" drop"
        "ip daddr $XL4.128 oifname != \"${XL_ID}46\" drop"
        "ip6 daddr $XL6:64::/96 oifname != \"${XL_ID}64\" drop"
        "ip6 daddr $XL6:46::/96 oifname != \"${XL_ID}46\" drop")
}

translation_netns() {
    local ns="$1"
    shift
    # The control tools need only the network namespace. ip -n / netns exec
    # also remount /sys, which SELinux initrc_t correctly refuses on RHEL.
    nsenter "--net=/run/netns/$ns" -- "$@"
}

translation_resource_owned() {
    local mode="$1"
    translation_netns "$XL_ID$mode" ip -d -o link show lo 2>/dev/null | grep -qF "alias nft.sh:$XL_ID:$mode"
}

translation_version_supported() {
    [[ "$1" =~ ^4\.1\.([0-9]+)(\.[0-9]+)?$ ]] && [ "$((10#${BASH_REMATCH[1]}))" -ge 15 ]
}

translation_precheck() {
    local tool mode route prefix other value ls le tip ts te family af
    translation_settings "$TRANSLATE_DEPLOY" || { error '错误: 内核转换部署配置无效'; return 1; }
    if [ -L "$SYSTEMD_DIR/nft-sh-translate.service" ] || [ -L "$LIBEXEC_DIR/nft.sh" ]; then
        error '受管服务或脚本路径为符号链接，已拒绝覆盖'; return 1
    fi
    if [ -f "$SYSTEMD_DIR/nft-sh-translate.service" ] &&
        ! grep -qF '# Managed by nft.sh: kernel translation' "$SYSTEMD_DIR/nft-sh-translate.service"; then
        error '同名 systemd 单元不属于本项目，已拒绝覆盖'; return 1
    fi
    if [ -f "$LIBEXEC_DIR/nft.sh" ] && ! grep -qF '# NFTables 白名单防火墙' "$LIBEXEC_DIR/nft.sh"; then
        error '同名恢复脚本不属于本项目，已拒绝覆盖'; return 1
    fi
    if [ -f "$TRANSLATE_DIR/live.deployment" ] &&
        ! cmp -s <(printf 'id=%s\nipv4=%s\nipv6=%s\n' "$XL_ID" "$XL4" "$XL6") "$TRANSLATE_DIR/live.deployment"; then
        error '转换资源仍在使用旧部署参数；请先删除跨族规则，再修改部署参数'
        return 1
    fi
    for tool in ip ss nsenter jool modprobe modinfo; do
        command -v "$tool" >/dev/null || { error "跨族转发需要 $tool（Jool 工具和匹配的内核模块）"; return 1; }
    done
    modprobe -n jool >/dev/null 2>&1 || { error "当前内核 $(uname -r) 没有可用 Jool 模块，请安装匹配的 DKMS/headers"; return 1; }
    value=$(jool --version) || return 1
    translation_version_supported "$value" && [ "$value" = "$(modinfo -F version jool)" ] || {
        error '需要 Jool 4.1.15 或更新的 4.1 版本，且工具和模块版本一致；旧版未通过低 MTU UDP 验收'; return 1;
    }
    if [ -f /sys/module/jool/version ] && [ "$value" != "$(cat /sys/module/jool/version)" ]; then
        error '已加载的 Jool 模块与工具版本不同，请先安排模块升级再使用跨族转发'; return 1
    fi
    for mode in 64 46; do
        if ip netns list | awk '{print $1}' | grep -qxF "$XL_ID$mode"; then
            translation_resource_owned "$mode" || { error "namespace $XL_ID$mode 不属于本项目"; return 1; }
        fi
        if ip link show "$XL_ID$mode" >/dev/null 2>&1; then
            ip -d -o link show "$XL_ID$mode" | grep -qF "alias nft.sh:$XL_ID:$mode" || {
                error "接口 $XL_ID$mode 不属于本项目"; return 1;
            }
        fi
    done
    while read -r ls le tip ts te family; do
        af=4; [[ "$tip" != *:* ]] || af=6
        if { [ "$af" = 4 ] && ip_in_cidr "$tip" "$XL4.0/24"; } ||
            { [ "$af" = 6 ] && ip_in_cidr "$tip" "$XL6::/48"; }; then
            error "目标 $tip 落入本项目内部转换网段，已拒绝"; return 1
        fi
        if [[ "$family" = ipv6 && "$af" = 4 ]] || [[ "$family" = ipv4 && "$af" = 6 ]]; then
            route=$(ip "-$af" route get "$tip" 2>/dev/null) || { error "目标 $tip 没有可用路由"; return 1; }
            [[ "$route" != local\ * ]] || { error "跨族目标必须是其他主机的可达地址: $tip"; return 1; }
        fi
    done < <(list_forwards)
    # Ignore our own connected/return routes; reject overlapping external routes.
    for other in 4 6; do
        while IFS= read -r route; do
            [[ " $route " != *" dev ${XL_ID}64 "* && " $route " != *" dev ${XL_ID}46 "* ]] || continue
            read -r prefix value _ <<< "$route"
            case "$prefix" in default) continue ;; local|broadcast|unreachable|blackhole|throw) prefix="$value" ;; esac
            prefix=$(normalize_ip_entry "$prefix" 2>/dev/null) || continue
            [[ "$prefix" != */0 ]] || continue
            if [ "$other" = 4 ]; then value="$XL4.0/24"; else value="$XL6::/48"; fi
            if ip_in_cidr "${value%%/*}" "$prefix" || ip_in_cidr "${prefix%%/*}" "$value"; then
                error "转换网段 $value 与已有路由 $prefix 冲突，请更换部署参数"; return 1
            fi
        done < <(ip "-$other" route show table all)
    done
}

translation_remove() {
    local mode rc=0
    local XL_ID XL4 XL6
    if [ -f "$TRANSLATE_DIR/live.deployment" ]; then
        translation_settings "$TRANSLATE_DIR/live.deployment" || return 1
    else translation_settings || return 1; fi
    command -v ip >/dev/null || return 0
    for mode in 64 46; do
        # Cut the link while the namespace still has its bind mount. Deleting
        # the namespace first races the kernel's asynchronous peer destruction.
        if ip -d -o link show "$XL_ID$mode" 2>/dev/null | grep -qF "alias nft.sh:$XL_ID:$mode"; then
            if ! ip link del "$XL_ID$mode" 2>/dev/null && ip link show "$XL_ID$mode" >/dev/null 2>&1; then rc=1; fi
        fi
        if translation_resource_owned "$mode"; then
            if command -v jool >/dev/null; then
                translation_netns "$XL_ID$mode" jool instance remove nft-sh >/dev/null 2>&1 || true
            fi
            ip netns del "$XL_ID$mode" || rc=1
        fi
    done
    return "$rc"
}

translation_json() {
    local mode="$1" proto ls le tip ts te family port comma="" pool alias port_range
    if [ "$mode" = 64 ]; then pool="$XL4.64"; else pool="$XL4.128"; fi
    printf '{"instance":"nft-sh","framework":"netfilter","global":{"pool6":"%s:%s::/96","address-dependent-filtering":%s,"drop-externally-initiated-tcp":false,"ss-enabled":false},"pool4":[' "$XL6" "$mode" "$([ "$mode" = 64 ] && echo true || echo false)"
    for proto in TCP UDP ICMP; do
        port_range=1-65535; [ "$proto" != ICMP ] || port_range=0-65535
        printf '%s{"protocol":"%s","prefix":"%s/32","port range":"%s"}' "$comma" "$proto" "$pool" "$port_range"
        comma=,
    done
    printf '],"bib":['
    comma=""
    if [ "$mode" = 46 ]; then
        while read -r ls le tip ts te family; do
            [[ "$family" = ipv4 && "$tip" == *:* ]] || continue
            printf -v alias '%s:a46::%x' "$XL6" "$ls"
            for ((port = ls; port <= le; port++)); do
                for proto in TCP UDP; do
                    printf '%s{"protocol":"%s","ipv4 address":"%s#%s","ipv6 address":"%s#%s"}' "$comma" "$proto" "$pool" "$port" "$alias" "$((ts + port - ls))"
                    comma=,
                done
            done
        done < <(list_forwards)
    fi
    printf ']}\n'
}

translation_setup() {
    local mode ns link host4 peer4 host6 peer6 pool4 pool6 offset config sockets
    translation_settings || return 1
    translation_remove || return 1
    translation_needed || return 0
    modprobe jool || return 1
    for mode in 64 46; do
        translation_mode_needed "$mode" || continue
        ns="$XL_ID$mode"; link="$ns"
        if [ "$mode" = 64 ]; then offset=1; pool4="$XL4.64"; else offset=5; pool4="$XL4.128"; fi
        host4="$XL4.$offset"; peer4="$XL4.$((offset + 1))"
        host6="$XL6:$([ "$mode" = 64 ] && echo 1 || echo 2)::1"
        peer6="${host6%1}2"; pool6="$XL6:$mode::/96"
        ip netns add "$ns" && translation_netns "$ns" ip link set lo alias "nft.sh:$XL_ID:$mode" || return 1
        ip link add "$link" type veth peer name peer && ip link set "$link" alias "nft.sh:$XL_ID:$mode" || return 1
        ip link set peer netns "$ns" && sysctl -qw "net/ipv6/conf/$link/accept_dad=0" &&
            translation_netns "$ns" sysctl -qw net/ipv6/conf/peer/accept_dad=0 && ip addr add "$host4/30" dev "$link" &&
            ip -6 addr add "$host6/64" dev "$link" nodad && ip link set "$link" up || return 1
        translation_netns "$ns" ip addr add "$peer4/30" dev peer && translation_netns "$ns" ip -6 addr add "$peer6/64" dev peer nodad &&
            translation_netns "$ns" ip link set peer up && translation_netns "$ns" ip link set lo up || return 1
        translation_netns "$ns" ip route add default via "$host4" && translation_netns "$ns" ip -6 route add default via "$host6" || return 1
        translation_netns "$ns" sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1 || return 1
        printf 'table inet untranslated_guard {\n chain forward { type filter hook forward priority filter; policy drop; }\n}\n' |
            translation_netns "$ns" nft -f - || return 1
        # Always create a fresh instance: Jool file updates ignore the bib tag.
        config=$(mktemp) || return 1
        # These private pool addresses are not assigned to interfaces, and this
        # dedicated namespace has no TCP/UDP sockets. Acknowledge Jool 4.1.15's
        # ephemeral-port overlap warning here, never in the host namespace.
        sockets=$(translation_netns "$ns" ss -Han -t -u) || { rm -f "$config"; return 1; }
        if [ -n "$sockets" ]; then
            error "转换 namespace $ns 出现未预期的 TCP/UDP socket"; rm -f "$config"; return 1
        fi
        if ! translation_json "$mode" > "$config" || ! translation_netns "$ns" jool file handle "$config" --force; then
            rm -f "$config"; return 1
        fi
        rm -f "$config"
        ip route add "$pool4/32" via "$peer4" dev "$link" &&
            ip -6 route add "$pool6" via "$peer6" dev "$link" || return 1
    done
}

translation_guard_close() {
    local rules old_id="" links
    translation_settings || return 1
    links="\"${XL_ID}64\", \"${XL_ID}46\""
    if [ -f "$TRANSLATE_DIR/live.deployment" ]; then
        old_id=$(translation_settings "$TRANSLATE_DIR/live.deployment" && printf '%s' "$XL_ID") || return 1
        if [ "$old_id" != "$XL_ID" ]; then links+=", \"${old_id}64\", \"${old_id}46\""; fi
    fi
    if nft list table inet nft_sh_transition >/dev/null 2>&1; then
        nft list table inet nft_sh_transition | grep -qF 'nft.sh transition guard' || return 1
    fi
    rules="add table inet nft_sh_transition
delete table inet nft_sh_transition
table inet nft_sh_transition {
 comment \"nft.sh transition guard\"
 chain forward { type filter hook forward priority -5; policy accept;
 iifname { $links } drop
 oifname { $links } drop
 }
}"
    printf '%s\n' "$rules" | nft -f -
}

translation_guard_open() {
    if nft list table inet nft_sh_transition 2>/dev/null | grep -qF 'nft.sh transition guard'; then
        nft delete table inet nft_sh_transition || return 1
    fi
    return 0
}

managed_forwarding_sysctl() {
    local key="$1"
    case "$key" in
        net/ipv4/ip_forward) return 0 ;;
        net/ipv6/conf/*/*)
            case "${key##*/}" in forwarding|force_forwarding|accept_ra|accept_redirects) return 0 ;; esac ;;
        net/ipv4/conf/*/*)
            case "${key##*/}" in
                forwarding|accept_redirects|send_redirects|secure_redirects|accept_source_route|rp_filter|shared_media|route_localnet|accept_local|proxy_arp|proxy_arp_pvlan|bootp_relay|log_martians|arp_filter|arp_ignore|arp_announce|arp_accept|medium_id|src_valid_mark|promote_secondaries) return 0 ;;
            esac ;;
    esac
    return 1
}

snapshot_sysctls() {
    local file value
    : > "$1/sysctls"
    for file in /proc/sys/net/ipv4/ip_forward /proc/sys/net/ipv{4,6}/conf/*/*; do
        [ -f "$file" ] || continue
        managed_forwarding_sysctl "${file#/proc/sys/}" || continue
        { IFS= read -r value < "$file"; } 2>/dev/null || continue
        [[ "$value" =~ ^-?[0-9]+$ ]] || continue
        printf '%s %s\n' "${file#/proc/sys/}" "$value" >> "$1/sysctls"
    done
}

restore_sysctls() {
    local key value current rc=0
    [ -f "$1/sysctls" ] || return 0
    while read -r key value; do
        [[ "$key" == net/ipv4/* || "$key" == net/ipv6/* ]] || return 1
        [[ "$key" != *..* && "$value" =~ ^-?[0-9]+$ ]] || return 1
        # Older snapshots also recorded read-only/dynamic fields such as
        # ifindex. Restore only forwarding-related configuration we manage.
        managed_forwarding_sysctl "$key" || continue
        [ -f "/proc/sys/$key" ] || continue
        { IFS= read -r current < "/proc/sys/$key"; } 2>/dev/null || continue
        [ "$current" = "$value" ] || sysctl -qw "$key=$value" || rc=1
    done < "$1/sysctls"
    return "$rc"
}

persist_forward_value() {
    local key="$1" value="$2" tmp source=/dev/null
    mkdir -p "$(dirname "$SYSCTL_FILE")" || return 1
    [ ! -f "$SYSCTL_FILE" ] || source="$SYSCTL_FILE"
    tmp=$(mktemp "$(dirname "$SYSCTL_FILE")/.nft-forward.XXXXXX") || return 1
    if ! awk -v key="$key" -v value="$value" '{
        split($0,a,"="); gsub(/[[:space:]]/,"",a[1]); if(a[1]!=key) print
    } END { print key " = " value }' "$source" > "$tmp" || ! mv -f "$tmp" "$SYSCTL_FILE"; then
        rm -f "$tmp"; return 1
    fi
}

ensure_ipv6_forward() {
    local iface key value
    command -v ip >/dev/null || { error 'IPv6 转发需要 iproute2，以检查和保留上联 RA'; return 1; }
    # Preserve RA on the actual uplinks before switching them to router mode.
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        [[ "$iface" != *'/'* && "$iface" != *..* ]] || return 1
        key="net/ipv6/conf/$iface/accept_ra"
        value=$(cat "/proc/sys/$key" 2>/dev/null)
        if [ "$value" = 1 ] || [ "$value" = 2 ]; then
            [ "$value" = 2 ] || sysctl -qw "$key=2" || return 1
            persist_forward_value "$key" 2 || return 1
        fi
    done < <(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="dev")print $(i+1)}' | sort -u)
    [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" = 1 ] || sysctl -qw net.ipv6.conf.all.forwarding=1 || return 1
    persist_forward_value net.ipv6.conf.all.forwarding 1
}

ensure_runtime_forwarding() {
    local ls le tip ts te family need4=0 need6=0
    while read -r ls le tip ts te family; do
        if [[ "$family" = ipv4 || "$tip" != *:* ]]; then need4=1; fi
        if [[ "$family" = ipv6 || "$tip" == *:* ]]; then need6=1; fi
    done < <(list_forwards)
    if [ "$need4" = 1 ]; then
        ensure_ip_forward || return 1
        if ip_forward_enabled; then persist_forward_value net.ipv4.ip_forward 1 || return 1
        elif translation_needed; then error '跨族转发需要启用 IPv4 forwarding，已取消应用'; return 1; fi
    fi
    if [ "$need6" = 1 ]; then ensure_ipv6_forward || { error '启用 IPv6 转发失败'; return 1; }; fi
    return 0
}

translation_current() {
    local mode proto live
    [ -f "$TRANSLATE_DIR/live.forward" ] && cmp -s "$FORWARD_FILE" "$TRANSLATE_DIR/live.forward" || return 1
    translation_settings || return 1
    for mode in 64 46; do
        translation_mode_needed "$mode" || continue
        translation_resource_owned "$mode" || return 1
        translation_netns "$XL_ID$mode" jool -i nft-sh global display --csv 2>/dev/null | grep -qx 'manually-enabled,TRUE' || return 1
        if [ "$mode" = 64 ]; then
            ip -4 route show "$XL4.64/32" | grep -qF "dev $XL_ID$mode" || return 1
        else
            ip -4 route show "$XL4.128/32" | grep -qF "dev $XL_ID$mode" || return 1
        fi
        ip -6 route show "$XL6:$mode::/96" | grep -qF "dev $XL_ID$mode" || return 1
        live=$(translation_pool_state "$mode") || return 1
        [ -f "$TRANSLATE_DIR/live.pool$mode" ] && [ "$live" = "$(cat "$TRANSLATE_DIR/live.pool$mode")" ] || return 1
        if [ "$mode" = 46 ]; then
            for proto in tcp udp; do
                live=$(set -o pipefail; translation_netns "$XL_ID$mode" jool -i nft-sh bib display "--$proto" --numeric --csv --no-headers | LC_ALL=C sort) || return 1
                [ "$live" = "$(cat "$TRANSLATE_DIR/live.$proto" 2>/dev/null)" ] || return 1
            done
        fi
    done
}

translation_pool_state() {
    local proto
    for proto in tcp udp icmp; do
        printf '%s\n' "$proto"
        translation_netns "$XL_ID$1" jool -i nft-sh pool4 display "--$proto" --csv --no-headers || return 1
    done
}

translation_record() {
    local proto mode
    translation_settings || return 1
    mkdir -p "$TRANSLATE_DIR" || return 1
    chmod 700 "$TRANSLATE_DIR" || return 1
    printf 'id=%s\nipv4=%s\nipv6=%s\n' "$XL_ID" "$XL4" "$XL6" > "$TRANSLATE_DEPLOY" || return 1
    if [ "$TRANSLATE_DEPLOY" != "$TRANSLATE_DIR/live.deployment" ]; then
        cp "$TRANSLATE_DEPLOY" "$TRANSLATE_DIR/live.deployment" || return 1
    fi
    if [ "$FORWARD_FILE" != "$TRANSLATE_DIR/live.forward" ]; then
        cp "$FORWARD_FILE" "$TRANSLATE_DIR/live.forward" || return 1
    fi
    for mode in 64 46; do
        if translation_mode_needed "$mode"; then
            translation_pool_state "$mode" > "$TRANSLATE_DIR/live.pool$mode" || return 1
        else rm -f "$TRANSLATE_DIR/live.pool$mode"; fi
    done
    if translation_mode_needed 46; then
        for proto in tcp udp; do
            (set -o pipefail; translation_netns "${XL_ID}46" jool -i nft-sh bib display "--$proto" --numeric --csv --no-headers | LC_ALL=C sort) > "$TRANSLATE_DIR/live.$proto" || return 1
        done
    else
        rm -f "$TRANSLATE_DIR/live.tcp" "$TRANSLATE_DIR/live.udp"
    fi
}

translation_persist() {
    local key value path
    # A test/network namespace must not install a service in the host's systemd.
    [ "$(readlink /proc/self/ns/net)" = "$(readlink /proc/1/ns/net)" ] || return 0
    command -v systemctl >/dev/null || { error '跨族开机恢复需要 systemd oneshot'; return 1; }
    for path in "$LIBEXEC_DIR" "$SYSTEMD_DIR" "$TRANSLATE_DIR" "$WHITELIST_FILE" "$FORWARD_FILE" "$WHITELIST_ENABLED_FILE" "$NFT_PERSIST_DIR" "$SYSCTL_FILE"; do
        [[ "$path" =~ ^/[a-zA-Z0-9_./-]+$ && "$path" != *..* ]] || { error '开机恢复路径含不支持的字符'; return 1; }
    done
    mkdir -p "$LIBEXEC_DIR" "$SYSTEMD_DIR" || return 1
    if [ "$SCRIPT_PATH" != "$(readlink -f "$LIBEXEC_DIR/nft.sh" 2>/dev/null)" ]; then
        cp "$SCRIPT_PATH" "$LIBEXEC_DIR/nft.sh" || return 1
    fi
    chmod 700 "$LIBEXEC_DIR/nft.sh" || return 1
    : > "$TRANSLATE_DIR/service.env" || return 1
    for key in WHITELIST_FILE FORWARD_FILE ENABLED_FILE PERSIST_DIR SYSCTL_FILE TRANSLATE_DIR LIBEXEC_DIR SYSTEMD_DIR; do
        case "$key" in
            ENABLED_FILE) value="$WHITELIST_ENABLED_FILE" ;;
            PERSIST_DIR) value="$NFT_PERSIST_DIR" ;;
            *) value="${!key}" ;;
        esac
        printf 'NFT_SH_%s=%s\n' "$key" "$value" >> "$TRANSLATE_DIR/service.env" || return 1
    done
    cat > "$SYSTEMD_DIR/nft-sh-translate.service" <<EOF
# Managed by nft.sh: kernel translation, no userspace relay.
[Unit]
Description=nft.sh kernel IPv4/IPv6 translation
After=nftables.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=$TRANSLATE_DIR/service.env
ExecStart=/bin/bash $LIBEXEC_DIR/nft.sh __translate_boot
ExecStop=/bin/bash $LIBEXEC_DIR/nft.sh __translate_stop
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable nft-sh-translate.service
}

translation_boot() {
    [ "$EUID" -eq 0 ] || return 1
    # Restore only the last confirmed generation, not un-applied file edits.
    local FORWARD_FILE="$TRANSLATE_DIR/live.forward" TRANSLATE_DEPLOY="$TRANSLATE_DIR/live.deployment"
    [ -f "$FORWARD_FILE" ] && [ -f "$TRANSLATE_DEPLOY" ] || return 1
    translation_needed || return 0
    if translation_current && nft_table_exists "$NFT_TABLE"; then return 0; fi
    # Load this project's file only. Starting the system's nftables.service here
    # could execute its flush-ruleset and erase Docker/other live tables.
    translation_guard_close && translation_precheck &&
        (set -o pipefail; cat "$NFT_PERSIST_FILE" | nft -f -) &&
        translation_setup && translation_record && translation_guard_open
}

translation_status() {
    local mode prefix
    translation_needed || return 0
    translation_settings || return 1
    echo '跨族后端: Jool 内核转换（无常驻用户态中继）'
    printf '  工具: %s；已加载模块: %s\n' "$(jool --version 2>/dev/null || echo 不可用)" "$(cat /sys/module/jool/version 2>/dev/null || echo 未加载)"
    for mode in 64 46; do
        translation_mode_needed "$mode" || continue
        prefix="$XL_ID$mode"
        if translation_resource_owned "$mode" && translation_netns "$prefix" jool -i nft-sh global display --csv 2>/dev/null | grep -qx 'manually-enabled,TRUE'; then
            echo "  $mode: $prefix 已启用，转换前缀 $XL6:$mode::/96"
            if [ "$mode" = 64 ]; then echo "    动态 IPv4 池: $XL4.64"
            else echo "    静态 IPv4 池: $XL4.128"; fi
            translation_pool_state "$mode" 2>/dev/null
            if [ "$mode" = 46 ]; then
                translation_netns "$prefix" jool -i nft-sh bib display --tcp --numeric --csv 2>/dev/null
                translation_netns "$prefix" jool -i nft-sh bib display --udp --numeric --csv 2>/dev/null
            fi
        else
            echo "  $mode: $prefix 未就绪（模块、实例或权限异常）"
        fi
    done
    translation_current || warn '声明与运行状态不一致，请检查后重新 apply'
}

print_plan() {
    local mode offset pool
    show_forwards
    build_ruleset || return 1
    if translation_needed; then
        translation_settings || return 1
        printf '\n# Jool deployment: %s, IPv4 %s.0/24, IPv6 %s::/48\n' "$XL_ID" "$XL4" "$XL6"
        for mode in 64 46; do
            translation_mode_needed "$mode" || continue
            printf '# namespace %s%s; pool6 %s:%s::/96\n' "$XL_ID" "$mode" "$XL6" "$mode"
            if [ "$mode" = 64 ]; then offset=1; pool=64; else offset=5; pool=128; fi
            printf '# veth %s%s: host %s.%s/30 -> peer %s.%s/30\n' "$XL_ID" "$mode" "$XL4" "$offset" "$XL4" "$((offset + 1))"
            printf '# veth IPv6: host %s:%s::1/64 -> peer %s:%s::2/64\n' "$XL6" "$([ "$mode" = 64 ] && echo 1 || echo 2)" "$XL6" "$([ "$mode" = 64 ] && echo 1 || echo 2)"
            printf '# host routes: %s.%s/32 and %s:%s::/96 via the namespace peer\n' "$XL4" "$pool" "$XL6" "$mode"
            translation_json "$mode" || return 1
        done
        echo '# Requires matching Jool >= 4.1.15 (4.1 series) tools/module, namespace/veth, both IP families and routes.'
        echo '# sysctl: net.ipv4.ip_forward=1; net.ipv6.conf.all.forwarding=1 (host and namespaces).'
        echo '# Uplink accept_ra=1 is changed to 2 and persisted before enabling IPv6 forwarding.'
    fi
}

finish_action_guard() {
    [ "$ROLLBACK_PENDING" = 1 ] && [ -d "$SNAPSHOT_DIR" ] || return 0
    if mkdir "$SNAPSHOT_DIR/decision" 2>/dev/null; then : > "$SNAPSHOT_DIR/confirmed"; fi
    : > "$SNAPSHOT_DIR/completed"
}

translation_uninstall() {
    translation_guard_close && translation_remove || return 1
    if [ "$(readlink /proc/self/ns/net)" = "$(readlink /proc/1/ns/net)" ] && command -v systemctl >/dev/null; then
        systemctl stop nft-sh-translate.service >/dev/null 2>&1 || true
        systemctl disable nft-sh-translate.service >/dev/null 2>&1 || true
    fi
    rm -f "$TRANSLATE_DIR/live.forward" "$TRANSLATE_DIR/live.tcp" "$TRANSLATE_DIR/live.udp" \
        "$TRANSLATE_DIR/live.pool64" "$TRANSLATE_DIR/live.pool46" \
        "$TRANSLATE_DIR/live.deployment" "$TRANSLATE_DIR/service.env" "$SYSTEMD_DIR/nft-sh-translate.service"
    if [ "$(readlink /proc/self/ns/net)" = "$(readlink /proc/1/ns/net)" ] && command -v systemctl >/dev/null; then
        systemctl daemon-reload || return 1
    fi
    translation_guard_open
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
    local e i proto lspec tspec target cmt line policy="accept" family af addr_af host loopback
    local ls le tip ts te
    local -a v4=() v6=() f_ls=() f_le=() f_tip=() f_ts=() f_te=() f_map=() f_family=()
    local -a pre=() outp=() post=() xpost=() in_rules=() fw_rules=() xguards=() output_guards=()

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

    while read -r ls le tip ts te family; do
        f_ls+=("$ls"); f_le+=("$le"); f_tip+=("$tip"); f_ts+=("$ts"); f_te+=("$te")
        f_family+=("$family")
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
        if [[ "${f_family[i]}" = ipv4 && "${f_tip[i]}" == *:* ]]; then continue; fi
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
        family="${f_family[i]}"
        af="ipv4"; [[ "${f_tip[i]}" != *:* ]] || af="ipv6"
        if [ "$af" != "$family" ]; then
            build_translation_rules "$i" || return 1
            continue
        fi
        addr_af="ip"; host="${f_tip[i]}"; loopback="127.0.0.0/8"
        if [ "$family" = "ipv6" ]; then addr_af="ip6"; host="[${f_tip[i]}]"; loopback="::1"; fi
        for proto in tcp udp; do
            if [ "${f_ls[i]}" -eq "${f_le[i]}" ]; then
                target="$host:${f_ts[i]}"
            elif [ -z "${f_map[i]}" ]; then
                target="${f_tip[i]}"        # 端口段号码相同：不写端口，保持原端口
            else
                target="$host : $proto dport map @${f_map[i]}"
            fi
            # 只转发发往本机地址的流量，不会劫持容器 / VPN 客户端经过本机访问外网的流量
            pre+=("meta nfproto $family fib daddr type local $proto dport $lspec counter dnat $addr_af to $target $cmt")
            # 本机访问自己的转发端口同样生效；本机访问其他服务器的同号端口不受影响
            outp+=("$addr_af daddr != $loopback fib daddr type local $proto dport $lspec counter dnat $addr_af to $target $cmt")
            # 只对 DNAT 过的连接做 masquerade，保证目标服务器的回包经过本机
            post+=("ct status dnat $addr_af daddr ${f_tip[i]} $proto dport $tspec counter masquerade $cmt")
        done
    done

    translation_guards || return 1
    emit_chain prerouting "type nat hook prerouting priority dstnat; policy accept;" "${pre[@]}"
    emit_chain output_nat "type nat hook output priority -100; policy accept;" "${outp[@]}"
    # Specific translation SNAT must precede native rules for shared targets.
    emit_chain postrouting "type nat hook postrouting priority srcnat; policy accept;" "${xpost[@]}" "${post[@]}"
    if [ "${#output_guards[@]}" -gt 0 ]; then
        emit_chain translation_route_guard "type filter hook postrouting priority 110; policy accept;" "${output_guards[@]}"
    fi

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
    emit_chain forward "type filter hook forward priority filter; policy accept;" "${xguards[@]}" "${fw_rules[@]}"
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
    local i=0 f t pending lockfile="${NFT_SH_LOCK_FILE:-$FORWARD_FILE.lock}"
    end_action
    command -v flock >/dev/null || { error '需要 util-linux 的 flock 防止并发修改'; return 1; }
    exec {ACTION_LOCK_FD}<> "$lockfile" || return 1
    if ! flock -n "$ACTION_LOCK_FD"; then
        error '另一项配置操作正在进行，请稍后重试'
        exec {ACTION_LOCK_FD}>&-
        ACTION_LOCK_FD=""
        return 1
    fi
    # A disconnected foreground releases its descriptor before its independent
    # guard runs. Keep the pending snapshot in the stable lock inode so a new
    # transaction cannot be overwritten later by the older guard.
    pending=$(head -n 1 "$lockfile")
    case "$pending" in
        */nft-sh.*)
            if [ -d "$pending" ] && [ ! -e "$pending/completed" ]; then
                error '前一次配置仍在等待确认或回滚，请稍后重试'
                release_action_lock
                return 1
            fi ;;
    esac
    CONFIRM_ALWAYS=0
    SNAPSHOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nft-sh.XXXXXX") || {
        SNAPSHOT_DIR=""
        return 1
    }
    for f in "$WHITELIST_FILE" "$FORWARD_FILE" "$WHITELIST_ENABLED_FILE" "$SYSCTL_FILE" \
        "$NFT_PERSIST_FILE" "$(detect_nft_main_conf)" "$TRANSLATE_DEPLOY" \
        "$TRANSLATE_DIR/live.forward" "$TRANSLATE_DIR/live.tcp" "$TRANSLATE_DIR/live.udp" "$TRANSLATE_DIR/live.deployment" \
        "$TRANSLATE_DIR/live.pool64" "$TRANSLATE_DIR/live.pool46" \
        "$TRANSLATE_DIR/service.env" "$SYSTEMD_DIR/nft-sh-translate.service" "$LIBEXEC_DIR/nft.sh"; do
        i=$((i + 1))
        printf '%s\n' "$f" > "$SNAPSHOT_DIR/cfg.$i.path" || { end_action; return 1; }
        if [ -f "$f" ]; then
            cp -p "$f" "$SNAPSHOT_DIR/cfg.$i" || { end_action; return 1; }
        else
            : > "$SNAPSHOT_DIR/cfg.$i"
            : > "$SNAPSHOT_DIR/cfg.$i.missing"
        fi
    done
    {
        for t in "$NFT_TABLE" "${LEGACY_TABLES[@]}"; do
            echo "add table inet $t"
            echo "delete table inet $t"
            if nft list table inet "$t" 2>/dev/null; then
                [ "$t" != "$NFT_TABLE" ] || : > "$SNAPSHOT_DIR/had_table"
            fi
        done
    } > "$SNAPSHOT_DIR/live.nft"
    snapshot_sysctls "$SNAPSHOT_DIR"
    if [ -f "$TRANSLATE_DIR/live.forward" ]; then
        translation_settings "$TRANSLATE_DIR/live.deployment" || return 1
        if translation_resource_owned 64 || translation_resource_owned 46; then
            : > "$SNAPSHOT_DIR/had_translation"
            cp "$TRANSLATE_DIR/live.forward" "$SNAPSHOT_DIR/running.forward" || return 1
        fi
        translation_settings || return 1
    fi
    if [ "$(readlink /proc/self/ns/net 2>/dev/null)" = "$(readlink /proc/1/ns/net 2>/dev/null)" ] && command -v systemctl >/dev/null; then
        systemctl is-enabled --quiet nft-sh-translate.service 2>/dev/null && : > "$SNAPSHOT_DIR/unit.enabled"
        systemctl is-active --quiet nft-sh-translate.service 2>/dev/null && : > "$SNAPSHOT_DIR/unit.active"
    fi
    return 0
}

release_action_lock() {
    if [ -n "${ACTION_LOCK_FD:-}" ]; then exec {ACTION_LOCK_FD}>&-; ACTION_LOCK_FD=""; fi
}

end_action() {
    if [ -n "$SNAPSHOT_DIR" ]; then
        if [ "$ROLLBACK_PENDING" -ne 1 ] ||
            { [ -e "$SNAPSHOT_DIR/completed" ] && [ -e "$SNAPSHOT_DIR/guard_finished" ]; }; then
            remove_snapshot_dir "$SNAPSHOT_DIR"
        fi
    fi
    SNAPSHOT_DIR=""
    ROLLBACK_PENDING=0
    release_action_lock
}

# 把配置文件恢复成快照里的内容
restore_config_files() {
    local snap="$1" p target rc=0
    [ -n "$snap" ] && [ -d "$snap" ] || return 1
    for p in "$snap"/cfg.*.path; do
        [ -f "$p" ] || continue
        target=$(head -n 1 "$p")
        [ -n "$target" ] || continue
        if [ -e "${p%.path}.missing" ]; then
            rm -f -- "$target" || rc=1
        else
            cat "${p%.path}" > "$target" || rc=1
        fi
    done
    return "$rc"
}

# 恢复快照：实时规则 + 配置文件。旧规则恢复失败时删除本脚本的表，保证不会把人锁在外面
restore_snapshot() {
    local snap="$1" rc=0
    if [ -e "$snap/translation.changed" ]; then
        translation_guard_close || rc=1
        translation_remove || rc=1
        if [ ! -e "$snap/unit.active" ] && [ "$(readlink /proc/self/ns/net)" = "$(readlink /proc/1/ns/net)" ]; then
            systemctl stop nft-sh-translate.service >/dev/null 2>&1 || true
        fi
    fi
    restore_config_files "$snap" || rc=1
    if [ -e "$snap/translation.changed" ] && [ -e "$snap/had_translation" ]; then
        # The desired file might have been edited manually before apply. Rebuild
        # the last running declaration, not that un-applied desired file.
        local FORWARD_FILE="$snap/running.forward"
        local TRANSLATE_DEPLOY="$TRANSLATE_DIR/live.deployment"
        translation_setup || rc=1
    fi
    # RHEL 的 SELinux 域可能禁止 nft 直接读取 user_tmp_t；由 shell 读取后经管道传入。
    if ! (set -o pipefail; cat "$snap/live.nft" | nft -f -) 2>/dev/null; then
        nft delete table inet "$NFT_TABLE" 2>/dev/null
        rc=1
    fi
    restore_sysctls "$snap" || rc=1
    if [ -e "$snap/translation.changed" ]; then
        if [ "$(readlink /proc/self/ns/net)" = "$(readlink /proc/1/ns/net)" ] && command -v systemctl >/dev/null; then
            systemctl daemon-reload >/dev/null 2>&1 || rc=1
            if [ -e "$snap/unit.enabled" ]; then
                systemctl enable nft-sh-translate.service >/dev/null 2>&1 || rc=1
            else
                systemctl disable nft-sh-translate.service >/dev/null 2>&1 || true
            fi
        fi
        if [ "$rc" -eq 0 ]; then translation_guard_open || rc=1; fi
    fi
    return $rc
}

save_rollback_context() {
    local key
    for key in "${ROLLBACK_CONTEXT_KEYS[@]}"; do
        printf '%s\0%s\0' "$key" "${!key-}" || return 1
    done > "$1/context"
}

load_rollback_context() {
    local key value
    local -A values=()
    [ -f "$1/context" ] || return 0
    while IFS= read -r -d '' key; do
        IFS= read -r -d '' value || return 1
        case "$key" in
            WHITELIST_FILE|FORWARD_FILE|WHITELIST_ENABLED_FILE|NFT_TABLE|NFT_PERSIST_DIR|NFT_PERSIST_FILE|NFT_INCLUDE_LINE|NFT_MAIN_CONF|SYSCTL_FILE|TRANSLATE_DIR|TRANSLATE_DEPLOY|LIBEXEC_DIR|SYSTEMD_DIR|NFT_SH_LOCK_FILE|NFT_SH_XLATE_ID|NFT_SH_XLATE_V4|NFT_SH_XLATE_V6) ;;
            *) return 1 ;;
        esac
        [ -z "${values[$key]+present}" ] || return 1
        values[$key]="$value"
    done < "$1/context"
    [ -z "$key" ] || return 1
    [ "${#values[@]}" -eq "${#ROLLBACK_CONTEXT_KEYS[@]}" ] || return 1
    for key in "${ROLLBACK_CONTEXT_KEYS[@]}"; do
        printf -v "$key" '%s' "${values[$key]}" || return 1
    done
}

# 在独立于当前 SSH 会话的后台安排回滚：即使连接断开、脚本被终止，也会按时回滚
schedule_rollback_guard() {
    local snap="$1" delay="$2" self="$1/nft.sh"
    # systemd-run does not inherit shell configuration. Store only known data
    # fields, including first-deployment parameters not yet persisted to disk.
    save_rollback_context "$snap" || return 1
    if [ ! -f "$SCRIPT_PATH" ] || ! cp -f "$SCRIPT_PATH" "$self" 2>/dev/null || [ ! -s "$self" ]; then
        return 1
    fi
    # systemd-run 默认回到宿主机的网络命名空间；隔离环境中必须使用 setsid 保留当前空间。
    if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ] &&
        [ "$(readlink /proc/self/ns/net)" = "$(readlink /proc/1/ns/net)" ] &&
        systemd-run --quiet --collect --unit="nft-sh-rollback-$$-$RANDOM" --on-active="$delay" \
            --timer-property=AccuracySec=1s --timer-property=RemainAfterElapse=no \
            /bin/bash "$self" __rollback_guard "$snap" 0 >/dev/null 2>&1; then
        return 0
    fi
    if command -v setsid >/dev/null 2>&1; then
        (
            [ -z "${ACTION_LOCK_FD:-}" ] || exec {ACTION_LOCK_FD}>&-
            exec setsid /bin/bash "$self" __rollback_guard "$snap" "$delay"
        ) </dev/null >/dev/null 2>&1 &
        return 0
    fi
    return 1
}

# 后台回滚任务本体（由 schedule_rollback_guard 启动）
rollback_guard() {
    local snap="$1" delay="${2:-0}" message i deadline now
    case "$snap" in
        */nft-sh.*) ;;
        *) return 1 ;;
    esac
    [ -d "$snap" ] || return 0
    load_rollback_context "$snap" || return 1
    if [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ]; then
        for ((i = 0; i < delay; i++)); do
            [ -d "$snap" ] || return 0
            if [ -e "$snap/confirmed" ] && [ -e "$snap/completed" ]; then break; fi
            sleep 1
        done
    fi
    [ -d "$snap" ] || return 0
    if [ -f "$snap/confirm.deadline" ]; then
        deadline=$(cat "$snap/confirm.deadline")
        if [[ "$deadline" =~ ^[0-9]+$ ]]; then
            while [ -d "$snap" ] && [ ! -e "$snap/confirmed" ]; do
                now=$(date +%s)
                [ "$now" -lt "$deadline" ] || break
                sleep 1
            done
        fi
    fi
    [ -d "$snap" ] || return 0
    # 和前台的确认 / 回滚互斥，避免临近超时时重复恢复或误报确认成功。
    if mkdir "$snap/decision" 2>/dev/null; then
        : > "$snap/rolled_back"
        if restore_snapshot "$snap"; then
            message="change was not confirmed in time, firewall rules rolled back"
        else
            message="rollback failed; managed firewall table removed to restore access"
        fi
        : > "$snap/completed"
        if command -v logger >/dev/null 2>&1; then
            logger -t nft.sh "$message"
        fi
    fi
    : > "$snap/guard_finished"
    # 前台可能仍在恢复或持久化；由最后完成的一方清理快照。
    [ ! -e "$snap/completed" ] || remove_snapshot_dir "$snap"
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
    case "$snap" in */nft-sh.*) [ -d "$snap" ] || return 1 ;; *) return 1 ;; esac
    echo ""
    warn "规则已生效。请不要关闭当前窗口，另开一个 SSH 窗口测试能否正常登录。"
    echo -ne "${YELLOW}确认正常请在 ${ROLLBACK_TIMEOUT} 秒内输入 y 并回车，超时或输入其他内容将自动回滚: ${NC}"
    # 超时时 read 会保留已输入但没按回车的内容，所以必须以 read 成功返回为准
    if read -r -t "$ROLLBACK_TIMEOUT" ans; then
        answered=1
    else
        echo ""
    fi
    if [ "$answered" -eq 1 ] && [[ "$ans" =~ ^[Yy]$ ]] && mkdir "$snap/decision" 2>/dev/null; then
        : > "$snap/confirmed"
        return 0
    fi
    if ! mkdir "$snap/decision" 2>/dev/null; then
        warn "后台回滚已开始，本次修改未确认"
        return 1
    fi
    : > "$snap/rolled_back"
    if restore_snapshot "$snap"; then
        warn "已回滚：防火墙规则和配置都恢复到了修改前的状态"
    else
        error "恢复旧规则失败，已删除本脚本的防火墙表以保证可以登录，请检查后重新应用规则"
    fi
    : > "$snap/completed"
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
    local rules="$1" conf tmp
    if ! mkdir -p "$NFT_PERSIST_DIR"; then
        error "✗ 创建 $NFT_PERSIST_DIR 失败"
        return 1
    fi
    tmp=$(mktemp "$NFT_PERSIST_DIR/.unified.XXXXXX") || return 1
    if ! cat "$rules" > "$tmp" || ! chmod 644 "$tmp" || ! mv -fT -- "$tmp" "$NFT_PERSIST_FILE"; then
        rm -f -- "$tmp"
        error "✗ 写入 $NFT_PERSIST_FILE 失败，规则在重启后不会保留"
        return 1
    fi
    conf=$(detect_nft_main_conf)
    if [ -f "$conf" ]; then
        if ! grep -qxF "$NFT_INCLUDE_LINE" "$conf"; then
            if ! append_line "$conf" "$NFT_INCLUDE_LINE"; then
                error "✗ 写入 $conf 失败，无法设置开机加载"
                return 1
            fi
        fi
    else
        if ! mkdir -p "$(dirname "$conf")" ||
            ! printf '#!/usr/sbin/nft -f\n%s\n' "$NFT_INCLUDE_LINE" > "$conf"; then
            error "✗ 写入 $conf 失败，无法设置开机加载"
            return 1
        fi
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

# 对重新应用和导入的配置同样检查 SSH 端口和重复范围，不能只在添加时校验。
precheck_forwards() {
    local ls le tip ts te p i ports family
    local -a starts=() ends=() families=()
    if [ -n "$(invalid_forward_lines)" ]; then
        error "错误: 转发配置含无效条目，已拒绝应用"
        return 1
    fi
    ports=$(get_ssh_ports)
    while read -r ls le tip ts te family; do
        for p in $ports; do
            if [ "$p" -ge "$ls" ] && [ "$p" -le "$le" ]; then
                error "错误: 转发配置包含 SSH 端口 $p，已拒绝应用"
                return 1
            fi
        done
        for i in "${!starts[@]}"; do
            [ "$family" = "${families[i]}" ] || continue
            if [ "$ls" -le "${ends[i]}" ] && [ "$le" -ge "${starts[i]}" ]; then
                error "错误: 转发配置中的本地端口范围重叠: $(port_spec "$ls" "$le")"
                return 1
            fi
        done
        starts+=("$ls"); ends+=("$le"); families+=("$family")
    done < <(list_forwards)
    return 0
}

# 应用完整 nft 规则，跨族资源按阶段保护，成功后写入持久化配置
apply_all_rules() {
    local rules live err wl_count fw_count confirm=0 cross_change=0
    case "$SNAPSHOT_DIR" in */nft-sh.*) [ -d "$SNAPSHOT_DIR" ] || return 1 ;; *) error '应用前必须建立有效快照'; return 1 ;; esac
    echo -e "${YELLOW}正在应用防火墙和转发规则...${NC}"

    if ! precheck_forwards || ! precheck_lockout; then
        [ -n "$SNAPSHOT_DIR" ] && restore_config_files "$SNAPSHOT_DIR"
        warn "已取消，配置和防火墙规则都没有改动"
        return 1
    fi
    if translation_needed; then
        if ! translation_precheck; then restore_config_files "$SNAPSHOT_DIR"; return 1; fi
        translation_current || cross_change=1
    elif [ -f "$TRANSLATE_DIR/live.forward" ] && translation_needed "$TRANSLATE_DIR/live.forward"; then
        cross_change=1
    fi

    rules=$(mktemp) || { restore_config_files "$SNAPSHOT_DIR"; return 1; }
    live=$(mktemp) || { rm -f "$rules"; restore_config_files "$SNAPSHOT_DIR"; return 1; }
    if ! build_ruleset > "$rules" || ! { legacy_table_deletes; cat "$rules"; } > "$live"; then
        rm -f "$rules" "$live"
        restore_config_files "$SNAPSHOT_DIR"
        return 1
    fi
    if ! err=$(nft -c -f "$live" 2>&1); then
        error "规则预检失败: $err"
        restore_config_files "$SNAPSHOT_DIR"
        rm -f "$rules" "$live"
        return 1
    fi

    # 先安排独立的回滚任务，再加载规则；保护程序无法启动时不冒险应用。
    if needs_confirmation || [ "$cross_change" = 1 ]; then
        if ! schedule_rollback_guard "$SNAPSHOT_DIR" $((ROLLBACK_TIMEOUT + 5)); then
            error "无法创建后台回滚任务，已取消应用"
            restore_config_files "$SNAPSHOT_DIR"
            rm -f "$rules" "$live"
            return 1
        fi
        ROLLBACK_PENDING=1
        if ! printf '%s\n' "$SNAPSHOT_DIR" > "${NFT_SH_LOCK_FILE:-$FORWARD_FILE.lock}"; then
            restore_config_files "$SNAPSHOT_DIR"
            finish_action_guard
            rm -f "$rules" "$live"
            return 1
        fi
        if needs_confirmation; then confirm=1; fi
    fi

    if ! ensure_runtime_forwarding; then
        restore_config_files "$SNAPSHOT_DIR"
        restore_sysctls "$SNAPSHOT_DIR"
        mkdir "$SNAPSHOT_DIR/decision" 2>/dev/null && : > "$SNAPSHOT_DIR/confirmed"
        : > "$SNAPSHOT_DIR/completed"
        rm -f "$rules" "$live"
        return 1
    fi
    if [ "$cross_change" = 1 ]; then
        : > "$SNAPSHOT_DIR/translation.changed"
        if ! translation_guard_close || ! translation_setup; then
            error '内核转换准备失败，正在恢复旧配置和转换路径'
            restore_snapshot "$SNAPSHOT_DIR"
            mkdir "$SNAPSHOT_DIR/decision" 2>/dev/null && : > "$SNAPSHOT_DIR/confirmed"
            : > "$SNAPSHOT_DIR/completed"
            rm -f "$rules" "$live"
            return 1
        fi
    fi

    if ! err=$(nft -f "$live" 2>&1); then
        error "✗ 规则应用失败，防火墙保持原样，没有做任何改动。nft 输出:"
        printf '%s\n' "$err" | head -n 20
        if [ -n "$SNAPSHOT_DIR" ]; then
            if [ "$cross_change" = 1 ]; then restore_snapshot "$SNAPSHOT_DIR"; else
                restore_config_files "$SNAPSHOT_DIR"; restore_sysctls "$SNAPSHOT_DIR"
            fi
            if [ "$ROLLBACK_PENDING" -eq 1 ]; then
                mkdir "$SNAPSHOT_DIR/decision" 2>/dev/null && : > "$SNAPSHOT_DIR/confirmed"
                : > "$SNAPSHOT_DIR/completed"
            fi
            warn "配置文件已恢复为修改前的内容"
        fi
        rm -f "$rules" "$live"
        return 1
    fi

    if [ "$cross_change" = 1 ] && ! translation_guard_open; then
        restore_snapshot "$SNAPSHOT_DIR"
        finish_action_guard
        rm -f "$rules" "$live"
        return 1
    fi
    if [ "$ROLLBACK_PENDING" = 1 ]; then
        printf '%s\n' "$(( $(date +%s) + ROLLBACK_TIMEOUT ))" > "$SNAPSHOT_DIR/confirm.deadline"
    fi

    if [ "$confirm" -eq 1 ] && ! confirm_or_rollback; then
        rm -f "$rules" "$live"
        return 1
    fi

    if ! persist_rules "$rules"; then
        if [ "$cross_change" = 1 ]; then restore_snapshot "$SNAPSHOT_DIR"; fi
        warn "规则已在内存中生效，但持久化失败，请修复文件路径或权限后重新 apply"
        rm -f "$rules" "$live"
        finish_action_guard
        return 1
    fi
    if translation_needed; then
        if ! translation_record || ! translation_persist; then
            error '内核转换持久化失败，恢复修改前的配置'
            : > "$SNAPSHOT_DIR/translation.changed"
            restore_snapshot "$SNAPSHOT_DIR"
            finish_action_guard
            rm -f "$rules" "$live"
            return 1
        fi
    elif [ "$cross_change" = 1 ]; then
        if ! translation_uninstall; then
            restore_snapshot "$SNAPSHOT_DIR"; finish_action_guard
            rm -f "$rules" "$live"; return 1
        fi
    fi
    if [ "$ROLLBACK_PENDING" = 1 ] && [ "$confirm" = 0 ]; then
        mkdir "$SNAPSHOT_DIR/decision" 2>/dev/null && : > "$SNAPSHOT_DIR/confirmed"
    fi
    [ "$ROLLBACK_PENDING" -ne 1 ] || : > "$SNAPSHOT_DIR/completed"
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
    append_line "$WHITELIST_FILE" "$entry" || return 1
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
    if ! cat "$tmp" > "$WHITELIST_FILE"; then
        rm -f "$tmp"
        return 1
    fi
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
    if persist_forward_value net.ipv4.ip_forward 1; then
        info "✓ IPv4转发已启用，并写入 $SYSCTL_FILE（重启后仍然生效）"
    else
        warn "IPv4转发已临时启用，但写入 $SYSCTL_FILE 失败，重启后会失效"
        return 1
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
    FWD_FAMILY="${4:-ipv4}"
    case "$FWD_FAMILY" in ipv4|ipv6) ;; *) error "错误: 入站地址族必须为 ipv4 或 ipv6"; return 1 ;; esac
    FWD_TIP=$(trim "$2")
    validate_target_ip "$FWD_TIP" || return 1
    FWD_TIP=$(normalize_ip_entry "$FWD_TIP") || return 1
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
    if conflict=$(forward_conflict "$FWD_LS" "$FWD_LE" "$FWD_FAMILY"); then
        error "错误: 本地端口与已有转发重叠: $conflict"
        return 1
    fi
    check_local_ports "$FWD_LS" "$FWD_LE"
}

fwd_append() {
    local lspec tspec
    lspec=$(port_spec "$FWD_LS" "$FWD_LE")
    tspec=$(port_spec "$FWD_TS" "$FWD_TE")
    if [[ "$FWD_FAMILY" = "ipv4" && "$FWD_TIP" != *:* ]]; then
        append_line "$FORWARD_FILE" "$lspec|$FWD_TIP|$tspec" || return 1
    else
        append_line "$FORWARD_FILE" "$FWD_FAMILY|$lspec|$FWD_TIP|$tspec" || return 1
    fi
    info "✓ 已添加转发: $FWD_FAMILY 本地 $lspec → $FWD_TIP:$tspec [TCP+UDP]"
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
    if ! cat "$tmp" > "$FORWARD_FILE"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    info "✓ 已删除转发: $removed"
}

# 按本地端口（段）查找转发的序号
fwd_index_by_local() {
    local want n=0 ls le tip ts te family found="" count=0
    want=$(parse_port_spec "$1") || return 1
    while read -r ls le tip ts te family; do
        n=$((n + 1))
        [ -z "${2:-}" ] || [ "$family" = "$2" ] || continue
        if [ "$ls $le" = "$want" ]; then
            found="$n"; count=$((count + 1))
        fi
    done < <(list_forwards)
    if [ "$count" -gt 1 ]; then
        error "相同端口存在多个地址族，请指定 --listen-family ipv4|ipv6" >&2
        return 1
    fi
    [ "$count" -eq 1 ] || return 1
    echo "$found"
}

show_forwards() {
    local n=0 ls le tip ts te family backend target
    while read -r ls le tip ts te family; do
        n=$((n + 1))
        target="$tip"; backend="nft"
        [[ "$tip" != *:* ]] || target="[$tip]"
        if { [[ "$tip" == *:* ]] && [ "$family" = "ipv4" ]; } ||
            { [[ "$tip" != *:* ]] && [ "$family" = "ipv6" ]; }; then backend="Jool"; fi
        echo -e "${GREEN}[$n]${NC} [TCP+UDP/$backend] $family 本地:$(port_spec "$ls" "$le") → $target:$(port_spec "$ts" "$te")"
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
    if ! fwd_append; then
        restore_config_files "$SNAPSHOT_DIR"
        return 1
    fi
    apply_all_rules
}

# 添加单个端口转发
add_forward_single() {
    local target_ip target_port local_port family
    echo -e "\n${BLUE}【添加单端口转发】${NC}"
    echo -ne "${YELLOW}入站地址族 [ipv4/ipv6，默认 ipv4]: ${NC}"
    read -r family
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
    fwd_validate "$local_port" "$target_ip" "$target_port" "${family:-ipv4}" || return 1
    fwd_confirm_and_apply
}

# 添加端口段转发
add_forward_range() {
    local target_ip ts te ls le family
    echo -e "\n${BLUE}【添加端口段转发】${NC}"
    echo -ne "${YELLOW}入站地址族 [ipv4/ipv6，默认 ipv4]: ${NC}"
    read -r family
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
    fwd_validate "$(trim "$ls")-$(trim "$le")" "$target_ip" "$(trim "$ts")-$(trim "$te")" "${family:-ipv4}" || return 1
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
    local clear_choice confirm batch translated=0
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
            if translation_needed || [ -f "$TRANSLATE_DEPLOY" ]; then
                translation_guard_close || return 1
                translated=1
            fi
            batch=$(
                nft_table_exists "$NFT_TABLE" && echo "delete table inet $NFT_TABLE"
                legacy_table_deletes
            )
            if [ -n "$batch" ] && ! nft_run_batch "$batch"; then
                error "✗ 删除防火墙表失败，没有做任何改动"
                [ "$translated" = 0 ] || translation_guard_open
                return 1
            fi
            : > "$WHITELIST_FILE"
            : > "$FORWARD_FILE"
            if [ "$translated" = 1 ]; then
                translation_uninstall || return 1
                rm -f "$TRANSLATE_DEPLOY" "$LIBEXEC_DIR/nft.sh"
            fi
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
    for f in "$WHITELIST_FILE" "$FORWARD_FILE" "$WHITELIST_ENABLED_FILE" "$TRANSLATE_DEPLOY"; do
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

# 从备份中读取一个普通文件到固定临时文件。只向 stdout 解压，归档中的链接、目录和
# 路径都不会交给 tar 写入文件系统；同名成员出现多次也拒绝，避免内容被拼接。
read_backup_member() {
    local archive="$1" member="$2" dest="$3" listing
    listing=$(tar -tvzf "$archive" --no-recursion -- "$member" 2>/dev/null) || return 1
    [[ "$listing" == -* && "$listing" != *$'\n'* ]] || return 1
    tar -xOzf "$archive" --no-recursion -- "$member" > "$dest" 2>/dev/null
}

# 导入配置：只读取本脚本的三个配置文件，内容逐条校验后再写入
import_config() {
    local backup_file tmpd src total valid found=0 wl_ok=0 wl_bad=0 fw_ok=0 fw_bad=0
    local ls le tip ts te family flag name target
    echo -ne "备份文件路径: "
    read -r backup_file
    backup_file=$(trim "$backup_file")
    if [ ! -f "$backup_file" ]; then
        error "文件不存在"
        return 1
    fi
    tmpd=$(mktemp -d) || return 1
    src="$tmpd/whitelist"
    if read_backup_member "$backup_file" "${WHITELIST_FILE#/}" "$src"; then
        found=1
        total=$(load_whitelist "$src" | wc -l)
        load_whitelist_normalized "$src" 2>/dev/null | awk '!seen[$0]++' > "$tmpd/whitelist.valid"
        valid=$(load_whitelist_normalized "$src" 2>/dev/null | wc -l)
        wl_ok=$(load_whitelist "$tmpd/whitelist.valid" | wc -l)
        wl_bad=$((total - valid))
    fi

    src="$tmpd/forward"
    if read_backup_member "$backup_file" "${FORWARD_FILE#/}" "$src"; then
        found=1
        list_forwards "$src" | while read -r ls le tip ts te family; do
            if [[ "$family" = "ipv4" && "$tip" != *:* ]]; then
                echo "$(port_spec "$ls" "$le")|$tip|$(port_spec "$ts" "$te")"
            else
                echo "$family|$(port_spec "$ls" "$le")|$tip|$(port_spec "$ts" "$te")"
            fi
        done > "$tmpd/forward.valid"
        fw_ok=$(list_forwards "$tmpd/forward.valid" | wc -l)
        fw_bad=$(invalid_forward_lines "$src" | wc -l)
    fi

    src="$tmpd/enabled"
    if read_backup_member "$backup_file" "${WHITELIST_ENABLED_FILE#/}" "$src"; then
        found=1
        flag=$(trim "$(cat "$src")")
        case "$flag" in
            0|1) printf '%s\n' "$flag" > "$tmpd/enabled.valid" ;;
            *)
                error "备份中的白名单开关无效（只能是 0 或 1），已取消导入"
                rm -rf "$tmpd"
                return 1
                ;;
        esac
    fi

    if [ "$found" -eq 0 ]; then
        error "备份文件中没有本脚本的配置（需要使用菜单 11 导出的 .tar.gz 文件）"
        rm -rf "$tmpd"
        return 1
    fi
    src="$tmpd/deployment"
    if read_backup_member "$backup_file" "${TRANSLATE_DEPLOY#/}" "$src"; then
        if ! (translation_settings "$src"); then
            error '备份中的内核转换部署参数无效，已取消导入'
            rm -rf "$tmpd"; return 1
        fi
        cp "$src" "$tmpd/deployment.valid" || { rm -rf "$tmpd"; return 1; }
    fi
    for name in whitelist forward enabled deployment; do
        [ -f "$tmpd/$name.valid" ] || continue
        case "$name" in
            whitelist) target="$WHITELIST_FILE" ;;
            forward) target="$FORWARD_FILE" ;;
            enabled) target="$WHITELIST_ENABLED_FILE" ;;
            deployment) target="$TRANSLATE_DEPLOY"; mkdir -p "$TRANSLATE_DIR" || { rm -rf "$tmpd"; return 1; } ;;
        esac
        if ! cat "$tmpd/$name.valid" > "$target"; then
            error "写入 $target 失败，已取消导入"
            restore_config_files "$SNAPSHOT_DIR"
            rm -rf "$tmpd"
            return 1
        fi
    done
    rm -rf "$tmpd"
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
    if [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" = 1 ]; then
        echo -e "IPv6转发: ${GREEN}✓ 已启用${NC}"
    else
        echo -e "IPv6转发: ${RED}✗ 未启用${NC}"
    fi
    translation_status
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
            1|2|3|4|5|6|8|10|12)
                if ! begin_action; then
                    error "无法保存操作前的快照，已取消"
                    continue
                fi
                ;;
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
  $me add-forward [--listen-family ipv4|ipv6] <本地端口> <目标IP> <目标端口>
                                          添加 TCP+UDP 转发，端口可以写成段，如 10000-10010
  $me del-forward [--listen-family ipv4|ipv6] <本地端口>
  $me ip-forward                          开启 IPv4 转发
  $me print-rules                         只打印将要应用的 nftables 规则，不做任何修改
  $me print-plan                          只读预览 nft、内核转换配置及环境要求
  $me help | version

说明:
  - 在 SSH 终端中修改白名单后，需要在 ${ROLLBACK_TIMEOUT} 秒内确认，否则自动回滚
  - 非交互运行（如 cron）时，可能导致失联的操作会被拒绝；确认无误可设置 NFT_SH_FORCE=1
EOF
}

run_cli() {
    local cmd="$1" rc=0 idx family=""
    shift
    CLI_MODE=1
    case "$cmd" in
        status)
            show_all_rules
            ;;
        print-rules)
            build_ruleset
            ;;
        print-plan)
            print_plan
            ;;
        apply)
            begin_action || return 1
            CONFIRM_ALWAYS=1
            apply_all_rules
            rc=$?
            ;;
        add-ip|del-ip)
            if [ $# -ne 1 ]; then
                usage >&2
                return 2
            fi
            begin_action || return 1
            if [ "$cmd" = "add-ip" ]; then
                wl_add "$1" && apply_all_rules
            else
                wl_remove "$1" && apply_all_rules
            fi
            rc=$?
            ;;
        whitelist)
            [ $# -eq 1 ] || { usage >&2; return 2; }
            case "${1:-}" in
                on|off)
                    begin_action || return 1
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
            if [ "${1:-}" = "--listen-family" ]; then
                [ $# -ge 2 ] || return 2
                family="$2"; shift 2
                case "$family" in ipv4|ipv6) ;; *) return 2 ;; esac
            fi
            if [ $# -ne 3 ]; then
                usage >&2
                return 2
            fi
            begin_action || return 1
            if fwd_validate "$1" "$2" "$3" "${family:-ipv4}"; then
                fwd_append && apply_all_rules
                rc=$?
            else
                rc=1
            fi
            ;;
        del-forward)
            if [ "${1:-}" = "--listen-family" ]; then
                [ $# -ge 2 ] || return 2
                family="$2"; shift 2
                case "$family" in ipv4|ipv6) ;; *) return 2 ;; esac
            fi
            if [ $# -ne 1 ]; then
                usage >&2
                return 2
            fi
            begin_action || return 1
            if idx=$(fwd_index_by_local "$1" "$family"); then
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
        __translate_boot)
            translation_boot
            exit $?
            ;;
        __translate_stop)
            [ "$EUID" -eq 0 ] || exit 1
            translation_guard_close && translation_remove
            exit $?
            ;;
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

    # 规则预览只读取已有配置，不要求 root/nft，也不初始化任何文件。
    if [ "${1:-}" = "print-rules" ] || [ "${1:-}" = "print-plan" ]; then
        if [ "$1" = print-plan ]; then print_plan; else build_ruleset; fi
        exit $?
    fi

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
