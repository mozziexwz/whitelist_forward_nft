#!/bin/bash
# 生成可发布脚本和 SHA256SUMS；不创建标签，也不访问 GitHub。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(awk -F '"' '/^VERSION=/ {print $2; exit}' "$ROOT/nft.sh")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "无效版本号"; exit 1; }
if [ -n "${RELEASE_TAG:-}" ] && [ "$RELEASE_TAG" != "v$VERSION" ]; then
    echo "RELEASE_TAG 与脚本版本号不一致"; exit 1
fi
bash -n "$ROOT/nft.sh"
if LC_ALL=C grep -q $'\r' "$ROOT/nft.sh"; then echo "脚本包含 CRLF，拒绝发布"; exit 1; fi
OUT="${1:-$ROOT/dist/v$VERSION}"
mkdir -p "$OUT"
cp "$ROOT/nft.sh" "$OUT/nft.sh"
chmod 755 "$OUT/nft.sh"
(
    cd "$OUT"
    sha256sum nft.sh > SHA256SUMS
    sha256sum -c SHA256SUMS
)
printf 'Release v%s: %s\n' "$VERSION" "$OUT"
