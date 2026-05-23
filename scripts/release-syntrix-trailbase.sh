#!/usr/bin/env bash
set -euo pipefail

BUMP_TYPE="${1:-patch}"
DIST_TAG="${2:-latest}"
NPM_SCOPE="${3:-@roy.alcala}"
DO_PUBLISH="${4:-true}"

REPO_ROOT="$(pwd)"
TMP_DIR="$(mktemp -d)"
TMP_REPO="${TMP_DIR}/db"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

publish_or_tag() {
  local pkg_dir="$1"
  local pkg_name="$2"
  local pkg_version="$3"

  cd "$pkg_dir"
  if npm publish --access public --tag "$DIST_TAG"; then
    cd ../../
    return 0
  fi

  # NPM versions are immutable. If this version already exists, just move/add the dist-tag.
  if npm view "$pkg_name@$pkg_version" version >/dev/null 2>&1; then
    npm dist-tag add "$pkg_name@$pkg_version" "$DIST_TAG"
    cd ../../
    return 0
  fi

  cd ../../
  return 1
}

case "$BUMP_TYPE" in
  patch|minor|major|prepatch|preminor|premajor|prerelease) ;;
  *)
    echo "Invalid bump type: $BUMP_TYPE"
    echo "Use one of: patch|minor|major|prepatch|preminor|premajor|prerelease"
    exit 1
    ;;
esac

case "$DO_PUBLISH" in
  true|false) ;;
  *)
    echo "Invalid publish flag: $DO_PUBLISH"
    echo "Use true or false"
    exit 1
    ;;
esac

if [[ ! -d "${REPO_ROOT}/.git" ]]; then
  echo "Run this script from the repository root."
  exit 1
fi

git clone --quiet "${REPO_ROOT}" "${TMP_REPO}"
cd "${TMP_REPO}"

replace_text_tree() {
  local target_dir="$1"
  local search_pattern="$2"
  local replacement="$3"

  while IFS= read -r -d '' file; do
    if grep -q "$search_pattern" "$file"; then
      SEARCH_PATTERN="$search_pattern" REPLACEMENT="$replacement" perl -0pi -e 's/\Q$ENV{SEARCH_PATTERN}\E/$ENV{REPLACEMENT}/g' "$file"
    fi
  done < <(find "$target_dir" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.cjs' -o -name '*.mjs' -o -name '*.d.ts' -o -name '*.d.cts' -o -name '*.json' \) -print0)
}

pnpm install --frozen-lockfile --ignore-scripts

# Build in dependency order.
pnpm --filter @tanstack/db-ivm build
pnpm --filter @tanstack/db build
pnpm --filter @tanstack/trailbase-db-collection build

# Prepare scoped package metadata and imports after build.
sed -i "s|\"name\": \"@tanstack/db-ivm\"|\"name\": \"${NPM_SCOPE}/db-ivm\"|" packages/db-ivm/package.json

sed -i "s|\"name\": \"@tanstack/db\"|\"name\": \"${NPM_SCOPE}/db\"|" packages/db/package.json
sed -i "s|\"@tanstack/db-ivm\": \"workspace:\*\"|\"${NPM_SCOPE}/db-ivm\": \"workspace:*\"|" packages/db/package.json
replace_text_tree "packages/db/src" "@tanstack/db-ivm" "${NPM_SCOPE}/db-ivm"
replace_text_tree "packages/db/dist" "@tanstack/db-ivm" "${NPM_SCOPE}/db-ivm"

sed -i "s|\"name\": \"@tanstack/trailbase-db-collection\"|\"name\": \"${NPM_SCOPE}/trailbase-db-collection\"|" packages/trailbase-db-collection/package.json
sed -i "s|\"@tanstack/db\": \"workspace:\*\"|\"${NPM_SCOPE}/db\": \"workspace:*\"|" packages/trailbase-db-collection/package.json
replace_text_tree "packages/trailbase-db-collection/src" "@tanstack/db" "${NPM_SCOPE}/db"
replace_text_tree "packages/trailbase-db-collection/dist" "@tanstack/db" "${NPM_SCOPE}/db"

# Keep versions aligned for the Syntrix release track.
cd packages/db-ivm
npm version "$BUMP_TYPE" --no-git-tag-version
DB_IVM_VERSION="$(node -p "require('./package.json').version")"
cd ../db
npm version "$BUMP_TYPE" --no-git-tag-version
DB_VERSION="$(node -p "require('./package.json').version")"
cd ../trailbase-db-collection
npm version "$BUMP_TYPE" --no-git-tag-version
TRAILBASE_VERSION="$(node -p "require('./package.json').version")"
cd ../../

if [[ "$DO_PUBLISH" == "true" ]]; then
  publish_or_tag "packages/db-ivm" "${NPM_SCOPE}/db-ivm" "$DB_IVM_VERSION"
  publish_or_tag "packages/db" "${NPM_SCOPE}/db" "$DB_VERSION"
  publish_or_tag "packages/trailbase-db-collection" "${NPM_SCOPE}/trailbase-db-collection" "$TRAILBASE_VERSION"
  echo "Published ${NPM_SCOPE}/db-ivm, ${NPM_SCOPE}/db, and ${NPM_SCOPE}/trailbase-db-collection with bump '$BUMP_TYPE' and tag '$DIST_TAG'."
else
  echo "Publish skipped (DO_PUBLISH=false)."
  echo "Prepared ${NPM_SCOPE}/db-ivm, ${NPM_SCOPE}/db, and ${NPM_SCOPE}/trailbase-db-collection with bump '$BUMP_TYPE' and tag '$DIST_TAG'."
fi
