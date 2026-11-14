#!/bin/bash
# Exercise the same explicit dependency installer shipped to VPS users.
set -euo pipefail
[ "$EUID" -eq 0 ] && [ "${CI:-}" = true ] || { echo 'Run only as root on a disposable CI host (CI=true)' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y nftables python3
bash "$ROOT/nft.sh" install-jool
bash "$ROOT/nft.sh" check-jool
# Repeating installation must keep the installed translator and services intact.
bash "$ROOT/nft.sh" install-jool
[ "$(jool --version)" = "$(cat /sys/module/jool/version)" ]
! systemctl is-active --quiet jool.service
! systemctl is-active --quiet jool_siit.service
uname -r
jool --version
