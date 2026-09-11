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
