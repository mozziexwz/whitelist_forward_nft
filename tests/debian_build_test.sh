#!/bin/bash
# Disposable Debian containers only. Build for Debian kernels without loading
# modules into the container host; this is not a boot or data-path test.
set -euo pipefail
[ "$EUID" -eq 0 ] && [ "${CI:-}" = true ] && [ -f /.dockerenv ] || {
    echo 'Run only inside a disposable root CI container (CI=true)' >&2; exit 1;
}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
# shellcheck source=../nft.sh
source "$ROOT/nft.sh"
[ "$(jool_os_id)" = debian ] && [ "$(dpkg --print-architecture)" = amd64 ]
mkdir -p /run/lock
bash "$ROOT/tests/unit_test.sh"
bash "$ROOT/tests/jool_install_test.sh"
apt-get update
# Build both VPS cloud and ordinary Debian kernel flavours, using the same
# dependency preparation and exact-header checks as the production installer.
for flavour in cloud-amd64 amd64; do
    package=$(LC_ALL=C apt-cache depends "linux-headers-$flavour" | awk '/Depends: linux-headers-[0-9]/ { print $2; exit }')
    [ -n "$package" ] || { echo "No current Debian headers for $flavour"; exit 1; }
    kernel="${package#linux-headers-}"
    jool_install_dependencies debian "$kernel"
    jool_kernel_headers_ready "$kernel"
    printf '%s\n' "$kernel" >> "$WORK/kernels"
done
curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 15 \
    https://github.com/NICMx/Jool/releases/download/v4.1.15/jool-4.1.15.tar.gz -o "$WORK/jool.tar.gz"
printf '%s  %s\n' 51604bcf6a9f7fbb9080876102d05da01dc91d8c73cd5828fd73d5895643f8cd "$WORK/jool.tar.gz" | sha256sum -c -
tar -xzf "$WORK/jool.tar.gz" -C "$WORK"
cd "$WORK/jool-4.1.15"
./configure --prefix=/usr/local --with-xtables=no --with-bash-completion-dir=no
make -j2
make install
ldconfig
[ "$(jool --version)" = 4.1.15.0 ]
first=1
while IFS= read -r kernel; do
    if [ "$first" -eq 1 ]; then
        dkms install "$WORK/jool-4.1.15" -k "$kernel"
        first=0
    else
        dkms install -m jool -v 4.1.15 -k "$kernel"
    fi
    [ "$(modinfo -k "$kernel" -F version jool)" = "$(jool --version)" ]
    [ "$(modinfo -k "$kernel" -F vermagic jool | awk '{ print $1 }')" = "$kernel" ]
    echo "PASS: Debian tools + exact headers + DKMS for $kernel (no module load)"
done < "$WORK/kernels"

# Check all generated rule directions with each distribution's nft userspace.
# The container has its own network namespace; --check commits no firewall state.
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y nftables
FORWARD_FILE="$WORK/forward.conf"
WHITELIST_FILE="$WORK/whitelist"
WHITELIST_ENABLED_FILE="$WORK/enabled"
TRANSLATE_DIR="$WORK/translate"
TRANSLATE_DEPLOY="$TRANSLATE_DIR/deployment.conf"
printf '192.0.2.1\n2001:db8::1\n' > "$WHITELIST_FILE"
echo 1 > "$WHITELIST_ENABLED_FILE"
cat > "$FORWARD_FILE" <<'CONF'
ipv4|30000-30002|192.0.2.10|20000-20002
ipv6|31000-31002|2001:db8::10|20000-20002
ipv6|32000-32002|192.0.2.10|20000-20002
ipv4|33000-33002|2001:db8::10|20000-20002
CONF
build_ruleset > "$WORK/plan.nft"
nft --check --file "$WORK/plan.nft"
echo 'PASS: all four directions parsed by native Debian nftables (no rules applied)'
