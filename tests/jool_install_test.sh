#!/bin/bash
# Failure-path tests use fake package/build commands; no packages are installed.
# shellcheck disable=SC2034
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
# shellcheck source=../nft.sh
source "$ROOT/nft.sh"
PASS=0 FAIL=0

expect() {
    local desc="$1"
    shift
    if "$@"; then PASS=$((PASS + 1)); else echo "FAIL: $desc"; FAIL=$((FAIL + 1)); fi
}

fixture() {
    CASE="$WORK/$1"
    mkdir -p "$CASE/tmp"
    export TMPDIR="$CASE/tmp"
    FORWARD_FILE="$CASE/forward.conf"
    printf 'existing forwarding declaration\n' > "$FORWARD_FILE"
    ip() { :; }
    ss() { :; }
    nsenter() { :; }
    # Hide the fake client until the fake installation has created it.
    command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = jool ] && [ ! -f "$CASE/tool" ]; then return 1; fi
        builtin command "$@"
    }
    jool() { cat "$CASE/tool"; }
    modinfo() { cat "$CASE/disk" 2>/dev/null; }
    jool_loaded_version() { cat "$CASE/loaded-$1" 2>/dev/null; }
    modprobe() {
        printf '%s\n' "$*" >> "$CASE/modprobe.calls"
        if [ "${1:-}" = -n ]; then [ -f "$CASE/disk" ]; return $?; fi
        [ ! -f "$CASE/fail-load" ] || return 1
        cp "$CASE/disk" "$CASE/loaded-jool"
    }
    jool_install_platform() { echo debian; }
    jool_install_dependencies() {
        : > "$CASE/dependencies.called"
        [ ! -f "$CASE/fail-dependencies" ]
    }
    flock() { :; }
    curl() {
        : > "$CASE/download.called"
        [ ! -f "$CASE/fail-download" ] || return 22
        printf 'not a trusted tarball\n' > "${!#}"
    }
    sha256sum() { cat >/dev/null; [ ! -f "$CASE/fail-checksum" ]; }
    tar() {
        : > "$CASE/extraction.called"
        mkdir -p "${!#}/jool-4.1.15"
        printf '#!/bin/bash\nexit 0\n' > "${!#}/jool-4.1.15/configure"
        chmod +x "${!#}/jool-4.1.15/configure"
    }
    make() {
        if [ "${!#}" = install ]; then
            : > "$CASE/tool-install.called"
            echo 4.1.15.0 > "$CASE/tool"
        fi
    }
    dkms() {
        [ "$1" != status ] || return 0
        printf '%s\n' "$*" >> "$CASE/dkms.calls"
        [ ! -f "$CASE/fail-dkms" ] || return 1
        echo 4.1.15.0 > "$CASE/disk"
    }
    ldconfig() { :; }
    nft() { : > "$CASE/nft.called"; return 1; }
    systemctl() { : > "$CASE/systemctl.called"; return 1; }
}

diagnostic() (
    fixture "diagnostic-$1"
    echo 4.1.15.0 > "$CASE/tool"
    echo 4.1.15.0 > "$CASE/disk"
    case "$1" in
        missing-client) rm "$CASE/tool" ;;
        missing-module) rm "$CASE/disk" ;;
        old) echo 4.1.13.0 > "$CASE/tool"; cp "$CASE/tool" "$CASE/disk" ;;
        mismatch) echo 4.1.16.0 > "$CASE/disk" ;;
        loaded-mismatch) echo 4.1.13.0 > "$CASE/loaded-jool_common" ;;
        unloaded|ready) ;;
    esac
    [ "$1" != ready ] || cp "$CASE/disk" "$CASE/loaded-jool"
    check_jool > "$CASE/output" 2>&1
    rc=$?
    case "$1" in unloaded|ready) [ "$rc" -eq 0 ] ;; *) [ "$rc" -ne 0 ] ;; esac || exit 1
    # Read-only checks must never load modules, install packages or change rules.
    ! grep -qx jool "$CASE/modprobe.calls" 2>/dev/null &&
        [ ! -e "$CASE/dependencies.called" ] && [ ! -e "$CASE/nft.called" ]
)
for scenario in missing-client missing-module old mismatch loaded-mismatch unloaded ready; do
    expect "read-only dependency diagnostic: $scenario" diagnostic "$scenario"
done

installation() (
    fixture "installation-$1"
    case "$1" in
        old-client) echo 4.1.13.0 > "$CASE/tool" ;;
        old-disk) echo 4.1.13.0 > "$CASE/disk" ;;
        old-loaded) echo 4.1.13.0 > "$CASE/loaded-jool_common" ;;
        dependencies|download|checksum|dkms|load) : > "$CASE/fail-$1" ;;
        ready) echo 4.1.15.0 > "$CASE/tool"; echo 4.1.15.0 > "$CASE/disk" ;;
        missing-client) echo 4.1.15.0 > "$CASE/disk" ;;
        missing-module) echo 4.1.15.0 > "$CASE/tool" ;;
        fresh) ;;
    esac
    install_jool > "$CASE/output" 2>&1
    rc=$?
    if [ -e "$CASE/nft.called" ] || [ -e "$CASE/systemctl.called" ] ||
        [ "$(cat "$FORWARD_FILE")" != 'existing forwarding declaration' ]; then exit 1; fi
    case "$1" in
        old-*) [ "$rc" -ne 0 ] && [ ! -e "$CASE/dependencies.called" ] ;;
        dependencies) [ "$rc" -ne 0 ] && [ ! -e "$CASE/download.called" ] ;;
        download|checksum) [ "$rc" -ne 0 ] && [ ! -e "$CASE/extraction.called" ] && [ ! -e "$CASE/dkms.calls" ] ;;
        dkms) [ "$rc" -ne 0 ] && [ ! -e "$CASE/tool-install.called" ] ;;
        load) [ "$rc" -ne 0 ] && ! grep -q '依赖已就绪' "$CASE/output" ;;
        ready) [ "$rc" -eq 0 ] && [ ! -e "$CASE/dependencies.called" ] && [ ! -e "$CASE/download.called" ] ;;
        missing-client) [ "$rc" -eq 0 ] && [ ! -e "$CASE/dkms.calls" ] && [ -e "$CASE/tool-install.called" ] ;;
        missing-module) [ "$rc" -eq 0 ] && [ -e "$CASE/dkms.calls" ] && [ ! -e "$CASE/tool-install.called" ] ;;
        fresh) [ "$rc" -eq 0 ] && [ -e "$CASE/dkms.calls" ] && [ -e "$CASE/tool-install.called" ] &&
            grep -q -- "-k $(uname -r)" "$CASE/dkms.calls" ;;
    esac || { cat "$CASE/output"; exit 1; }
    # The source download/extraction directory must be removed on every exit.
    [ -z "$(find "$CASE/tmp" -mindepth 1 -print -quit)" ]
)
if [ "$EUID" -eq 0 ]; then
    for scenario in old-client old-disk old-loaded dependencies download checksum dkms load ready missing-client missing-module fresh; do
        expect "isolated dependency installation: $scenario" installation "$scenario"
    done
else
    echo '安装失败路径需要 root；CI 使用 sudo 执行这些隔离测试'
fi

printf 'Jool 依赖测试: 通过 %s，失败 %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
