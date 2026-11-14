#!/bin/bash
# Tag-triggered GitHub Actions only. Published releases are never overwritten.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] && [ "${GITHUB_REF_TYPE:-}" = tag ] || {
    echo 'Run only from a tag-triggered GitHub Actions workflow' >&2; exit 1;
}
: "${GH_TOKEN:?GitHub token is required}"
: "${GITHUB_REPOSITORY:?Repository is required}"
: "${RELEASE_TAG:?Release tag is required}"
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
commit=$(git rev-parse HEAD)
[ "$(git rev-parse "$RELEASE_TAG^{commit}")" = "$commit" ]
git merge-base --is-ancestor "$commit" origin/main

# Publishing requires successful main CI on this exact commit, including all
# kernel builds and integration checks. Do not accept a different commit's CI.
gh api "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs" --method GET \
    -f branch=main -f event=push -f head_sha="$commit" \
    --jq '.workflow_runs[] | select(.status == "completed" and .conclusion == "success") | .head_sha' |
    grep -qxF "$commit"
bash scripts/package_release.sh
notes="docs/releases/$RELEASE_TAG.md"
[ -f "$notes" ] || { echo "Missing release notes: $notes" >&2; exit 1; }
out="$ROOT/dist/$RELEASE_TAG"
verify=$(mktemp -d)
trap 'rm -rf -- "$verify"' EXIT
verify_assets() {
    gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
        --pattern nft.sh --pattern SHA256SUMS --dir "$verify"
    cmp "$out/nft.sh" "$verify/nft.sh"
    cmp "$out/SHA256SUMS" "$verify/SHA256SUMS"
    (cd "$verify" && sha256sum -c SHA256SUMS)
}

if draft=$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft 2>/dev/null); then
    if [ "$draft" != true ]; then
        verify_assets
        echo 'Existing published release verified; no files changed.'
        exit 0
    fi
else
    gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --verify-tag \
        --draft --title "$RELEASE_TAG" --notes-file "$notes"
fi
# Only drafts reach this point. Verify downloaded bytes before making public.
gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber \
    "$out/nft.sh" "$out/SHA256SUMS"
verify_assets
gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest
gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json url,isDraft,isPrerelease
