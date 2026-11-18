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
  config: [
    store: {EmAttachments.Backends.S3, bucket: "my-bucket", acl: :public_read}
  ]
```

For local development use `EmAttachments.Backends.Local`:

```elixir
config :em_attachments,
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

### Asset IDs and storage keys

`file.id` is a UUIDv7 with the detected file extension appended, and the storage key is
always `<prefix>/<file.id>`:

```
uploads/019bf3c2-7a41-7c9e-b8d2-3f1a2b4c5d6e.jpg
```

The extension and the `Content-Type` sent to the backend both come from the file's magic
bytes, never from the submitted filename. This works whether or not the `Mime` plugin is
declared — the plugin adds validation and exposes the result in `metadata`, but detection
for the key and the content type happens either way. Files whose format is not recognised
get no extension and no content type rather than a guessed one.

Derivatives follow the same scheme and are sniffed individually, so a thumbnail encoded in
a different format than its source declares its own type.

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
| Signed token (`AvatarUploader.sign(file)`, `to_string(file)`, what `EmAttachments.Plug.Upload` answers) | Attach a stored file; claimed on save, once |
| The uploader's struct (server code only: params can't hold one) | Attach a file the application stored itself; claimed on save |
| Bare file ID, or its serialized JSON, matching the current field | No-op |
| Any other unsigned value (a serialized file included) | Error `"is invalid"`: never trusted |
| Key absent from params | No-op (unless `promote: true` / `reprocess: true`) |

A file is **claimed once**: saving a record with its token turns its tracking row from
`pending` to `permanent`. A second record given the same token, or a token whose upload
expired or whose record was deleted, gets `"has already been used or has expired"`. One file,
one record: the library's own cleanup (a replaced or removed file, a deleted record) never
deletes a file another record holds.

A record deleted without a changeset (`Repo.delete(struct)`, `delete_all`) releases its files
with `EmAttachments.Ecto.release(repo, files)`, typically from the schema's delete hook.

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
  url_expires_in: 3600,        # presigned URL TTL in seconds
  content_disposition: :inline} # :inline | :attachment — omitted entirely by default
```

No ExAws dependency — uses AWS Signature v4 directly via `req`.

Objects are written with the `Content-Type` detected from their bytes, so they render in a
browser instead of downloading as `binary/octet-stream`. Setting `content_disposition` adds
a `Content-Disposition` header carrying the original filename.

Objects uploaded before v0.3 have no extension and no content type. Their keys keep working
untouched — `file.id` has always been the key's basename — but their content type is only
corrected if they are re-uploaded or reprocessed.

### Presigned uploads

Direct uploads go through `EmAttachments.Plug.Upload` (below): a slot
(`AvatarUploader.presign/1`), the browser's POST to it, then `AvatarUploader.complete/2`. On
S3 the slot is a presigned POST writing exactly one key, capped by `content-length-range`; on
the Local backend it is the plug's own `/local`. The bucket needs a CORS rule allowing `POST`
from the application's origin.

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

  # Optional: what direct uploads need (`complete/2`): the size, and the first bytes to sniff
  def head(id, opts), do: ...
  def get_range(id, first, last, opts), do: ...

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

## Browser uploads: `EmAttachments.Plug.Upload`

Mount the plug behind your own authentication; it answers a **signed token** that
`cast_attachments/3` accepts (a form's hidden input, a JSON API's param):

```elixir
# router.ex (Phoenix)
forward "/api/uploads", EmAttachments.Plug.Upload,
  uploader: MyApp.AvatarUploader,
  max_size: 10_000_000,                              # bytes, default 100MB
  validates: [mime: [type: ~w(image/png image/jpeg)]] # over the uploader's own
```

In a Phoenix router, `EmAttachments.Router.attachments/2` mounts uploads and the files'
URLs (below) under one path, behind the scope's pipelines:

```elixir
import EmAttachments.Router

scope "/" do
  pipe_through [:api, :authenticated]
  attachments "/api/files", uploader: MyApp.FileUploader, max_size: 10_000_000
end
# POST /api/files (a slot, with its `complete_url`), POST /api/files/local,
# POST /api/files/complete, GET /api/files/:token
```

| Route | Body | Answer |
|---|---|---|
| `POST /` | multipart `file` | the file (through the application) |
| `POST /presign` | `size` (optional, refused early when too large) | `{url, fields, token}`: a slot |
| `POST <url>` | multipart: every `fields` entry, then `file` | S3's answer, or `204` from `/local` |
| `POST /complete` | `token`, `filename` | the file |

The file is `{token, id, filename, size, content_type}` (`200`). Refusals are `422`
`{error, message}` (`too_large`, `not_accepted`, `invalid_token`, `not_found`, `no_file`), a
storage failure `502` (`error: "storage"`, `EmAttachments.Error.message/1`).

`complete` reads the object's size and its first bytes only (ranged reads), validates them,
copies the object to its asset id (server-side on S3) and removes the slot. A slot never
completed is tracked like any pending upload and removed by the Sweeper.

```js
const slot = await post("/api/uploads/presign", { size: file.size })
const form = new FormData()
Object.entries(slot.fields).forEach(([k, v]) => form.append(k, v))
form.append("file", file) // last: S3 ignores what follows it
await fetch(slot.url, { method: "POST", body: form })
const { token } = await post("/api/uploads/complete", { token: slot.token, filename: file.name })
// send `token` with the record
```

## Files' URLs: `EmAttachments.Plug.File`

A private store's files are reached through the application: `MyUploader.url_token(file,
name: "Bail")` names a file (and the name it downloads as) in a signed token, and
`GET <path>/:token` (`EmAttachments.Router.attachments/2`) redirects to the store's
short-lived URL (`?download=1` to download it). The token is the authorization: hand it only
to who may see the record holding the file, in the data you send them. With tracking, it
reaches the file only while a record holds it (a released file is a `404`). It's valid one to
two `:max_age` (7 days by default) and the same for a file, a name and a period, so a page
reloaded gets the same URL and the browser keeps the file.

## Per-call backend overrides

Override the store backend for a single call:

```elixir
# Use a different uploader-level backend just for this upload:
use EmAttachments.Uploader, store: {MyBackend, bucket: "special-bucket"}

# Or pass plugin-level runtime opts:
AvatarUploader.upload(file, dimensions: [adapter: MyApp.FastAdapter])
```

## Serialization

```elixir
json = AvatarUploader.serialize(file)
# => JSON string, ready to embed in an HTML hidden input

{:ok, file} = AvatarUploader.deserialize(json)
# => the file struct
```

The payload is plain JSON, not signed: `cast_attachments/3` refuses it from a client. Hand
a client `AvatarUploader.sign(file)` instead (`to_string(file)` is the same), valid as long as
the pending upload (`expiry`, 24 h by default).

The signing key is `config :em_attachments, :config, secret_key: ...` (32 bytes at least,
`{:env, "VAR"}` accepted). Signing raises without it.
