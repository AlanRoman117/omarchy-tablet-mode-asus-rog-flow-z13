#!/bin/bash

# Publishes a release on main: one commit holding only what users install, built from
# develop. `omarchy plugin add` clones the repo's default branch (main) whole, and
# `omarchy plugin update` fast-forwards it, so dev notes, tests and diagnostics stay on
# develop. Each release commit's parent is the previous main, so updates fast-forward.
# Nothing is pushed.
#
# Usage: scripts/release.sh [--dry-run] VERSION   (e.g. 0.2.0; bump it on develop first)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# What deploy.sh installs, plus the screenshots the README shows.
SHIP=(manifest.json Widget.qml bin systemd packaging README.md LICENSE docs/screenshots)

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

dry=0
[[ ${1:-} == --dry-run ]] && dry=1 && shift
VERSION=${1:-}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Usage: scripts/release.sh [--dry-run] VERSION (like 0.2.0)"
cd "$REPO"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
((dry)) || [[ $branch == develop ]] || die "Releases are built from develop (you're on ${branch:-a detached HEAD})"
[[ -z $(git status --porcelain) ]] || die "Commit or stash your changes first"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && die "v$VERSION is already tagged"
grep -qx "VERSION=$VERSION" bin/tablet-mode || die "bin/tablet-mode isn't at VERSION=$VERSION; bump it on develop first"
[[ $(jq -r .version manifest.json) == "$VERSION" ]] || die "manifest.json isn't at version $VERSION; bump it on develop first"

echo "Running the tests..."
test/run.sh >/dev/null 2>&1 || die "test/run.sh fails; run it to see why"

# The release tree: exactly the shipped paths from HEAD, modes kept, through a private index.
index=$(mktemp)
check=$(mktemp -d)
trap 'rm -rf "$index" "$check"' EXIT
GIT_INDEX_FILE=$index git read-tree --empty
git ls-tree -r --full-tree HEAD -- "${SHIP[@]}" | GIT_INDEX_FILE=$index git update-index --index-info
tree=$(GIT_INDEX_FILE=$index git write-tree)

# What users will get must stand on its own.
git archive "$tree" | tar -x -C "$check"
omarchy-plugin-validate "$check" >/dev/null || die "The release tree doesn't validate as a plugin"
bash -n "$check/bin/tablet-mode" || die "bin/tablet-mode doesn't parse"
for path in "${SHIP[@]}"; do [[ -e $check/$path ]] || die "$path is missing from the release"; done

echo "v$VERSION ships:"
git ls-tree -r --name-only "$tree" | sed 's/^/  /'
if ((dry)); then
  echo "Dry run: main and the tags are unchanged."
  exit 0
fi

main=$(git rev-parse main)
[[ $tree != $(git rev-parse "main^{tree}") ]] || die "main already holds exactly this tree"
commit=$(git commit-tree "$tree" -p "$main" -m "Release v$VERSION" -m "Built from develop at $(git rev-parse --short HEAD) by scripts/release.sh.")
git update-ref refs/heads/main "$commit" "$main"
git tag -a "v$VERSION" -m "Tablet Mode $VERSION" "$commit"
echo "main is now v$VERSION ($(git rev-parse --short "$commit"))."
echo "Publish with: git push origin main develop v$VERSION"
