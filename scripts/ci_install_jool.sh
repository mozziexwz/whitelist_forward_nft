#!/bin/bash
# Disposable Debian/Ubuntu CI hosts only. Exact upstream release assets/digests.
set -euo pipefail
[ "$EUID" -eq 0 ] && [ "${CI:-}" = true ] || { echo 'Run only as root on a disposable CI host (CI=true)' >&2; exit 1; }
[ "$(dpkg --print-architecture)" = amd64 ] || exit 1
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    build-essential dkms "linux-headers-$(uname -r)" curl ca-certificates nftables iproute2 python3
base=https://github.com/NICMx/Jool/releases/download/v4.1.15
curl -fL --retry 3 "$base/jool-dkms_4.1.15-1_all.deb" -o "$WORK/jool-dkms.deb"
curl -fL --retry 3 "$base/jool-tools_4.1.15-1_amd64.deb" -o "$WORK/jool-tools.deb"
printf '%s  %s\n' \
    6a6f3bdc9c34c8b45f3404e5b926c1e2dfc2696afe3955aaed91c61c939d6294 "$WORK/jool-dkms.deb" \
    ad4707e00db184303693fb1ec8161137ba9c1d37b252a74fc805136a88750479 "$WORK/jool-tools.deb" | sha256sum -c -
DEBIAN_FRONTEND=noninteractive apt-get install -y "$WORK/jool-dkms.deb" "$WORK/jool-tools.deb"
systemctl disable jool.service jool_siit.service
modprobe jool
[ "$(jool --version)" = "$(cat /sys/module/jool/version)" ]
uname -r
jool --version
