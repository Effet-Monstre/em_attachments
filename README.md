# EmAttachments

File attachment library for Elixir, inspired by [Shrine](https://shrinerb.com) for Rails.

Upload files to cache on receive, promote them to permanent storage on save, run plugins
(MIME detection, dimension validation, derivative generation) at each phase, and store the
result as a structured metadata map in your database.

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

### Upload → promote lifecycle

```elixir
# 1. Upload a file (writes to cache, runs all plugins + validations)
{:ok, cached_file} = AvatarUploader.upload(plug_upload_or_temp_file)

# cached_file.storage  => :cache
# cached_file.metadata => %{size: 42000, filename: "photo.jpg",
#                           plugins: %{mime: %{type: "image/jpeg", extension: "jpg"},
#                                      dimensions: %{width: 800, height: 600}}}

# 2. Promote to permanent storage (copies to store, runs store-phase plugins, deletes cache copy)
{:ok, stored_file} = AvatarUploader.promote(cached_file)

# stored_file.storage => :store

# 3. Get the URL
url = AvatarUploader.url(stored_file)

# 4. Delete (removes file + all derivatives from store)
AvatarUploader.delete(stored_file)
```

## Ecto integration

When `ecto` is available, each uploader is also an `Ecto.Type` and can be used as a field type directly.

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
| `%Plug.Upload{}` | Upload to cache; promote to store inside Ecto transaction |
| `nil` or `""` | Delete existing file inside transaction; set field to `nil` |
| Signed JSON string (from prior serialize call) | Re-submit cached file; promote on save |
| Bare file ID string matching current field | No-op |
| Key absent from params | No-op (unless `promote: true` / `reprocess: true`) |

### Deferred promotion

Keep the file in `:cache` state and promote later (e.g. from a background job):

```elixir
# On form submit — saves as :cache
cast_attachments(changeset, [:avatar], promote: false)

# In a background job — promotes the cached file to :store
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

When promoting from a cache bucket to the same S3 bucket, the backend performs a server-side
`CopyObject` so the file is never downloaded locally.

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
# Generic handler — same derivatives for both phases; cached copies are promoted to
# store automatically (no re-generation):
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)
  {:ok, resized} = Image.thumbnail(path, 80)
  {:ok, small_bin} = Image.write_to_buffer(resized, ".png")
  %{small: small_bin}
end

# Phase-specific handlers — different derivatives per phase:
def handle(:derivatives, %{file: file, store: :cache}) do
  path = EmAttachments.SourceFile.local_path!(file)
  %{thumb: make_thumb(path)}
end

def handle(:derivatives, %{file: file, store: :store}) do
  path = EmAttachments.SourceFile.local_path!(file)
  %{thumb: make_thumb(path), large: make_large(path)}
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
  use EmAttachments.Plugin, depends_on: [mime: EmAttachments.Plugins.Mime]

  # init/5 runs in the cache phase only; result available in deps[plugin_key]
  # before upload/6 is called:
  @impl true
  def init(source, _key, _uploader, _deps, _opts) do
    path = EmAttachments.SourceFile.local_path!(source)
    {:ok, content} = File.read(path)
    {:ok, %{sha256: Base.encode16(:crypto.hash(:sha256, content))}}
  end

  # upload/6 runs in both phases; deps[plugin_key] contains the init result:
  @impl true
  def upload(_source, key, _uploader, deps, _opts, {:store, _mod, _opts}) do
    {:ok, %{stored_hash: deps[key][:sha256]}}
  end

  def upload(_, _, _, _, _, _), do: :skip
end
```

Plugin callbacks (all optional):

| Callback | When called |
|---|---|
| `init/5` | Cache phase only (skipped if result already seeded from cache phase) |
| `upload/6` | Both phases; receives init result in `deps[plugin_key]` |
| `validate/4` | After upload, when uploader declares `validates plugin_key: opts` |
| `destroy/4` | When parent file is deleted |
| `url/5` | When resolving a URL; return `{:ok, url}` to short-circuit |

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

Override the store or cache backend for a single call:

```elixir
# Use a different uploader-level backend just for this upload:
use EmAttachments.Uploader, store: {MyBackend, bucket: "special-bucket"}

# Or pass plugin-level runtime opts:
AvatarUploader.upload(file, dimensions: [adapter: MyApp.FastAdapter])
```

## Serialization

Cache files are HMAC-signed to prevent enumeration and tampering:

```elixir
json = AvatarUploader.serialize(cached_file)
# => signed JSON string safe to embed in an HTML form

{:ok, file} = AvatarUploader.deserialize(json)
# => verifies signature, returns the file struct
```

Store files serialize without a signature (the ID is already in the database).
