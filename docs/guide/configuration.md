# Configuration

## Global Config

Add to `config/config.exs`:

```elixir
config :em_attachments,
  secret_key: "long-random-secret",   # required — used to sign cache file IDs
  config: [
    store: {EmAttachments.Backends.S3, bucket: "my-bucket", acl: :public_read},
    cache: [prefix: "cache"]          # inherits store backend, merges opts on top
  ]
```

For local development use `EmAttachments.Backends.Local`:

```elixir
config :em_attachments,
  secret_key: "dev-secret",
  config: [
    store: {EmAttachments.Backends.Local, fs_path: "/var/app/store", render_path: "/files/store"},
    cache: {EmAttachments.Backends.Local, fs_path: "/var/app/cache", render_path: "/files/cache"}
  ]
```

### `secret_key`

Required. Used to HMAC-sign cache file IDs to prevent enumeration. Generate one with:

```bash
mix phx.gen.secret
```

Or any 64-character random string.

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
| `policy` | — | Set to `:cache` to enable same-bucket cache optimisation |
| `cache_ttl` | `1800` | Seconds before a cache-policy file is auto-deleted |

No ExAws dependency — uses AWS Signature v4 directly via `req`.

See the [S3 guide](./s3) for credentials setup, ACL options, presigned uploads, the cache policy, and bulk operations.

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
end
```
