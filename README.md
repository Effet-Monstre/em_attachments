# EmAttachments

File attachment library for Elixir, inspired by [Shrine](https://shrinerb.com) for Rails.

Upload files directly to permanent storage, run plugins (MIME detection, dimension validation, derivative generation) during the pipeline, and store the result as a structured metadata map in your database.

## Installation

```elixir
def deps do
  [
    {:em_attachments, "~> 0.1"},

    # pick one or more storage backends:
    {:req, "~> 0.5"},          # required for the S3 backend

    # optional integrations:
    {:ecto, "~> 3.11"},        # Ecto.Type + cast_attachments/3
    {:plug, "~> 1.16"},        # Plug.Upload source + upload endpoint
    {:phoenix, "~> 1.8"},      # Phoenix.HTML.Safe

    # optional image adapters (for the Dimensions plugin):
    {:vix, "~> 0.35"},         # libvips
    {:mogrify, "~> 0.9"},      # ImageMagick
  ]
end
```

## Configuration

```elixir
# config/config.exs
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

Env-var expansion is supported anywhere in config values:

```elixir
store: {EmAttachments.Backends.S3,
  bucket: {:env, "S3_BUCKET"},
  access_key_id: {:env, "AWS_ACCESS_KEY_ID"},
  secret_access_key: {:env, "AWS_SECRET_ACCESS_KEY", "fallback"}}
```

## Defining an uploader

```elixir
defmodule MyApp.AvatarUploader do
  use EmAttachments.Uploader

  plugin mime: EmAttachments.Plugins.Mime
  plugin dimensions: {EmAttachments.Plugins.Dimensions, adapter: MyApp.ImageAdapter}
  plugin derivatives: EmAttachments.Plugins.Derivatives

  validates mime: [type: ~w(image/png image/jpeg), extension: ~w(png jpg jpeg)]
  validates dimensions: [min_width: 100, max_width: 4000, min_height: 100, max_height: 4000]

  # Optional: custom cross-plugin validation
  def validate(_source, plugin_results) do
    case plugin_results[:dimensions] do
      %{width: w, height: h} when w != h -> {:error, "avatar must be square"}
      _ -> :ok
    end
  end

  # Generate derivative files (called by the Derivatives plugin)
  def handle(:derivatives, %{file: file}) do
    path = EmAttachments.SourceFile.local_path!(file)
    {:ok, resized} = Image.thumbnail(path, 80)
    {:ok, thumb_bin} = Image.write_to_buffer(resized, ".png")
    %{thumb: thumb_bin}
  end
end
```

### Upload lifecycle

```elixir
# 1. Upload a file (writes to store, runs all plugins + validations)
{:ok, file} = AvatarUploader.upload(plug_upload_or_temp_file)

# file.storage  => :store
# file.metadata => %{size: 42000, filename: "photo.jpg",
#                    plugins: %{mime: %{type: "image/jpeg", extension: "jpg"},
#                               dimensions: %{width: 800, height: 600}}}

# 2. Get the URL
url = AvatarUploader.url(file)

# 3. Delete (removes file + all derivatives from store)
AvatarUploader.delete(file)
```

## Ecto integration

When `ecto` is available, each uploader is also an `Ecto.Type` and can be used as a field type directly.

### Setup

Generate the tracking migration:

```bash
mix em_attachments.gen.migration
mix ecto.migrate
```

Add the repo and Sweeper to your configuration and supervision tree:

```elixir
# config/config.exs
config :em_attachments, :config,
  repo: MyApp.Repo

# application.ex
children = [MyApp.Repo, EmAttachments.Sweeper, ...]
```

### Schema

```elixir
defmodule MyApp.User do
  use Ecto.Schema
  import EmAttachments.Ecto

  schema "users" do
    field :avatar, MyApp.AvatarUploader
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> cast_attachments([:avatar])
  end
end
```

`cast_attachments/3` accepts:

| Param value | Behaviour |
|---|---|
| `%Plug.Upload{}` | Upload to store; mark permanent inside Ecto transaction |
| `{:url, url}` | Download file from `url` (via `Req`), then upload and mark permanent. Filename is derived from the URL path. |
| `{:binary, data}` | Treat `data` (raw bytes) as an in-memory file and run the upload pipeline. Filename defaults to `"upload"`. |
| `{:binary, data, filename}` | Same as above but uses the given `filename`. |
| `nil` or `""` | Delete existing file inside transaction; set field to `nil` |
| JSON string (from prior serialize call) | Re-submit a pending file; mark permanent on save |
| Bare file ID string matching current field | No-op |
| Key absent from params | No-op (unless `promote: true` / `reprocess: true`) |

### Deferred confirmation

Upload on receive but skip marking permanent until later (e.g. from a background job or a two-step wizard):

```elixir
# On form submit — file is in store but not yet confirmed
cast_attachments(changeset, [:avatar], promote: false)

# Later (separate request or background job) — confirms the file
cast_attachments(changeset, [:avatar], promote: true)
```

### Reprocessing

Re-run the full pipeline on an already-stored file (e.g. after changing derivative settings):

```elixir
# Via Ecto changeset
cast_attachments(changeset, [:avatar], reprocess: true)

# Or directly
{:ok, new_file} = AvatarUploader.reprocess(stored_file)
```

## Storage backends

### Local filesystem

```elixir
{EmAttachments.Backends.Local,
  fs_path: "/var/uploads",      # directory where files are written
  render_path: "/uploads"}      # URL prefix returned by url/2
```

### S3

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

No ExAws dependency — uses AWS Signature v4 directly via `req`.

### Presigned uploads

For direct browser-to-S3 uploads, generate presigned POST credentials:

```elixir
{:ok, %{url: url, fields: fields}} = AvatarUploader.presign_upload()
# Render url + fields as a multipart form; the browser uploads directly to S3.
# After upload, call AvatarUploader.upload/1 with the returned object key.
```

### Custom backend

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

## Plugins

### Mime

Detects the real MIME type from magic bytes (not file extension or browser content-type).

```elixir
plugin mime: EmAttachments.Plugins.Mime

validates mime: [
  type: ~w(image/png image/jpeg image/webp),
  extension: ~w(png jpg jpeg webp)
]
```

Result stored in `file.metadata.plugins.mime`: `%{type: "image/png", extension: "png"}`

Supported types: PNG, JPEG, GIF, WebP, PDF, ZIP, MP3, MP4/MOV, BMP, TIFF.

### Dimensions

Reads image dimensions via an adapter module or anonymous function.

```elixir
plugin dimensions: {EmAttachments.Plugins.Dimensions,
  adapter: EmAttachments.ImageAdapters.Vix}   # or Mogrify, or fn path -> ... end

validates dimensions: [
  min_width: 100, max_width: 4000,
  min_height: 100, max_height: 4000
]
```

Result stored in `file.metadata.plugins.dimensions`: `%{width: 800, height: 600}`

Built-in adapters: `EmAttachments.ImageAdapters.Vix` (requires `vix`) and
`EmAttachments.ImageAdapters.Mogrify` (requires `mogrify`).

### Derivatives

Generates derivative files (thumbnails, variants, transcodes) during upload.

```elixir
plugin derivatives: EmAttachments.Plugins.Derivatives
```

Define `handle/2` in your uploader to produce derivatives:

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)
  {:ok, resized} = Image.thumbnail(path, 80)
  {:ok, small_bin} = Image.write_to_buffer(resized, ".png")
  %{small: small_bin}
end
```

Map values may be binaries (written to a temp file automatically) or path strings.
Derivatives may be nested: `%{thumb: %{small: bin, large: bin}}`.

Derivatives are uploaded in parallel via `Task.async_stream`.

#### Getting derivative URLs

```elixir
# url/2 with a keyword list navigates the derivative tree:
thumb_url = AvatarUploader.url(file, derivatives: [:small])

# Nested derivatives:
small_thumb_url = AvatarUploader.url(file, derivatives: [:thumb, :small])
```

### Custom plugins

```elixir
defmodule MyApp.HashPlugin do
  use EmAttachments.Plugin

  @impl true
  def init(source, _ctx) do
    path = EmAttachments.SourceFile.local_path!(source)
    {:ok, %{sha256: Base.encode16(:crypto.hash(:sha256, File.read!(path)))}}
  end

  @impl true
  def upload(_source, {_backend_mod, _backend_opts}, ctx) do
    {:ok, %{stored_hash: ctx.deps[ctx.plugin_key][:sha256]}}
  end
end
```

Plugin callbacks (all optional):

| Callback | When called |
|---|---|
| `cast/2` | Before upload — convert a raw param value into a `SourceFile` |
| `init/2` | Before `upload/3` — cheap one-time work (hash, type detection) |
| `upload/3` | During upload — receives `{backend_mod, backend_opts}` tuple |
| `validate/3` | After upload — return `:ok` or `{:error, message}` |
| `destroy/2` | When parent file is deleted |
| `url/3` | When resolving a URL — return `{:ok, url}` to short-circuit |
| `after_confirm/2` | Called by Sweeper after a pending upload is confirmed permanent |

## Direct browser uploads (AJAX)

Use `EmAttachments.Plug.Upload` to accept files via AJAX before form submit:

```elixir
# router.ex (Phoenix)
forward "/attachments/avatar", EmAttachments.Plug.Upload,
  uploader: MyApp.AvatarUploader,
  max_size: 10_000_000   # bytes, default 100MB
```

The endpoint returns a signed JSON string on success (HTTP 200) or a JSON error on failure (HTTP 422).
Submit the JSON string as a hidden input value; `cast_attachments/3` will pick it up on form submit.

## Per-call backend overrides

Override the store backend for a single call:

```elixir
# Use a different uploader-level backend just for this upload:
use EmAttachments.Uploader, store: {MyBackend, bucket: "special-bucket"}

# Or pass plugin-level runtime opts:
AvatarUploader.upload(file, dimensions: [adapter: MyApp.FastAdapter])
```

## Serialization

Files are HMAC-signed to prevent enumeration and tampering:

```elixir
json = AvatarUploader.serialize(file)
# => signed JSON string safe to embed in an HTML form

{:ok, file} = AvatarUploader.deserialize(json)
# => verifies signature, returns the file struct
```
