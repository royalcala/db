# Syntrix fork maintenance workflow

This repository keeps a fast-track fork of TanStack DB with a primary focus on the Trailbase adapter.

## Branch model

- `syntrix-main`: default branch for independent development and releases
- short-lived fix branches: branch off `syntrix-main` and merge back quickly

## Upstream sync (Option A)

Run this from the repository root:

```bash
pnpm sync:upstream
```

What it does:

1. Fetches `upstream/main`
2. Merges it into `syntrix-main` with a merge commit
3. Pushes `syntrix-main` to `origin`

Automated sync is also available through `.github/workflows/sync-upstream.yml`.

## Independent publishing under `@syntrix`

Focused package stack:

- `@syntrix/db-ivm`
- `@syntrix/db`
- `@syntrix/trailbase-db-collection`

Manual local release command:

```bash
pnpm release:syntrix:trailbase
```

Release flow:

1. Build all three packages in dependency order
2. Rewrite package names to `@syntrix/*` inside an isolated temporary clone
3. Bump versions (default `patch`)
4. Publish to npm using `latest` dist-tag

The same flow is available in GitHub Actions via `.github/workflows/release-syntrix-trailbase.yml`.

Required repository secret:

- `NPM_TOKEN`: npm token with publish permissions for the `@syntrix` scope

## Trailbase-first development checklist

- Prefer shipping adapter fixes to `packages/trailbase-db-collection` first
- Keep compatibility checks against upstream `main` after each sync
- Run package tests before publishing:

```bash
pnpm --filter @syntrix/trailbase-db-collection test
pnpm --filter @syntrix/trailbase-db-collection test:e2e
```
