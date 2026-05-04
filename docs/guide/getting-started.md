# Getting Started

## Installation

Add `em_attachments` to your `mix.exs` dependencies:

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

Then run:

```bash
mix deps.get
```

## Defining an Uploader

An uploader is a plain module. `use EmAttachments.Uploader` injects the upload pipeline, plugin declarations, and validation DSL.

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

## Upload Lifecycle

Every file is uploaded directly to the store backend. When used with Ecto, the upload is registered as pending and confirmed atomically inside the database transaction.

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

| Step | What happens |
|---|---|
| `upload/1` | Writes to store backend, runs all plugins, returns a file with metadata |
| `url/1` | Returns the public URL from the storage backend |
| `delete/1` | Removes the file and all its derivatives |

## Ecto Integration

When `ecto` is available, each uploader is also an `Ecto.Type` and can be used as a field type directly.

### 1. Generate the tracking migration

```bash
mix em_attachments.gen.migration
mix ecto.migrate
```

This creates the `em_attachments_uploads` table used to track pending uploads and confirm them atomically with your Ecto transactions.

### 2. Configure repo and Sweeper

```elixir
# config/config.exs
config :em_attachments, :config,
  repo: MyApp.Repo

# application.ex
children = [
  MyApp.Repo,
  EmAttachments.Sweeper,
  ...
]
```

The Sweeper is a GenServer that periodically cleans up expired pending uploads and finalizes confirmed ones (e.g. updating S3 ACLs).

### 3. Define your schema

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
| `{:url, url}` | Download from `url`, then upload and mark permanent |
| `{:binary, data}` | Treat raw bytes as an in-memory file and run the upload pipeline |
| `{:binary, data, filename}` | Same as above with a given filename |
| `nil` or `""` | Delete existing file inside transaction; set field to `nil` |
| Signed JSON string | Re-submit a pending file; mark permanent on save |
| Key absent from params | No-op |
