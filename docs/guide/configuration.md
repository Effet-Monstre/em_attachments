# Configuration

## Global Config

Add to `config/config.exs`:

```elixir
config :em_attachments,
  secret_key: "long-random-secret",   # required — used to sign file IDs
  config: [
    store: {EmAttachments.Backends.S3, bucket: "my-bucket", acl: :public_read}
  ]
```

For local development use `EmAttachments.Backends.Local`:

```elixir
config :em_attachments,
  secret_key: "dev-secret",
  config: [
    store: {EmAttachments.Backends.Local, fs_path: "/var/app/store", render_path: "/files/store"}
  ]
```

### `secret_key`

Required. Used to HMAC-sign file IDs to prevent enumeration. Generate one with:

```bash
mix phx.gen.secret
```

Or any 64-character random string.

### `repo`

Optional. The `Ecto.Repo` module used to track pending uploads. Required for Ecto integration.

```elixir
config :em_attachments, :config,
  repo: MyApp.Repo
```

When set, each upload inserts a `pending` row into `em_attachments_uploads` immediately after the file is written to the backend. `cast_attachments/3` calls `mark_permanent` inside the Ecto transaction to confirm the upload atomically.

### `expiry`

How long (in milliseconds) a pending upload row survives before the Sweeper deletes it. Defaults to `86_400_000` (24 hours).

```elixir
config :em_attachments, :config,
  expiry: :timer.hours(48)
```

### `sweeper_interval`

How often (in milliseconds) the `EmAttachments.Sweeper` GenServer polls for expired pending uploads. Defaults to `1_800_000` (30 minutes).

```elixir
config :em_attachments, :config,
  sweeper_interval: :timer.minutes(10)
```

### `finalize_opts`

Options passed to `backend.finalize/2` when the Sweeper confirms permanent uploads. Useful for backends that need post-confirmation steps (e.g. updating an S3 object's ACL).

```elixir
config :em_attachments, :config,
  finalize_opts: [acl: :public_read]
```

### Env-var expansion

Env-var expansion is supported anywhere in config values:

```elixir
store: {EmAttachments.Backends.S3,
  bucket: {:env, "S3_BUCKET"},
  access_key_id: {:env, "AWS_ACCESS_KEY_ID"},
  secret_access_key: {:env, "AWS_SECRET_ACCESS_KEY", "fallback"}}
```

The third element of the tuple is an optional fallback used when the variable is unset.

---

## Ecto tracking table

Run the provided mix task to generate the migration:

```bash
mix em_attachments.gen.migration
mix ecto.migrate
```

The `em_attachments_uploads` table stores one row per pending upload. Rows transition from `pending` to `permanent` inside your Ecto transaction via `mark_permanent`, then the Sweeper finalizes and removes them in the background.

---

## Sweeper

Add `EmAttachments.Sweeper` to your supervision tree:

```elixir
children = [
  MyApp.Repo,
  EmAttachments.Sweeper,
  MyAppWeb.Endpoint
]
```

The Sweeper is a no-op (`:ignore`) when no `repo` is configured.

---

## Local Backend

```elixir
{EmAttachments.Backends.Local,
  fs_path: "/var/uploads",      # directory where files are written
  render_path: "/uploads"}      # URL prefix returned by url/2
```

| Option | Required | Description |
|---|---|---|
| `fs_path` | yes | Filesystem directory for file writes |
| `render_path` | yes | URL prefix returned by `url/2` |

---

## S3 Backend

```elixir
{EmAttachments.Backends.S3,
  bucket: "my-bucket",
  prefix: "uploads",            # key prefix, default "uploads"
  region: "us-east-1",         # default: AWS_REGION env var or "us-east-1"
  access_key_id: "...",        # default: AWS_ACCESS_KEY_ID env var
  secret_access_key: "...",    # default: AWS_SECRET_ACCESS_KEY env var
  acl: :public_read,           # :private (default) | :public_read | :authenticated_read
  url_expires_in: 3600}        # presigned URL TTL in seconds
```

| Option | Default | Description |
|---|---|---|
| `bucket` | — | S3 bucket name (required) |
| `prefix` | `"uploads"` | Key prefix for all uploaded files |
| `region` | `AWS_REGION` env / `"us-east-1"` | AWS region |
| `access_key_id` | `AWS_ACCESS_KEY_ID` env | AWS access key |
| `secret_access_key` | `AWS_SECRET_ACCESS_KEY` env | AWS secret key |
| `acl` | `:private` | Canned ACL: `:private`, `:public_read`, `:authenticated_read` |
| `url_expires_in` | `3600` | Presigned URL TTL in seconds |

No ExAws dependency — uses AWS Signature v4 directly via `req`.

### Presigned uploads

For direct browser-to-S3 uploads, generate presigned POST credentials:

```elixir
{:ok, %{url: url, fields: fields}} = AvatarUploader.presign_upload()
# Render url + fields as a multipart form; the browser uploads directly to S3.
# After upload, call AvatarUploader.upload/1 with the returned object key.
```

---

## Custom Backend

Implement `EmAttachments.Backend`:

```elixir
defmodule MyApp.GCSBackend do
  @behaviour EmAttachments.Backend

  def put(id, source, opts), do: ...
  def get(id, opts), do: ...
  def delete(id, opts), do: ...
  def url(id, opts), do: ...
  def presign_upload(id, opts), do: ...

  # Optional: called by the Sweeper after confirming a permanent upload
  def finalize(id, opts), do: ...
end
```
