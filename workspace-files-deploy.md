# Deploying folders (workspaces) — runbook

Covers `vargHQ/api#90` and `vargHQ/app#311`.

State at the time of writing, verified directly against both databases:

| | staging | production |
|---|---|---|
| `0128` (`be_workspace_files`, `be_varg_jobs.workspace_id`) | applied | **applied** |
| app `20260731000000` (`workspaces.account_id`) | applied | **applied** |
| `0129` (`be_file_creators` 2-arg) | applied | **NOT applied** |
| API code | deployed (`varg-api-proto`) | not deployed |
| App code | deployed (`stage.varg.ai`) | not deployed |
| Folders with `account_id IS NULL` | 0 | 1 (see step 5) |

Production already carries the schema from `0128` and the app migration — they
were applied during development. Only `0129` is outstanding there.

---

## Order — this part matters

```
1. api#90 merge  →  2. apply 0129 to prod  →  3. deploy varg-api  →  4. app#311 merge → deploy app
```

**The API must ship before the app.** The app sends `?workspace=` and
`X-Workspace-Id`; against today's production API those are ignored, so a
folder's Resources tab would show the entire account instead of the folder, and
`/v2/workspaces` would 404. The reverse order is harmless — the new API is a
no-op for clients that never send those.

**`0129` must be applied before the API code is deployed.** The new code calls
`be_file_creators(p_account_id, p_workspace_id)`; production still has the
one-argument version, so the creator tab strip would fail until the migration
lands. The migration is safe to apply on its own — see step 2.

---

## 1. Merge `vargHQ/api#90`

Merge to `main`. Nothing deploys automatically.

## 2. Apply `0129` to production

```bash
cd api/varg-api-proto/apps/api
# .env.prod → jawyggwaylpehmatvwni
set -a; . ./.env.prod; set +a
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/0129_file_creators_workspace.sql
```

Expect `BEGIN / DROP FUNCTION / CREATE FUNCTION / COMMIT`.

Why the `DROP` is in there: adding a second argument with `DEFAULT NULL` creates
an **overload** rather than replacing the function, and then every existing
one-argument call fails with `function be_file_creators(uuid) is not unique`.
Both statements are in one transaction, so nothing observes a gap.

Verify — exactly one signature, taking two arguments:

```bash
psql "$DATABASE_URL" -c \
  "SELECT oid::regprocedure FROM pg_proc WHERE proname='be_file_creators';"
# expected: be_file_creators(uuid,uuid)
```

**Compatibility:** `p_workspace_id = NULL` reproduces the old behaviour exactly,
so the currently deployed production API keeps working between this step and
step 3. There is no window where the two must ship together.

**Rollback:** re-run `migrations/0126_file_creators_dedupe.sql`, which recreates
the one-argument version. Do that only if the API is *also* rolled back — the
new code passes two arguments.

## 3. Deploy the API to production

```bash
cd api/varg-api-proto/apps/api
git checkout main && git pull
fly deploy -c fly.prod.toml     # fly app varg-api → api.varg.ai
```

Smoke test with a **production** key:

```bash
K='varg_...'; API='https://api.varg.ai'

curl -s "$API/v2/workspaces?limit=3" -H "Authorization: Bearer $K" | jq '.data[] | {slug,name}'
curl -s "$API/v2/resources/files?workspace=unfiled&limit=2" -H "Authorization: Bearer $K" | jq '.data | length'
curl -s "$API/v2/resources/creators" -H "Authorization: Bearer $K" | jq '.data | length'
curl -s -o /dev/null -w '%{http_code}\n' \
  "$API/v2/resources/files?workspace=definitely-not-a-folder" -H "Authorization: Bearer $K"   # expect 404
```

The third call is the one that proves `0129` landed — it fails if the migration
was skipped.

## 4. Merge and deploy the app

Merge `vargHQ/app#311` to `main`, then deploy that project on Vercel
(`app.varg.ai`, project `prj_Dln8NsLjIQgCkydSXhmIVbw8AWiY`).

Note `develop` is the repo's *default* branch and already carries this code —
it is what `stage.varg.ai` serves. The PR deliberately targets `main`.

Smoke test in the browser, signed in:

- `/dashboard/resources/files` — toolbar, search, creator tabs, Upload
- open a folder → **Resources** tab → only that folder's files
- filter by Image inside the folder → the count narrows
- `/dashboard/resources/renders` → redirects to `?tool=render`
- create a new folder, generate an image inside its project → the file appears
  in that folder's Resources tab on its own

## 5. Backfill `account_id` (optional, after step 4)

`workspaces.account_id` is how the API recognises a folder as yours. Production
has **one** folder with it null, and that folder's owner has no `be_accounts`
row at all — the documented "never touched the API" case, not a defect. It stays
invisible to the API and keeps working in the app, exactly as before.

Nothing needs doing. If more appear later (someone gets an account after
creating folders), the same backfill the migration used will pick them up:

```sql
UPDATE public.workspaces w SET account_id = a.id FROM be_accounts a
 WHERE w.team_id IS NOT NULL AND a.team_id = w.team_id AND w.account_id IS NULL;
UPDATE public.workspaces w SET account_id = a.id FROM be_accounts a
 WHERE w.team_id IS NULL AND a.auth_user_id = w.owner_id AND w.account_id IS NULL;
```

Run the `SELECT count(*) ... WHERE account_id IS NULL` first to see the scope.

---

## If something goes wrong

**Roll back the API** — `fly releases -a varg-api`, then
`fly deploy -c fly.prod.toml --image <previous>`. Leave `0128`/`0129` in place:
both are additive and the old code ignores them.

**Roll back the app** — promote the previous Vercel deployment. The API tolerates
a client that stops sending folder params.

**Do not roll back the migrations** unless the API goes back too. `0129` is the
only one with a code dependency in that direction.

## Known non-issues

- **A folder's creator strip does not appear when it holds one author's files.**
  Deliberate: a one-button filter strip filters nothing.
- **`X-Team-Id` is ignored on the API-key path** (`auth/middleware.ts`) — a key
  already selects its account. A personal key cannot reach a team folder and
  will 404; use a team-scoped key. This bites when testing with curl.
- **Playground generations are not filed** into any folder — it has no project
  and no folder in scope.
- **Two pre-existing test failures** in `worker.test.ts` (`computeActualCost`),
  present on `main` before this work.
