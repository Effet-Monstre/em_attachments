# Detailed Implementation Plan

## Checklist

1. Drop the cache store — remove `:cache` config key, `Config.cache/1`, and all cache-phase backend logic in the pipeline
2. Create a Mix task `mix em_attachments.gen.migration` that generates the `em_attachments_uploads` tracking table migration; create `EmAttachments.Upload` Ecto schema with `insert_pending`, `mark_permanent`, `expired_pending`, and `all_permanent`
3. After `backend.put` in the pipeline, insert a `:pending` row into the tracking table (outside the user's transaction)
4. In `prepare_changes`, call `mark_permanent(repo, asset_id)` instead of promoting — no file copy; if the transaction rolls back the row stays `:pending` and the sweeper cleans it up
5. Create `EmAttachments.Sweeper` GenServer that periodically deletes expired `:pending` rows (calls `uploader.delete` then removes the row) and handles `:not_found` from the backend as already-deleted
6. In the same sweeper tick, process `:permanent` rows: call `backend.finalize(id, finalize_opts)` (new optional callback, e.g. change S3 ACL), call `uploader.after_confirm(file)` (dispatches new optional `plugin.after_confirm/2`), then delete the row
7. In the sweeper, treat `{:error, :not_found}` from `backend.delete/2` or `backend.finalize/2` as success — log a warning and delete the row to avoid pileup
8. Redesign config: drop `:cache`, add `:repo`, `:expiry`, `:finalize_opts`, `:sweeper_interval`
9. Update pipeline and plugins: `upload/3` storage context becomes `{backend_mod, backend_opts}` (no phase atom); add optional `after_confirm/2` to plugin behaviour; add optional `finalize/2` to backend behaviour; simplify derivatives plugin by removing the copy-to-store phase
10. Fix tests: remove cache/promote tests, add sweeper, mark_permanent, after_confirm, and finalize tests

---

## Overview

Remove the two-backend (cache → store) architecture. Instead, upload files **directly to the store backend**, track unconfirmed uploads in a DB table, and confirm them atomically with the Ecto transaction. A GenServer sweeps orphaned pending assets and runs optional post-confirmation hooks.

**Old flow:**

```
upload → cache backend → prepare_changes copies → store backend → delete from cache
```

**New flow:**

```
upload → store backend (as :pending) → DB row inserted → prepare_changes marks :permanent → GenServer finalizes
```

---

## 1. Drop Cache Store

- Remove `:cache` config key; raise a helpful error if found during startup pointing to migration guide
- Remove `Config.cache/1` function
- Remove all cache-phase backend.put logic in `pipeline.ex`
- Remove `promote/3` from `pipeline.ex` (or keep as deprecated no-op that logs a warning)
- `BackendFile` and `MemoryFile` can stay — used for plugin processing, just no longer pipeline-promoted
- Remove the cache-specific backend initialization path in `Config`

---

## 2. DB Tracking Table

**New Mix task:** `mix em_attachments.gen.migration`

Generates an Ecto migration into the host app. Table: `em_attachments_uploads`.

```elixir
create table(:em_attachments_uploads) do
  add :asset_id,   :string,             null: false  # file ID in backend
  add :uploader,   :string,             null: false  # "MyApp.AvatarUploader"
  add :serialized, :text,               null: false  # full JSON-serialized file struct (for cleanup/finalize)
  add :status,     :string,             null: false, default: "pending"  # "pending" | "permanent"
  add :expires_at, :utc_datetime_usec,  null: false
  timestamps(updated_at: false)
end

create index(:em_attachments_uploads, [:status, :expires_at])
create index(:em_attachments_uploads, [:asset_id], unique: true)
```

**New module:** `EmAttachments.Upload` — thin Ecto schema for this table.
Functions needed:

- `insert_pending(repo, attrs)` — called right after `backend.put` in pipeline
- `mark_permanent(repo, asset_id)` — called inside `prepare_changes`
- `expired_pending(repo, limit)` — query for sweeper cleanup
- `all_permanent(repo, limit)` — query for sweeper finalization

---

## 3. Upload Pipeline Changes (`uploader/pipeline.ex`)

### Single-phase upload

- `upload/3` uploads directly to the store backend (no cache backend)
- After `backend.put(id, source, store_opts)` succeeds, insert a pending row:

```elixir
EmAttachments.Upload.insert_pending(repo!, %{
  asset_id:   id,
  uploader:   uploader_name,
  serialized: serialize(file_struct),
  status:     :pending,
  expires_at: DateTime.add(DateTime.utc_now(), Config.expiry(), :millisecond)
})
```

- The DB insert happens **outside** the user's Ecto transaction — if the transaction rolls back, the row stays as `:pending` and the sweeper handles cleanup
- Remove `promote/3` (no file copying needed)

### Plugin execution — single phase

- Pass `{backend_mod, backend_opts}` as the storage context to `upload/3` (was `{:cache | :store, backend_mod, backend_opts}`)
- `init/2` unchanged — still runs before `upload/3` for metadata extraction
- No second "store-phase" run of plugins
- `ctx.deps` now only contains results from `init/2` and earlier plugins in topological order (no cache-phase vs. store-phase split)

---

## 4. Ecto Integration Changes (`ecto.ex`)

### `cast_attachments` — new `prepare_changes` flow

```elixir
# Before (copy from cache to store):
prepare_changes(changeset, fn cs ->
  {:ok, stored_file} = uploader.promote(cached_file, call_opts)
  if prev_file, do: uploader.delete(prev_file)
  put_change(cs, key, stored_file)
end)

# After (mark already-uploaded file as permanent):
prepare_changes(changeset, fn cs ->
  :ok = EmAttachments.Upload.mark_permanent(cs.repo, new_file.id)
  if prev_file, do: uploader.delete(prev_file)
  cs  # file struct is already the final stored file, no change needed
end)
```

- If `mark_permanent` fails (e.g. row not found), add an error to the changeset and let the transaction roll back
- If the outer Ecto transaction rolls back after `mark_permanent` succeeds, that's fine — the sweeper will eventually finalize the permanent row anyway
- Deletion of previous file stays in `prepare_changes` (unchanged)
- `reprocess: true` option stays but needs to re-insert a pending row for the new asset IDs

---

## 5. GenServer Sweeper (`EmAttachments.Sweeper`)

```elixir
defmodule EmAttachments.Sweeper do
  use GenServer

  def start_link(opts \\ [])

  # On each tick:
  # 1. Cleanup expired pending assets
  # 2. Finalize confirmed permanent assets
end
```

### Tick logic

**Step 1 — Cleanup expired pending:**

```
query: status = "pending" AND expires_at < now()
for each row:
  file = uploader_mod.deserialize(row.serialized)
  uploader_mod.delete(file)   # calls plugin.destroy/2 + backend.delete/2
  # if backend returns :not_found → log warning, continue (item 7)
  delete row from table
```

**Step 2 — Finalize permanent assets:**

```
query: status = "permanent"
for each row:
  file = uploader_mod.deserialize(row.serialized)
  backend_mod.finalize(file.id, finalize_opts)   # new backend callback
  uploader_mod.after_confirm(file)               # calls plugin.after_confirm/2 for each plugin
  delete row from table
```

### Supervision

- Add `EmAttachments.Sweeper` to a supervisor that users add to their supervision tree
- Or: document starting it in `application.ex` with `{EmAttachments.Sweeper, repo: MyApp.Repo}`
- Make it optional — if no `:repo` configured, Sweeper does not start and logs a warning

---

## 6. Plugin Callback Changes

### Changed: `upload/3`

The storage context tuple is simplified — no phase atom, just the backend module and opts.

```elixir
# Old signature (two phases, atom indicated which):
@callback upload(source, {:cache | :store, backend_mod, backend_opts}, ctx) :: ...

# New signature (single phase, no atom needed):
@callback upload(source, {backend_mod, backend_opts}, ctx) :: ...
```

All existing plugin `upload/3` implementations that matched on `:cache` vs `:store` need updating. The derivatives plugin is the main affected one (see section 9).

### New optional: `after_confirm/2`

```elixir
@callback after_confirm(
  file :: struct(),
  ctx :: %{
    plugin_key:  atom(),
    plugin_opts: keyword(),
    backend:     {module(), keyword()}
  }
) :: :ok | {:error, term()}
```

- Called by the Sweeper when processing a permanent row
- Useful for plugins that manage their own derived assets (e.g. derivatives plugin changing ACL on variant files)
- Default: `{:ok}` / not required

### Callback summary

| Callback          | Change                                                             |
| ----------------- | ------------------------------------------------------------------ |
| `cast/2`          | Unchanged                                                          |
| `init/2`          | Unchanged                                                          |
| `upload/3`        | Storage context is always `{:store, ...}` — remove `:cache` branch |
| `validate/3`      | Unchanged                                                          |
| `destroy/2`       | Unchanged — must handle `:not_found` gracefully                    |
| `url/3`           | Unchanged                                                          |
| `after_confirm/2` | **NEW** — optional, called by Sweeper post-confirmation            |

---

## 7. Backend Callback Changes

### New optional: `finalize/2`

```elixir
@callback finalize(id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
```

- Called by the Sweeper when processing a permanent row
- `opts` comes from `Config.finalize_opts()` (new config key)
- Default implementation: `:ok` (do nothing)
- **S3 use case:** change ACL from `:private` to `"public-read"` via PUT Object ACL
- **Local use case:** likely no-op
- If it returns `{:error, :not_found}`, the Sweeper should log a warning and still delete the row

### Updated: `delete/2`

- Must handle the case where the asset no longer exists in the backend (deleted externally)
- Should return `:ok` (not `{:error, :not_found}`) when the file is already gone — or at minimum the Sweeper must handle `:not_found` as a successful deletion

### Callback summary

| Callback           | Change                                                           |
| ------------------ | ---------------------------------------------------------------- |
| `put/3`            | Unchanged                                                        |
| `get/2`            | Unchanged                                                        |
| `delete/2`         | Must gracefully handle already-deleted assets                    |
| `url/2`            | Unchanged                                                        |
| `presign_upload/2` | Unchanged                                                        |
| `finalize/2`       | **NEW** — optional post-confirmation action (e.g. change S3 ACL) |

---

## 8. Config Changes

### Old config:

```elixir
config :em_attachments, :config,
  store: {S3, bucket: "my-bucket", acl: :private},
  cache: [prefix: "tmp/"],    # REMOVED
  secret_key: "my-secret"
```

### New config:

```elixir
config :em_attachments, :config,
  repo:             MyApp.Repo,               # NEW: required for upload tracking table
  store:            {S3, bucket: "my-bucket"},# Unchanged (still called :store for now)
  expiry:           :timer.hours(24),         # NEW: how long a :pending asset lives (default: 24h)
  finalize_opts:    [acl: "public-read"],     # NEW: opts forwarded to backend.finalize/2
  sweeper_interval: :timer.minutes(30),       # NEW: sweeper tick rate (default: 30m)
  secret_key:       "my-secret"              # Unchanged
```

### `Config` module additions / removals:

| Function                    | Change                                         |
| --------------------------- | ---------------------------------------------- |
| `Config.store/1`            | Unchanged                                      |
| `Config.cache/1`            | **REMOVED**                                    |
| `Config.repo!/0`            | **NEW** — raises if `:repo` not configured     |
| `Config.expiry/0`           | **NEW** — returns `:expiry` in ms, default 24h |
| `Config.finalize_opts/0`    | **NEW** — returns keyword list, default `[]`   |
| `Config.sweeper_interval/0` | **NEW** — returns ms, default 30m              |

### Consider: per-uploader expiry override

```elixir
defmodule MyApp.AvatarUploader do
  use EmAttachments.Uploader,
    expiry: :timer.hours(1)   # override global expiry just for this uploader
end
```

This gets merged into `call_opts` and checked before `Config.expiry/0`.

---

## 9. Derivatives Plugin Updates (`plugins/derivatives.ex`)

Current `upload/3` has two branches: `:cache` phase (generate + upload variants) and `:store` phase (copy variants from cache to store).

With single-phase uploads:

- Remove the `:store` branch / `copy_variants_to_store/4` logic entirely
- `upload/3` (`:store` context) — generate variants and upload directly to store backend
- `after_confirm/2` — **NEW**: if S3 backend and `finalize_opts` includes an ACL change, call PUT Object ACL on each variant ID
- `destroy/2` — Unchanged, still deletes all variant IDs from the backend

This removes `copy_variants_to_store/4` and the `BackendFile` wrapping for cache-variant-to-store copying, simplifying the plugin significantly.

---

## 10. Not-Found Handling (item 7)

Ensure assets manually deleted outside the app don't cause the Sweeper to pile up retries:

- After each failed `backend.delete/2` with `:not_found`, still delete the DB row
- After each failed `backend.finalize/2` with `:not_found`, log a warning and delete the DB row
- **Do not retry** — if the file is gone, the row is stale; remove it
- Consider adding a `max_attempts` column to the table if you want bounded retries before giving up

---

## 11. Fix Tests

- Remove tests for cache backend configuration and two-phase upload flow
- Remove tests for `promote/2`
- Add tests for:
  - DB row insertion in `pipeline.ex` after `backend.put`
  - `mark_permanent` called inside `prepare_changes`
  - Sweeper cleanup of expired `:pending` rows (file deleted + row removed)
  - Sweeper finalization of `:permanent` rows (`backend.finalize/2` called + row removed)
  - `:not_found` from `backend.delete/2` treated as success (row still deleted)
  - `plugin.after_confirm/2` called during sweeper finalization
  - `backend.finalize/2` called with correct `finalize_opts` from config
- Update integration tests to use single-backend config (no `:cache` key)
