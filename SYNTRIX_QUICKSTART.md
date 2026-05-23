# Syntrix Fork Quick Start

## Current Setup
- **Default branch:** `syntrix-main`
- **Fork owner:** `royalcala`
- **Upstream:** `TanStack/db` (main branch)
- **NPM scope (default):** `@roy.alcala` (override supported in workflow input)

---

## Daily Operations

### 1. Sync with upstream/main
**Local sync (manual):**
```bash
pnpm sync:upstream
```

**What it does:**
- Fetches `upstream/main`
- Merges into `syntrix-main` with a merge commit
- Pushes to `origin/syntrix-main`

**Or use GitHub Actions (automated):**
- Runs daily at 11:00 UTC
- Manual trigger: https://github.com/royalcala/db/actions/workflows/sync-upstream.yml

---

### 2. Work on fixes
```bash
# Create fix branch from syntrix-main
git checkout -b fix/your-fix-name

# Make changes (focus on packages/trailbase-db-collection)
# ...

# Test
pnpm --filter @tanstack/trailbase-db-collection build
pnpm --filter @tanstack/trailbase-db-collection test

# Push and merge to syntrix-main
git push origin fix/your-fix-name
# Then create PR or merge directly
```

---

### 3. Publish scoped packages
**Manual release (local):**
```bash
# Bump patch version (default)
pnpm release:syntrix:trailbase

# Or with custom bump
bash scripts/release-syntrix-trailbase.sh minor latest

# Or with custom scope
bash scripts/release-syntrix-trailbase.sh minor latest @syntrix

# Test full pipeline without publishing
bash scripts/release-syntrix-trailbase.sh patch next @roy.alcala false
```

What it does:
1. Clones repo to temp directory
2. Renames `@tanstack/*` → target scope packages (default `@roy.alcala/*`)
3. Builds in dependency order: db-ivm → db → trailbase
4. Bumps versions
5. Publishes to npm with dist-tag

**Or use GitHub Actions (manual):**
- Go to: https://github.com/royalcala/db/actions/workflows/release-syntrix-trailbase.yml
- Click "Run workflow" 
- Select bump type (patch/minor/major/prerelease) and dist-tag
- Keep `npmScope` as `@roy.alcala` (or override)
- Watch logs in Actions tab

---

## Key Files
- `.github/workflows/sync-upstream.yml` — Auto-sync scheduler
- `.github/workflows/release-syntrix-trailbase.yml` — Publish workflow
- `scripts/sync-upstream-main.sh` — Local sync script
- `scripts/release-syntrix-trailbase.sh` — Local release script
- `docs/guides/syntrix-maintenance.md` — Full documentation

---

## Troubleshooting

**"Cannot find module @tanstack/db"**
- Run `pnpm install --no-frozen-lockfile` to regenerate lockfile after scope changes

**Release fails with "Cannot find module..."**
- This is expected if running from main workspace; use script which handles it in isolated clone
- Local: `pnpm release:syntrix:trailbase`
- GitHub Actions: workflow handles isolation automatically

**Sync pull fails**
- Check if `upstream` remote exists: `git remote -v`
- If missing: `git remote add upstream https://github.com/TanStack/db.git`

---

## Branch Strategy
- `syntrix-main` = default, always deployable
- `fix/*` branches = short-lived, merge back to syntrix-main quickly
- Never force-push after merge

## Publishing Checklist
- [ ] Tests pass: `pnpm --filter @tanstack/trailbase-db-collection test`
- [ ] Changes are in syntrix-main
- [ ] NPM_TOKEN secret exists in GitHub Actions
- [ ] Target npm scope exists and you have publish access
