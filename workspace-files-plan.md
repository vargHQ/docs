# Workspace-scoped files — implementation plan

> Status: DRAFT for review
> Date: 2026-07-31
> Owner: architecture

## 1. Problem

A workspace (folder) today shows projects but not files. Files live in
`be_files` owned by an **account** (personal or team) — there is no
folder-level grouping. API-only users (curl, API clients) have no way to
organize files into folders at all.

## 1.5 Goals

1. **API-first parity.** Any file-management scenario available in the app
   is available through the API. The app is a view on top, not a gatekeeper.
2. **Reuse without duplication.** One file can be linked into N workspaces.
   No R2 duplication, no double billing for storage. A team asset uploaded
   once appears in every folder it's linked to.
3. **Workspace as a first-class resource unit.** Workspaces work the same
   way as files today: personal scope via `account_id`, team scope via
   `X-Team-Id`, same CRUD pattern.

## 1.6 Definition of Done — Phase 1 (API)

Workspaces work like files today: same ownership pattern (personal via
`account_id`, team via `X-Team-Id`), same set of operations.

> **One sentence:** a curl user can create a workspace → upload a file into
> it → generate a job into it → link an existing file → unlink → list files
> → delete the workspace (files survive). Personal and team — identical.

### Workspace CRUD
- `POST /v2/workspaces { name, slug? }` → creates, returns workspace.
  `account_id` from auth context (personal or team via `X-Team-Id`).
- `GET /v2/workspaces` → lists only the caller's workspaces (by `account_id`).
- `GET /v2/workspaces/:id` → single workspace.
- `PATCH /v2/workspaces/:id { name?, slug? }` → update.
- `DELETE /v2/workspaces/:id` → deletes workspace; `be_workspace_files`
  links removed (cascade); **files stay in `be_files`**.

### Job → workspace auto-link
- `POST /v2/jobs { input, workspace_id }` → validates workspace belongs to
  account, stores `workspace_id` on the job.
- On job completion → each output file is linked to the workspace via
  `be_workspace_files`. Idempotent (`ON CONFLICT DO NOTHING`).
- **DoD:** `POST /v2/image { prompt, workspace_id: "abc" }` → job done →
  `GET /v2/files?workspace=abc` shows the output. No app, no webhooks.

### File ↔ workspace link/unlink
- `POST /v2/workspaces/:id/files { file_id }` → links file into workspace.
  Idempotent. File must belong to the same `account_id`.
- `DELETE /v2/workspaces/:id/files/:file_id` → removes link, file stays.
- `GET /v2/workspaces/:id/files` → paginated list of files in workspace.
- **DoD:** file can be in multiple workspaces; unlink from one → stays in
  others. One file, zero duplicates.

### Upload → workspace
- `POST /v2/files` + `X-Workspace-Id` header → upload + link in one call.
- `POST /v2/files/import { url, workspace_id }` → import + link in one call.
- **DoD:** `curl -H "X-Workspace-Id: abc" -X POST /v2/files --data-binary
  @photo.jpg` → file in workspace abc.

### File list filter
- `GET /v2/files?workspace=<id>` → only files in that workspace.
- `GET /v2/files?workspace=unfiled` → files not in any workspace.
- **DoD:** `GET /v2/files?workspace=abc` and `GET /v2/workspaces/abc/files`
  return the same result.

### Out of scope for Phase 1
- App changes (Phase 2)
- Agent tools (Phase 3)
- Backfill of existing files
- Shared workspace access (app-side sharing proxy)
- Dedicated "move" endpoint (link + unlink covers it)

## 2. Principle

> **If an API-only user cannot do X, then X belongs to the API.**

Organizing files into named containers is resource management, not a UI
concern. It belongs to the API. The app is a view on top.

**End state: the API owns workspace identity.** The existing
`public.workspaces` table stays where it is (same Postgres, same name) —
the API reads and writes it directly, same as it already reads `be_files`.
App-specific concerns (sharing, members, project links) stay in app
reference tables that point to `public.workspaces.id`.

## 3. Design: API uses existing `public.workspaces` directly

### 3.1 No new workspace table, no rename

`public.workspaces` already exists in the same Postgres the API uses. The
API already reads `be_files` from this database. It can read
`public.workspaces` the same way.

**What changes on `public.workspaces`:**
- Add `account_id uuid REFERENCES be_accounts(id)` — the API's ownership
  scope (personal account or team account). Backfilled from `owner_id` /
  `team_id` for existing rows.
- All existing columns (`owner_id`, `team_id`, `name`, `slug`, `visibility`,
  `link_access`, `link_token_hash`, etc.) stay as-is. The app keeps using
  them.

**What's new:**
- `be_workspace_files` — many-to-many junction (file can be in N workspaces)
- `be_varg_jobs.workspace_id` — so finalize knows where to link outputs

### 3.2 Who writes what

| Column | Written by | Used by |
|--------|-----------|---------|
| `id`, `name`, `slug`, `account_id` | API (`POST /v2/workspaces`) or app (delegated) | Both |
| `owner_id`, `team_id` | App (UI creation) | App (RLS, sharing) |
| `visibility`, `link_access`, `link_token_hash` | App (sharing flows) | App (RLS) |
| `created_at`, `updated_at` | Both | Both |

When the API creates a workspace (`POST /v2/workspaces` from curl), it sets
`id`, `name`, `slug`, `account_id`. `owner_id` and `team_id` are null —
the API-only user has no app identity. The app ignores these rows (no
RLS match) unless the user later links their app account.

When the app creates a workspace (UI), it calls `POST /v2/workspaces` first
(API creates the row with `account_id`), then the app updates the same row
with `owner_id`, `team_id`, `visibility`, etc.

### 3.3 App-specific concerns stay in app reference tables

| App table | What it stores | Key |
|-----------|----------------|-----|
| `public.workspace_members` | sharing access per user | `workspace_id → public.workspaces.id` (as today) |
| `public.workspace_share_invites` | email invites | `workspace_id → public.workspaces.id` (as today) |
| `public.projects_workspaces` | project ↔ folder links | `workspace_id → public.workspaces.id` (as today) |

No reference tables are re-pointed. No data is migrated. No table is
renamed. The only schema change is adding `account_id` to
`public.workspaces` and creating the two new API-side objects.

### 3.4 Flows

```
Create folder (UI):
  app  → POST /v2/workspaces { name, slug }        → public.workspaces(id=abc, account_id=…)
  app  → UPDATE public.workspaces SET owner_id=…, team_id=…, visibility=… WHERE id=abc
  app  → INSERT workspace_members(workspace_id=abc, user_id=…)
  app  → INSERT projects_workspaces(project_id=…, workspace_id=abc)

Create folder (API only):
  curl → POST /v2/workspaces { name, slug }        → public.workspaces(id=xyz, account_id=…)
  (owner_id, team_id null — no app identity)

Job:
  POST /v2/jobs { input: {…}, workspace_id: "abc" }
  → finalize: INSERT be_workspace_files(workspace_id=abc, file_id=…)

Link existing file into a workspace (reuse, no duplication):
  POST /v2/workspaces/abc/files { file_id: "file_…" }
  → INSERT be_workspace_files(workspace_id=abc, file_id=…)

List files in folder:
  GET /v2/files?workspace=abc   (API, works for everyone)
```

## 4. Implementation priorities (phased)

### Phase 1 — API: workspace file containers (self-contained, no app changes)

**Goal:** API-only users can create workspaces, link files, and get
workspace-scoped file lists. Zero app changes.

**Deliverables:**
1. Migration: add `account_id` to `public.workspaces` + create
   `be_workspace_files` + add `be_varg_jobs.workspace_id`
2. Backfill `public.workspaces.account_id` from `owner_id` / `team_id`
3. `/v2/workspaces` CRUD (create, list, get, patch, delete)
4. `/v2/workspaces/:id/files` — link/unlink files (POST + DELETE)
5. Job submit accepts `workspace_id` → finalize auto-links output files
6. File upload accepts `workspace_id` (header on binary, body on import)
7. `GET /v2/files?workspace=<id>` filter (+ `?workspace=unfiled`)
8. `serializeVargJob` includes `workspace_id`

**Verification:** curl-only user creates workspace → submits job → files
appear in `GET /v2/files?workspace=<id>`. No app involved.

### Phase 2 — App: pass workspace_id to jobs and uploads

**Goal:** App passes `workspace_id` to the API so files generated through
the app land in the right folder. App resources view filters by workspace.

**Deliverables:**
1. App `POST /api/workspaces` → calls `POST /v2/workspaces` first, then
   updates the row with app fields (`owner_id`, `team_id`, `visibility`)
2. App job submit → resolves `workspace_id` from project → passes to API
3. App upload registration → passes `workspace_id` to `POST /v2/files/import`
4. App resources route → `?workspace=<id>` proxied to `GET /v2/files?workspace=`
5. Workspace page → "Resources" tab showing workspace-scoped files
6. Backfill: derive `be_workspace_files` from existing document graph

**No schema migration of `public.workspaces` needed** — `account_id` was
added in Phase 1. App just starts passing `workspace_id` through.

**Verification:** UI user creates folder → sees projects + resources in it.
Existing folders still work.

### Phase 3 — App agent: workspace-scoped tool access

**Goal:** The AI agent inside the app chat can list, use, and save files
to the current workspace context.

**Deliverables:**
1. Chat tool `getContent` → searches within `workspace_id` scope
2. Chat tool `renderVideo` → output files auto-linked to workspace (via
   `workspace_id` on job submit, already handled by Phase 1 API)
3. Agent can list workspace files via a new tool or extended `getContent`
4. Agent can link an existing file into the current workspace

**Verification:** Agent in a project inside folder X → generates video →
file appears in folder X's resources. Agent can find and reuse files from
folder X.

## 5. API changes (varg-api-proto) — Phase 1 detail

### 5.1 Migration

File: `apps/api/migrations/0128_workspaces.sql`

```sql
-- ── Add account_id to existing public.workspaces ───────────────────────────
-- The API's ownership scope (personal be_accounts or team be_accounts).
-- Backfilled from owner_id / team_id below.
ALTER TABLE public.workspaces
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES be_accounts(id);

CREATE INDEX IF NOT EXISTS idx_workspaces_account_id
  ON public.workspaces (account_id)
  WHERE account_id IS NOT NULL;

-- ── Backfill account_id ────────────────────────────────────────────────────
-- Personal workspaces (team_id IS NULL): account_id = user's personal be_accounts row.
-- Team workspaces (team_id IS NOT NULL): account_id = team's be_accounts row.

-- 1. Personal: match by auth_user_id
UPDATE public.workspaces w
  SET account_id = ba.id
  FROM be_accounts ba
  WHERE w.team_id IS NULL
    AND ba.kind = 'user'
    AND ba.auth_user_id = w.owner_id
    AND w.account_id IS NULL;

-- 2. Team: match by team_id
UPDATE public.workspaces w
  SET account_id = ba.id
  FROM be_accounts ba
  WHERE w.team_id IS NOT NULL
    AND ba.kind = 'team'
    AND ba.team_id = w.team_id
    AND w.account_id IS NULL;

-- 3. For any remaining nulls, auto-provision be_accounts and fill.
--    (Personal workspaces whose owner has no be_accounts row yet.)
INSERT INTO be_accounts (kind, auth_user_id)
  SELECT DISTINCT 'user', w.owner_id
  FROM public.workspaces w
  WHERE w.team_id IS NULL
    AND w.account_id IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM be_accounts ba WHERE ba.auth_user_id = w.owner_id AND ba.kind = 'user'
    )
  ON CONFLICT DO NOTHING;

UPDATE public.workspaces w
  SET account_id = ba.id
  FROM be_accounts ba
  WHERE w.team_id IS NULL
    AND ba.kind = 'user'
    AND ba.auth_user_id = w.owner_id
    AND w.account_id IS NULL;

-- ── be_workspace_files: many-to-many (a file can be in N workspaces) ───────
CREATE TABLE be_workspace_files (
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE CASCADE,
  file_id      text NOT NULL REFERENCES be_files(id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, file_id)
);

CREATE INDEX be_workspace_files_file_idx
  ON be_workspace_files (file_id);

-- ── be_varg_jobs.workspace_id: so finalize knows where to link outputs ────
ALTER TABLE be_varg_jobs
  ADD COLUMN workspace_id uuid REFERENCES public.workspaces(id) ON DELETE SET NULL;
```

Notes:
- **`public.workspaces` is not renamed, not moved, not duplicated.** Only
  `account_id` is added.
- **No `be_files.workspace_id` column.** File→workspace is many-to-many via
  `be_workspace_files`.
- `be_varg_jobs.workspace_id` is nullable — `NULL` = no workspace context.
- `ON DELETE CASCADE` on `be_workspace_files` — deleting a workspace removes
  links, not files.
- `ON DELETE SET NULL` on `be_varg_jobs.workspace_id` — deleting a workspace
  preserves job history.
- `account_id` is nullable during transition; backfilled in the same
  migration. Could add `NOT NULL` after backfill in a follow-up migration.

### 5.2 Schema types (`apps/api/src/db/schema.ts`)

```ts
export interface WorkspaceRecord {
  id: string;
  account_id: string;
  name: string;
  slug: string;
  // app-managed fields (API ignores these, app reads/writes):
  owner_id?: string | null;
  team_id?: string | null;
  visibility?: string | null;
  created_at: string;
  updated_at: string;
}

export interface WorkspaceFileLink {
  workspace_id: string;
  file_id: string;
  created_at: string;
}

// In VargJob, add:
//   workspace_id?: string | null;
```

### 5.3 DB queries

New file `apps/api/src/db/queries/workspaces.ts`:
- `insertWorkspace({ account_id, name, slug })` → inserts into `public.workspaces`
- `listWorkspaces(account_id)` → `WorkspaceRecord[]`
- `getWorkspace(account_id, idOrSlug)` → `WorkspaceRecord | null`
- `updateWorkspace(id, { name?, slug? })` → `WorkspaceRecord`
- `deleteWorkspace(id)` → void
- `assertWorkspaceOwned(account_id, workspace_id)` → throws 404 if not owned

New file `apps/api/src/db/queries/workspaceFiles.ts`:
- `linkFileToWorkspace(workspace_id, file_id)` → INSERT, ON CONFLICT DO NOTHING
- `unlinkFileFromWorkspace(workspace_id, file_id)` → DELETE
- `listWorkspaceFiles(workspace_id, { limit, cursor })` → joins `be_files`
- `listFileWorkspaces(file_id)` → `WorkspaceRecord[]`

Update `apps/api/src/db/queries/files.ts`:
- `listFiles` — add `workspaceId?: string` filter. When set, join
  `be_workspace_files`. When `'unfiled'` sentinel, anti-join (files not in
  any workspace).

### 5.4 Routes

New router `apps/api/src/routes/workspaces/index.ts`, mounted at `/v2/workspaces`:

| Method | Path | Body / Query | Returns |
|--------|------|--------------|---------|
| `POST` | `/` | `{ name, slug? }` | `WorkspaceRecord` (201) |
| `GET` | `/` | — | `WorkspaceRecord[]` |
| `GET` | `/:id` | — | `WorkspaceRecord` |
| `PATCH` | `/:id` | `{ name?, slug? }` | `WorkspaceRecord` |
| `DELETE` | `/:id` | — | 204 |
| `POST` | `/:id/files` | `{ file_id }` | `WorkspaceFileLink` (201) |
| `DELETE` | `/:id/files/:file_id` | — | 204 |
| `GET` | `/:id/files` | `?limit&cursor` | paginated `FileRecord[]` |

All scoped to `c.get("accountId")` — filters `public.workspaces` by
`account_id`. `X-Team-Id` header switches to team account (existing
middleware, zero extra code).

Wire in `apps/api/src/index.ts`:
```ts
app.route("/v2/workspaces", workspacesRouter);
```

### 5.5 Job submit: accept `workspace_id`

The unified tool body (`ValidatedToolBody`) is an open object
(`[key: string]: unknown`), so `workspace_id` passes validation without
schema changes to individual tools.

**Files to touch:**

1. `apps/api/src/routes/varg_jobs/create.ts` — `handleCreate`:
   - Extract `workspace_id` from `body` before `toInput(body)`.
   - Validate: `assertWorkspaceOwned(accountId, workspace_id)` if present.
   - Pass to `createJob({ …, workspaceId })`.

2. `apps/api/src/services/jobs/dispatch.ts` — `createJob`:
   - Add `workspaceId?: string` to args.
   - Store on the `VargJob` row (new `workspace_id` column).

3. `apps/api/src/db/queries/jobs.ts` — `insertVargJob`:
   - Include `workspace_id` in the insert.

### 5.6 Job finalize: auto-link output files to workspace

**File:** `apps/api/src/services/jobs/finalize.ts`

In `buildTerminalPatch` → `finalizeOutput` → `mirrorOne`:

- Thread `workspaceId` from `existing.workspace_id` through `finalizeOutput`
  into `mirrorOne`.
- After `insertFileWithRetry` succeeds, call `linkFileToWorkspace`:

```ts
await insertFileWithRetry({ id: fileId, account_id: accountId, … });
if (opts.workspaceId) {
  await linkFileToWorkspace(opts.workspaceId, fileId);  // ← NEW
}
```

This is the **single point** where generated files get linked to a workspace.
No webhooks, no app involvement. The job knew its workspace at submit time;
the file gets linked at finalize time.

`linkFileToWorkspace` uses `ON CONFLICT DO NOTHING` — if the file is already
linked (e.g. reused from cache), it's a no-op.

### 5.7 File upload: accept `workspace_id`

**`POST /v2/files`** (binary, `apps/api/src/routes/files/index.ts`):
- Accept `X-Workspace-Id` header. Validate ownership. After `insertFile`,
  call `linkFileToWorkspace`.

**`POST /v2/files/import`** (URL import):
- Accept `workspace_id` in JSON body. Validate ownership. After `insertFile`,
  call `linkFileToWorkspace`.

### 5.8 File list: filter by workspace

**`GET /v2/files`** (`apps/api/src/routes/files/index.ts`):
- Accept `?workspace=<id>` query param → filter via `be_workspace_files` join.
- Accept `?workspace=unfiled` → files not in any workspace.
- Pass to `listFiles(accountId, { workspaceId })`.

### 5.9 Serialization

`apps/api/src/routes/varg_jobs/common.ts` — `serializeVargJob`:
- Add `workspace_id: j.workspace_id ?? null` to output.
- Do **NOT** strip in `sanitizeLineageInput` — first-class field.

## 6. App changes — Phase 2 detail

### 6.1 Workspace creation: API-first

**File:** `src/app/api/workspaces/route.ts` — `POST` handler

```ts
// 1. Create via API (sets id, account_id, name, slug)
const apiWorkspace = await vargApiPost('/v2/workspaces', { name, slug }, auth)

// 2. Update the same row with app fields
await supabase
  .from('workspaces')
  .update({ owner_id: user.id, team_id: teamId, visibility })
  .eq('id', apiWorkspace.id)

// 3. Write app reference rows
await supabase.from('workspace_members').insert({
  workspace_id: apiWorkspace.id,
  user_id: user.id,
  access_level: 'write',
  access_source: 'direct',
})
```

If the API call fails → no app row created (atomicity: API-first).

### 6.2 Job submit from chat: pass `workspace_id`

**File:** `src/app/api/_shared/jobs/register-job.ts`

1. Resolve `workspace_id` from `project_id → projects_workspaces → workspace_id`.
2. Pass `workspace_id` in the job body to varg-api.

### 6.3 File upload from app: pass `workspace_id`

**File:** `src/app/api/attachments/register/route.ts`

- Resolve `workspace_id` from current workspace context.
- Pass to `POST /v2/files/import` as `workspace_id` in the body.

### 6.4 Resources view: filter by workspace

**File:** `src/app/api/resources/files/route.ts`

- `?workspace=<id>` → forward to varg-api `GET /v2/files?workspace=<id>`.
- `ResourceAll` view → accept `workspaceId`, pass to fetch hooks.

### 6.5 Workspace page: resources tab

**New route:** `src/app/dashboard/workspace/[slug]/resources/all/page.tsx`

Renders `<ResourceAll workspaceId={id} />` — reuses existing component,
scoped to a workspace.

### 6.6 Backfill existing files

One-time script: derive `be_workspace_files` links from the document graph:

```sql
INSERT INTO be_workspace_files (workspace_id, file_id)
SELECT DISTINCT pw.workspace_id, m.be_file_id
FROM projects_workspaces pw
JOIN documents d ON d.project_id = pw.project_id
JOIN document_media dm ON dm.document_id = d.id
JOIN media m ON m.id = dm.media_id
WHERE m.be_file_id IS NOT NULL
ON CONFLICT DO NOTHING;
```

## 7. App agent changes — Phase 3 detail

### 7.1 getContent tool: workspace scope

**File:** `src/app/api/chat/tools/` (getContent tool)

When the chat runs inside a project that belongs to a workspace:
- `getContent` search queries `GET /v2/files?workspace=<id>&q=<query>`
  instead of account-wide search.
- This scopes the agent's media retrieval to the current folder.

### 7.2 renderVideo tool: workspace auto-link

Already handled by Phase 1 + Phase 2: the app passes `workspace_id` on job
submit → API auto-links output files. No extra agent code needed.

### 7.3 New tool: listWorkspaceFiles (optional)

A tool that lets the agent enumerate files in the current workspace:
- `listWorkspaceFiles({ type?: 'image'|'video'|'audio', limit?: number })`
- Returns file URLs + metadata from `GET /v2/files?workspace=<id>`.

### 7.4 New tool: linkFileToWorkspace (optional)

A tool that lets the agent reuse a file from elsewhere:
- `linkFileToWorkspace({ file_id })`
- Calls `POST /v2/workspaces/:id/files { file_id }`.

## 8. What is NOT changing

- `public.workspaces` table name, columns, RLS, sharing helpers — all stay.
  Only `account_id` is added.
- `workspace_members`, `workspace_share_invites`, `projects_workspaces` —
  stay as-is, same FKs to `public.workspaces.id`.
- `be_files.metadata` — stays for physical file props.
- Webhook delivery — stays for job notifications, not for file linking.
- App RLS (`can_read_workspace`, `can_write_workspace`, etc.) — unchanged.

## 9. Verification checklist

### Phase 1 — API
- [ ] Migration `0128_workspaces.sql` applies cleanly on staging
- [ ] `account_id` backfilled for all existing `public.workspaces` rows
- [ ] `POST /v2/workspaces` creates a workspace, returns it
- [ ] `GET /v2/workspaces` lists only the caller's workspaces (by account_id)
- [ ] `X-Team-Id` header switches to team workspaces
- [ ] `POST /v2/workspaces/:id/files` links a file (idempotent on re-link)
- [ ] `DELETE /v2/workspaces/:id/files/:file_id` unlinks (file stays in be_files)
- [ ] `POST /v2/jobs` with `workspace_id` validates ownership (404 if not owned)
- [ ] Job finalize links output files to workspace via `be_workspace_files`
- [ ] `GET /v2/files?workspace=<id>` returns only files in that workspace
- [ ] `GET /v2/files?workspace=unfiled` returns files not in any workspace
- [ ] `POST /v2/files` with `X-Workspace-Id` links on upload
- [ ] `POST /v2/files/import` with `workspace_id` links on import
- [ ] `serializeVargJob` includes `workspace_id`
- [ ] Deleting a workspace removes `be_workspace_files` links (files survive)
- [ ] Same file linked to 2 workspaces appears in both `GET /v2/files?workspace=`
- [ ] API-only user: full flow (create workspace → job → list files) without app
- [ ] App still works unchanged (existing workspaces, RLS, sharing)

### Phase 2 — App
- [ ] `POST /api/workspaces` creates via API first, then updates with app fields
- [ ] App job submit resolves + passes `workspace_id`
- [ ] App upload registration passes `workspace_id`
- [ ] `GET /api/resources/files?workspace=<id>` proxies to API
- [ ] Workspace page shows "Resources" tab
- [ ] Backfill: historical files linked to workspaces via document graph
- [ ] Existing personal/team resources views still work (no workspace = all files)
- [ ] Sharing still works (invite user, link share, read/write access)

### Phase 3 — Agent
- [ ] `getContent` scopes search to current workspace
- [ ] `renderVideo` output files auto-linked to workspace
- [ ] Agent can list workspace files (if listWorkspaceFiles tool added)
- [ ] Agent can link an existing file into current workspace

### Edge cases
- [ ] Job without `workspace_id` → output files not linked to any workspace
- [ ] Workspace deleted → `be_workspace_files` links removed, files survive,
      `be_varg_jobs.workspace_id` set to NULL
- [ ] File in workspace A, used as input in workspace B → stays in A only
      (no auto-move; user can manually link via POST /v2/workspaces/B/files)
- [ ] Team workspace: `X-Team-Id` + `workspace_id` work together
- [ ] Cached job (cache hit): file already exists → `linkFileToWorkspace` is
      idempotent (`ON CONFLICT DO NOTHING`)
- [ ] API-created workspace (owner_id null) is invisible to app RLS — only
      visible via API. If the user later signs in via app, they need to claim
      it (match by account_id).

## 10. Open questions

1. **`account_id` NOT NULL**: add as nullable in Phase 1 (backfill in same
   migration), then add `NOT NULL` in a follow-up migration once confirmed
   all rows are populated. Recommendation: yes.

2. **API-created workspaces with `owner_id = null`**: if a curl user later
   signs into the app, their API-created workspaces won't match app RLS
   (which checks `owner_id = auth.uid()`). Options: (a) app claims them by
   matching `account_id` to the user's be_accounts row, (b) the app sets
   `owner_id` on first login. Recommendation: (a) — a one-time claim query
   on login.

3. **Workspace slug auto-generation**: API enforces `(account_id, slug)`
   unique. Should the API auto-generate a slug if none is provided?
   Recommendation: yes, fallback to `nanoid(10)`.

4. **Shared workspace file access (Phase 2)**: A user with app-shared read
   access to a workspace queries `GET /v2/files?workspace=<id>` — but the
   API returns 404 because the workspace's `account_id` belongs to a
   different account. The app's resources route needs to proxy with the
   workspace owner's account context. Not blocking Phase 1.

5. **Moving files between workspaces**: `POST /v2/workspaces/:id/files` +
   `DELETE /v2/workspaces/:old_id/files/:file_id` = move. Should there be a
   dedicated move endpoint? Recommendation: no — link/unlink is more
   flexible (a file can be in multiple workspaces).
