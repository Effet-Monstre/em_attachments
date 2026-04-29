# Derivatives

The `EmAttachments.Plugins.Derivatives` plugin generates derived files — thumbnails, resized images, video stills, text extractions, and any other transformations — alongside the original upload.

## Setup

```elixir
defmodule MyApp.AvatarUploader do
  use EmAttachments.Uploader

  plugin derivatives: EmAttachments.Plugins.Derivatives
end
```

Then implement `handle/2` in your uploader to produce the derivatives:

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)
  # ... generate files ...
  %{thumb: binary_or_path, large: binary_or_path}
end
```

`handle/2` returns a map where each value is either:

- **A binary** — written to a temp file automatically
- **A path string** — used as-is (you manage the file)
- **A `{:cmd, …}` tuple** — executed by the plugin (see [Cmd tuples](#cmd-tuples-no-library-needed))
- **A nested map** — creates a nested derivative tree

The plugin uploads all derivatives in parallel and stores their backend IDs under `file.metadata.plugins.derivatives.variants`.

---

## Generic handler (same derivatives for cache and store)

When `handle/2` matches only `%{file: file}` (no `:store` key), the plugin treats cache and store identically. On promotion it **copies** the cached derivatives to the store backend — no re-generation. This is the most common pattern:

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)
  {:ok, image} = Image.open(path)

  {:ok, thumb_bin} = image |> Image.thumbnail!(80) |> Image.write_to_buffer(".webp")
  {:ok, medium_bin} = image |> Image.thumbnail!(400) |> Image.write_to_buffer(".webp")

  %{thumb: thumb_bin, medium: medium_bin}
end
```

On S3 this copy is a server-side `CopyObject` — the file is never downloaded to your server.

---

## Phase-specific handlers

Match on the `:store` key to run different logic during cache vs. store:

```elixir
# Cache phase: cheap low-quality thumb for preview
def handle(:derivatives, %{file: file, store: :cache}) do
  path = EmAttachments.SourceFile.local_path!(file)
  %{thumb: generate_thumb(path, quality: :low)}
end

# Store phase: high-quality thumb + additional sizes
def handle(:derivatives, %{file: file, store: :store}) do
  path = EmAttachments.SourceFile.local_path!(file)
  %{
    thumb:   generate_thumb(path, quality: :high),
    medium:  generate_medium(path),
    original: path          # path string — no copy needed
  }
end
```

During promotion the plugin calls the `:store` clause first. If that returns `:skip`, it falls back to the generic clause (without a `:store` key).

---

## Cmd tuples — no library needed

Return `{:cmd, executable, args}` tuples to invoke CLI tools directly without an Elixir wrapper library. The plugin substitutes `:input` and `:output` with the actual file paths and uploads the output:

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)

  # ImageMagick: resize to 200px wide, output as JPEG
  %{
    thumb: {:cmd, "convert", [:input, "-resize", "200x", :output], ext: ".jpg"}
  }
end
```

For tools that write to **stdout** instead of a file, use `{:cmd_stdout, …}`:

```elixir
def handle(:derivatives, _) do
  %{
    # pdftotext: extract plain text
    text: {:cmd_stdout, "pdftotext", [:input, "-"]},

    # ImageMagick: resize and stream as PNG
    thumb: {:cmd_stdout, "magick", [:input, "-resize", "200x", "png:-"]},

    # ffmpeg: first video frame as JPEG via the pipe protocol
    still: {:cmd_stdout, "ffmpeg", ["-i", :input, "-frames:v", "1", "-f", "image2", "pipe:1"]}
  }
end
```

The captured output is held in memory as a `MemoryFile`. No temporary output file is written to disk before the derivative is stored on the backend.

### Choosing between `:cmd` and `:cmd_stdout`

| | `:cmd` | `:cmd_stdout` |
|---|---|---|
| Output location | Temp file on disk | In-memory `MemoryFile` |
| Tool requirement | Accepts an output path | Writes to stdout |
| Format inference | From `:output` file extension | Must be explicit in the args |
| `:ext` option | Required for most tools | Not applicable |
| Example tools | ffmpeg (to file), Mogrify | pdftotext, `magick png:-` |

### No-temp-file pipeline with binary input

When the source is binary data — an API payload, a buffer from another operation — supply it as `{:binary, data}` or `{:binary, data, filename}`:

```elixir
result = MyUploader.upload({:binary, png_bytes, "photo.png"})
```

Combined with `:cmd_stdout`, this keeps the entire flow — input to derivative to backend — free of user-visible temp files:

1. `{:binary, data}` creates a `MemoryFile` (data held in memory only).
2. When `:cmd_stdout` runs, the `MemoryFile` is written to a managed temp path just long enough for `:input` substitution.
3. The command's stdout is captured into a new `MemoryFile`.
4. That `MemoryFile` is passed directly to `backend.put` — no second disk write.

```elixir
def handle(:derivatives, _) do
  %{thumb: {:cmd_stdout, "magick", [:input, "-resize", "200x", "png:-"]}}
end
```

```elixir
# Somewhere in your application:
png_bytes = fetch_image_from_api()
{:ok, file} = MyUploader.upload({:binary, png_bytes, "photo.png"})
```

With a `{:binary, …}` source and `:cmd_stdout` derivatives, neither the input nor any derivative ever has a user-visible file path.

### Cmd tuple shapes

| Tuple | Description |
|---|---|
| `{:cmd, cmd, args}` | Run `cmd args`, output written to `:output` path |
| `{:cmd, cmd, args, opts}` | Same with options |
| `{:cmd_stdout, cmd, args}` | Run `cmd args`, output captured from stdout |
| `{:cmd_stdout, cmd, args, opts}` | Same with options |

**Substitutions in `args`:**

| Atom | Replaced with |
|---|---|
| `:input` | The source file path |
| `:output` | A managed temp file path (`:cmd` only) |

**Options:**

| Option | Applies to | Description |
|---|---|---|
| `:ext` | `:cmd` | Output file extension including the dot, e.g. `".jpg"`. Required for most `:cmd` uses — tools infer format from the extension. |
| `:filename` | `:cmd_stdout` | Filename stored in the resulting `MemoryFile`. Defaults to `"derivative"`. |

---

## Using `EmAttachments.Cmd` directly

For conditional logic inside `handle/2`, call `EmAttachments.Cmd` directly instead of returning a tuple:

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)

  # Conditional: only generate a video still if the file is a video
  thumb =
    if video?(path) do
      {:ok, tf} = EmAttachments.Cmd.run("ffmpeg",
        ["-i", :input, "-frames:v", "1", "-q:v", "2", :output],
        path,
        ext: ".jpg")
      tf  # TempFile.t() — accepted directly
    else
      :skip
    end

  if thumb == :skip, do: :skip, else: %{thumb: thumb}
end
```

`EmAttachments.Cmd.run/4` returns `{:ok, TempFile.t()}` on success. Pass the `TempFile` directly as a map value — the plugin handles cleanup.

`EmAttachments.Cmd.run_stdout/4` returns `{:ok, MemoryFile.t()}` and captures stdout. Use it when you need conditional logic around a stdout-producing command:

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)

  case EmAttachments.Cmd.run_stdout("pdftotext", [:input, "-"], path) do
    {:ok, mf}  -> %{text: mf}   # MemoryFile — accepted directly
    {:error, _} -> :skip        # no text derivative if extraction fails
  end
end
```

### Error returns

| Return | Meaning |
|---|---|
| `{:error, :command_not_found}` | Executable not on PATH |
| `{:error, :non_zero_exit}` | Command exited with non-zero code |
| `{:error, :no_output}` | Command exited 0 but wrote nothing to the output path (`:cmd` only) |

---

## Using Vix (libvips)

[Vix](https://hex.pm/packages/vix) provides Elixir bindings to libvips. It is the recommended image processing library for em_attachments — it is fast and memory-efficient.

Add to `mix.exs`:

```elixir
{:vix, "~> 0.35"}
```

### Thumbnailing

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)
  {:ok, image} = Vix.Vips.Operation.thumbnail(path, 300)
  {:ok, bin} = Vix.Vips.Image.write_to_buffer(image, ".webp[Q=80]")
  %{thumb: bin}
end
```

### Multiple sizes

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)

  sizes = [small: 100, medium: 400, large: 1200]

  Map.new(sizes, fn {name, width} ->
    {:ok, image} = Vix.Vips.Operation.thumbnail(path, width)
    {:ok, bin}   = Vix.Vips.Image.write_to_buffer(image, ".webp[Q=85]")
    {name, bin}
  end)
end
```

### Format conversion

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)
  {:ok, image} = Vix.Vips.Image.new_from_file(path)
  {:ok, avif}  = Vix.Vips.Image.write_to_buffer(image, ".avif[Q=60]")
  %{avif: avif}
end
```

### Using Vix for Dimensions

`EmAttachments.ImageAdapters.Vix` reads dimensions via libvips and is automatically available when `vix` is in your deps:

```elixir
plugin dimensions: {EmAttachments.Plugins.Dimensions, adapter: EmAttachments.ImageAdapters.Vix}
```

---

## Using Mogrify (ImageMagick)

[Mogrify](https://hex.pm/packages/mogrify) is an Elixir wrapper around the ImageMagick CLI. Requires ImageMagick on the host.

Add to `mix.exs`:

```elixir
{:mogrify, "~> 0.9"}
```

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)

  thumb_path = Path.join(System.tmp_dir!(), "thumb_#{:rand.uniform(999_999)}.jpg")

  Mogrify.open(path)
  |> Mogrify.resize_to_limit("200x200")
  |> Mogrify.save(path: thumb_path)

  %{thumb: thumb_path}  # path string — plugin uses it as-is
end
```

### Using Mogrify for Dimensions

```elixir
plugin dimensions: {EmAttachments.Plugins.Dimensions, adapter: EmAttachments.ImageAdapters.Mogrify}
```

---

## Nested derivatives

Values in the returned map can themselves be maps, creating a nested structure:

```elixir
def handle(:derivatives, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)
  %{
    thumb: %{
      webp: generate_thumb_webp(path),
      jpg:  generate_thumb_jpg(path)
    },
    original: path
  }
end
```

Access nested derivatives via `url/2`:

```elixir
AvatarUploader.url(file, derivatives: [:thumb, :webp])
AvatarUploader.url(file, derivatives: [:thumb, :jpg])
```

---

## Resolving derivative URLs

Pass a `:derivatives` key to `url/2`:

```elixir
# Top-level derivative
AvatarUploader.url(stored_file, derivatives: :thumb)

# Nested derivative
AvatarUploader.url(stored_file, derivatives: [:thumb, :small])
```

---

## Multiple derivative plugins

Mount the plugin under different keys to produce separate derivative sets:

```elixir
plugin avatars:    EmAttachments.Plugins.Derivatives
plugin thumbnails: EmAttachments.Plugins.Derivatives

def handle(:avatars, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)
  %{square: make_square(path)}
end

def handle(:thumbnails, %{file: file}) do
  path = EmAttachments.SourceFile.local_path!(file)
  %{sm: make_sm(path), lg: make_lg(path)}
end
```

---

## Reprocessing

To re-run all plugins (including derivative generation) on an already-stored file:

```elixir
{:ok, updated_file} = MyApp.AvatarUploader.reprocess(stored_file)
```

This downloads the original from the store, runs the full upload pipeline, promotes the result back, and deletes the original. Useful when you change your `handle/2` logic and need to regenerate existing derivatives.
