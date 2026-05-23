#!/usr/bin/env bash
set -euo pipefail

TARGET_BRANCH="${1:-syntrix-main}"
UPSTREAM_BRANCH="${2:-main}"

current_branch="$(git branch --show-current)"

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "Missing 'upstream' remote. Add it with: git remote add upstream https://github.com/TanStack/db.git"
  exit 1
fi

git fetch upstream "${UPSTREAM_BRANCH}"
git switch "${TARGET_BRANCH}"
git merge --no-ff "upstream/${UPSTREAM_BRANCH}" -m "chore(sync): merge upstream/${UPSTREAM_BRANCH} into ${TARGET_BRANCH}"
git push origin "${TARGET_BRANCH}"

echo "Synced ${TARGET_BRANCH} with upstream/${UPSTREAM_BRANCH}."

git switch "${current_branch}" >/dev/null 2>&1 || true
