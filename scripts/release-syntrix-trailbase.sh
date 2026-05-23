#!/usr/bin/env bash
set -euo pipefail

BUMP_TYPE="${1:-patch}"
DIST_TAG="${2:-latest}"

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
sed -i "s/\"name\": \"@tanstack\/db-ivm\"/\"name\": \"@syntrix\/db-ivm\"/" packages/db-ivm/package.json
sed -i "s/\"name\": \"@tanstack\/db\"/\"name\": \"@syntrix\/db\"/" packages/db/package.json
sed -i "s/\"@tanstack\/db-ivm\": \"workspace:\*\"/\"@syntrix\/db-ivm\": \"workspace:*\"/" packages/db/package.json
sed -i "s/\"name\": \"@tanstack\/trailbase-db-collection\"/\"name\": \"@syntrix\/trailbase-db-collection\"/" packages/trailbase-db-collection/package.json
sed -i "s/\"@tanstack\/db\": \"workspace:\*\"/\"@syntrix\/db\": \"workspace:*\"/" packages/trailbase-db-collection/package.json

while IFS= read -r file; do
  sed -i "s/@tanstack\/db-ivm/@syntrix\/db-ivm/g" "$file"
done < <(rg -l "@tanstack/db-ivm" packages/db | grep -E '\\.(ts|tsx|json)$')

while IFS= read -r file; do
  perl -0pi -e "s/@tanstack\\/db(?!-collection-e2e)/@syntrix\\/db/g" "$file"
done < <(rg -l "@tanstack/db" packages/trailbase-db-collection | grep -E '\\.(ts|tsx|json)$')

pnpm install --no-frozen-lockfile --ignore-scripts

# Build in dependency order.
pnpm --filter @syntrix/db-ivm build
pnpm --filter @syntrix/db build
pnpm --filter @syntrix/trailbase-db-collection build

# Keep versions aligned for the Syntrix release track.
pnpm --filter @syntrix/db-ivm exec npm version "$BUMP_TYPE" --no-git-tag-version
pnpm --filter @syntrix/db exec npm version "$BUMP_TYPE" --no-git-tag-version
pnpm --filter @syntrix/trailbase-db-collection exec npm version "$BUMP_TYPE" --no-git-tag-version

pnpm --filter @syntrix/db-ivm publish --access public --tag "$DIST_TAG" --no-git-checks
pnpm --filter @syntrix/db publish --access public --tag "$DIST_TAG" --no-git-checks
pnpm --filter @syntrix/trailbase-db-collection publish --access public --tag "$DIST_TAG" --no-git-checks

echo "Published @syntrix/db-ivm, @syntrix/db, and @syntrix/trailbase-db-collection with bump '$BUMP_TYPE' and tag '$DIST_TAG'."
