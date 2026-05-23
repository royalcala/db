#!/usr/bin/env bash
set -euo pipefail

BUMP_TYPE="${1:-patch}"
DIST_TAG="${2:-latest}"
NPM_SCOPE="${3:-@roy.alcala}"

REPO_ROOT="$(pwd)"
TMP_DIR="$(mktemp -d)"
TMP_REPO="${TMP_DIR}/db"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

case "$BUMP_TYPE" in
  patch|minor|major|prepatch|preminor|premajor|prerelease) ;;
  *)
    echo "Invalid bump type: $BUMP_TYPE"
    echo "Use one of: patch|minor|major|prepatch|preminor|premajor|prerelease"
    exit 1
    ;;
esac

if [[ ! -d "${REPO_ROOT}/.git" ]]; then
  echo "Run this script from the repository root."
  exit 1
fi

git clone --quiet "${REPO_ROOT}" "${TMP_REPO}"
cd "${TMP_REPO}"

# Rewrite package names/dependencies for publish artifacts only.
sed -i "s|\"name\": \"@tanstack/db-ivm\"|\"name\": \"${NPM_SCOPE}/db-ivm\"|" packages/db-ivm/package.json
sed -i "s|\"name\": \"@tanstack/db\"|\"name\": \"${NPM_SCOPE}/db\"|" packages/db/package.json
sed -i "s|\"@tanstack/db-ivm\": \"workspace:\*\"|\"${NPM_SCOPE}/db-ivm\": \"workspace:*\"|" packages/db/package.json
sed -i "s|\"name\": \"@tanstack/trailbase-db-collection\"|\"name\": \"${NPM_SCOPE}/trailbase-db-collection\"|" packages/trailbase-db-collection/package.json
sed -i "s|\"@tanstack/db\": \"workspace:\*\"|\"${NPM_SCOPE}/db\": \"workspace:*\"|" packages/trailbase-db-collection/package.json

while IFS= read -r file; do
  sed -i "s|@tanstack/db-ivm|${NPM_SCOPE}/db-ivm|g" "$file"
done < <(rg -l "@tanstack/db-ivm" packages/db | grep -E '\\.(ts|tsx|json)$')

while IFS= read -r file; do
  NPM_SCOPE="$NPM_SCOPE" perl -0pi -e 's/@tanstack\/db(?!-collection-e2e)/$ENV{NPM_SCOPE} . "/db"/ge' "$file"
done < <(rg -l "@tanstack/db" packages/trailbase-db-collection | grep -E '\\.(ts|tsx|json)$')

pnpm install --no-frozen-lockfile --ignore-scripts

# Build in dependency order.
pnpm --filter "${NPM_SCOPE}/db-ivm" build
pnpm --filter "${NPM_SCOPE}/db" build
pnpm --filter "${NPM_SCOPE}/trailbase-db-collection" build

# Keep versions aligned for the Syntrix release track.
pnpm --filter "${NPM_SCOPE}/db-ivm" exec npm version "$BUMP_TYPE" --no-git-tag-version
pnpm --filter "${NPM_SCOPE}/db" exec npm version "$BUMP_TYPE" --no-git-tag-version
pnpm --filter "${NPM_SCOPE}/trailbase-db-collection" exec npm version "$BUMP_TYPE" --no-git-tag-version

pnpm --filter "${NPM_SCOPE}/db-ivm" publish --access public --tag "$DIST_TAG" --no-git-checks
pnpm --filter "${NPM_SCOPE}/db" publish --access public --tag "$DIST_TAG" --no-git-checks
pnpm --filter "${NPM_SCOPE}/trailbase-db-collection" publish --access public --tag "$DIST_TAG" --no-git-checks

echo "Published ${NPM_SCOPE}/db-ivm, ${NPM_SCOPE}/db, and ${NPM_SCOPE}/trailbase-db-collection with bump '$BUMP_TYPE' and tag '$DIST_TAG'."
