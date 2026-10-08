# em_attachments

File attachment library for Elixir, inspired by Shrine. Consumed by apps via git ref, not Hex.

## Running tests

```bash
docker compose up -d db   # postgres:17 on host port 5437
mix test
```

Without the database `mix test` still reports success: `test/test_helper.exs` catches the
connection failure, prints a one-line warning, and adds `:db` to the exclude list, silently
skipping ~60 tests. Always start the container before trusting a green run.

Tags: `:db` (needs Postgres), `:external` (hits the network or real S3, always excluded),
`:local_backend` (excluded when `TEST_S3_BUCKET` points the suite at real S3).

## Postgres in practice

`ecto_sql` and `postgrex` are `only: :test` — host apps bring their own adapter. The code
branches on `Ecto.Adapters.Postgres` in three places (the migration's schema and notify
trigger, `Config.schema_name/0`, `Sweeper.maybe_start_notifications/1`) and degrades to a
flat table with pure polling elsewhere, but Postgres is the only adapter exercised.

`pg_notify` does not fire under `Ecto.Adapters.SQL.Sandbox` (notifications are delivered at
COMMIT), so the Sweeper's LISTEN/NOTIFY path cannot be covered by the suite.

## Architecture notes

Each uploader module is simultaneously the struct, the `Ecto.Type`, and the plugin host —
there is no separate asset type. `use EmAttachments.Uploader` injects `defstruct` plus
`cast/1`, `load/1`, `dump/1` via `__before_compile__`.

**An asset's `id` is exactly the basename of its storage key.** The key is always
`<backend prefix>/<id>`, and since v0.3 the id is a UUIDv7 with the detected file extension
appended. Nothing may break that invariant: it is what lets a bucket key be mapped back to
an asset without parsing, which future garbage collection depends on. Objects written
before v0.3 have base64url ids and no extension; they satisfy the same invariant.

MIME type and extension always come from magic bytes, never from a submitted filename.
`EmAttachments.Mime` does the detection; the `Mime` *plugin* only adds validation and a
`metadata.plugins.mime` entry on top of it.

The `uploads` tracking table holds in-flight assets only — rows are deleted once the
Sweeper finalizes them, so it is not an inventory of live objects.

## Toolchain and maintenance

`.tool-versions` pins Erlang/OTP and Elixir and `.nvmrc` pins Node for every place that
builds this repository: GitHub CI reads them, and so does the kranq image (`Kranqfile`).
Change a version there, never in a workflow.

`.github/workflows/maintenance.yml` runs every Monday. It sends the repository to kranq,
which runs the shared `maintenance` task from the infrastructure repository with the extra
rules in `ci/tasks/maintenance.md`, then merges the pull request once GitHub CI is green and
tags the patch release. `ci/tasks/setup.md` is the bring-up it follows. Repository settings:
the `KRANQ_URL`, `KRANQ_SSH_KEY` and `SYNC_TOKEN` secrets, and optionally the
`INFRASTRUCTURE_REF` variable.
