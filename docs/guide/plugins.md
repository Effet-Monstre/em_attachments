# Plugins

Plugins run during the upload pipeline to extract metadata, validate files, generate derivatives, and more. Each uploader declares which plugins it uses and in what order.

## Declaring plugins

```elixir
defmodule MyApp.AvatarUploader do
  use EmAttachments.Uploader

  plugin mime:        EmAttachments.Plugins.Mime
  plugin dimensions:  {EmAttachments.Plugins.Dimensions, adapter: MyApp.Vix}
  plugin derivatives: EmAttachments.Plugins.Derivatives
end
```

The first element of each pair is a **plugin key** — an atom you choose. The same plugin module can be mounted multiple times under different keys:

```elixir
plugin thumb: EmAttachments.Plugins.Derivatives
plugin banner: EmAttachments.Plugins.Derivatives
```

Plugin results are stored under their key inside `file.metadata.plugins`:

```elixir
file.metadata.plugins
# %{
#   mime:        %{type: "image/jpeg", extension: "jpg"},
#   dimensions:  %{width: 800, height: 600},
#   derivatives: %{variants: %{thumb: %{id: "abc123", storage: :store}}}
# }
```

---

## Built-in plugins

### `EmAttachments.Plugins.Mime`

Detects the real MIME type from magic bytes — not from the file extension or browser-provided content-type.

**Result shape**

```elixir
%{type: "image/jpeg", extension: "jpg"}
```

**Supported types:** PNG, JPEG, GIF, WebP, PDF, ZIP, MP3, MP4/MOV, BMP, TIFF.

**Validation options**

```elixir
validates mime: [
  type:      ~w(image/png image/jpeg),
  extension: ~w(png jpg jpeg)
]
```

| Option | Description |
|---|---|
| `:type` | List of allowed MIME type strings |
| `:extension` | List of allowed extensions (without dot) |

**Example**

```elixir
plugin mime: EmAttachments.Plugins.Mime
validates mime: [type: ~w(image/png image/jpeg image/gif image/webp)]
```

---

### `EmAttachments.Plugins.Dimensions`

Reads image dimensions using an `EmAttachments.ImageAdapter` module or an anonymous function.

**Result shape**

```elixir
%{width: 1920, height: 1080}
```

**Plugin options**

| Option | Required | Description |
|---|---|---|
| `:adapter` | yes | A module implementing `EmAttachments.ImageAdapter`, or a `fn path -> {:ok, %{width: w, height: h}} end` |

**Validation options**

```elixir
validates dimensions: [
  min_width:  100,
  max_width:  4000,
  min_height: 100,
  max_height: 4000,
]
```

**Image adapters**

Pick one based on what you have installed:

```elixir
# Using Vix (libvips — recommended, no extra deps beyond the vix hex package)
plugin dimensions: {EmAttachments.Plugins.Dimensions, adapter: EmAttachments.ImageAdapters.Vix}

# Using Mogrify (ImageMagick wrapper)
plugin dimensions: {EmAttachments.Plugins.Dimensions, adapter: EmAttachments.ImageAdapters.Mogrify}

# Inline anonymous function — useful when neither adapter fits
plugin dimensions: {EmAttachments.Plugins.Dimensions,
  adapter: fn path ->
    # call whatever library you have
    {:ok, %{width: 800, height: 600}}
  end}
```

Both `EmAttachments.ImageAdapters.Vix` and `EmAttachments.ImageAdapters.Mogrify` implement the `EmAttachments.ImageAdapter` behaviour. They are only compiled when the corresponding hex package (`vix` or `mogrify`) is available — see [Image Adapters](#image-adapters) below.

---

### `EmAttachments.Plugins.Derivatives`

Generates derivative files (thumbnails, variants, transcodes, etc.) during upload. Covered in detail on the [Derivatives](./derivatives) page.

---

### `EmAttachments.Plugins.Binary`

A **cast** plugin that lets you submit raw binary data as an attachment value in changeset params.

```elixir
plugin binary: EmAttachments.Plugins.Binary
```

Accepted param shapes:

| Value | Behaviour |
|---|---|
| `{:binary, data}` | Wraps `data` in an in-memory file named `"upload"` |
| `{:binary, data, filename}` | Same with a custom filename |

---

## Image adapters

Image adapters implement the `EmAttachments.ImageAdapter` behaviour:

```elixir
@callback dimensions(path :: String.t()) ::
  {:ok, %{width: pos_integer(), height: pos_integer()}} | {:error, term()}
```

### `EmAttachments.ImageAdapters.Vix`

Backed by the [`vix`](https://hex.pm/packages/vix) hex package (libvips bindings). Only compiled when `vix` is in your deps.

```elixir
# mix.exs
{:vix, "~> 0.35"}
```

```elixir
plugin dimensions: {EmAttachments.Plugins.Dimensions, adapter: EmAttachments.ImageAdapters.Vix}
```

libvips is significantly faster than ImageMagick for most read-only operations and is the recommended adapter when you have it available.

### `EmAttachments.ImageAdapters.Mogrify`

Backed by the [`mogrify`](https://hex.pm/packages/mogrify) hex package (ImageMagick wrapper). Only compiled when `mogrify` is in your deps.

```elixir
# mix.exs
{:mogrify, "~> 0.9"}
```

```elixir
plugin dimensions: {EmAttachments.Plugins.Dimensions, adapter: EmAttachments.ImageAdapters.Mogrify}
```

Requires ImageMagick to be installed on the host system.

### Custom adapter

```elixir
defmodule MyApp.ImageAdapter do
  @behaviour EmAttachments.ImageAdapter

  @impl true
  def dimensions(path) do
    # call any library
    {:ok, %{width: 1920, height: 1080}}
  end
end
```

---

## Writing a custom plugin

Plugins implement the `EmAttachments.Plugin` behaviour. All callbacks are optional — implement only what you need.

```elixir
defmodule MyApp.HashPlugin do
  use EmAttachments.Plugin

  @impl true
  def init(source, _ctx) do
    path = EmAttachments.SourceFile.local_path!(source)
    hash = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    {:ok, %{sha256: hash}}
  end
end
```

Mount it in an uploader:

```elixir
plugin hash: MyApp.HashPlugin
```

The result (`%{sha256: "..."}`) is available at `file.metadata.plugins.hash`.

### Plugin callbacks

| Callback | Phase | Purpose |
|---|---|---|
| `cast/2` | before upload | Convert a raw changeset value into a `SourceFile` |
| `init/2` | cache only | Cheap one-time init (e.g. hash, detect type). Runs before `upload/3`. |
| `upload/3` | cache + store | Upload-time work; receives `{:cache, …}` or `{:store, …}` storage tuple |
| `validate/3` | cache | Validate after cache upload; return `:ok` or `{:error, message}` |
| `destroy/2` | on delete | Clean up derived assets when the parent file is deleted |
| `url/3` | on URL resolution | Return a custom URL for this plugin's data, or `:skip` to pass |

### Declaring plugin dependencies

If your plugin needs results from another plugin, declare the dependency so the pipeline runs them in the right order:

```elixir
defmodule MyApp.ConditionalPlugin do
  use EmAttachments.Plugin, depends_on: [mime: EmAttachments.Plugins.Mime]

  @impl true
  def upload(_source, {:cache, _mod, _opts}, ctx) do
    case ctx.deps[:mime] do
      %{type: "image/" <> _} -> {:ok, %{is_image: true}}
      _ -> {:ok, %{is_image: false}}
    end
  end
end
```

`ctx.deps` is populated with the results of all declared dependencies before your plugin runs.

### Return values

| Return | Meaning |
|---|---|
| `{:ok, map}` | Store this map as the plugin's metadata under its key |
| `:skip` | Leave existing metadata unchanged |
| `{:error, term}` | Fail the upload with this error |
