defmodule EmAttachments.Test.BasicUploader do
  use EmAttachments.Uploader

  plugin mime: EmAttachments.Plugins.Mime

  validates mime: [type: ~w(image/png image/jpeg), extension: ~w(png jpg jpeg)]
end

defmodule EmAttachments.Test.DerivativeUploader do
  use EmAttachments.Uploader

  plugin mime: EmAttachments.Plugins.Mime
  plugin derivatives: EmAttachments.Plugins.Derivatives

  def handle(:derivatives, %{file: file}) do
    content = File.read!(EmAttachments.SourceFile.local_path!(file))
    %{copy: content}
  end
end

defmodule EmAttachments.Test.NoPluginUploader do
  use EmAttachments.Uploader
end

defmodule EmAttachments.Test.CmdStdoutDerivativeUploader do
  use EmAttachments.Uploader

  plugin mime: EmAttachments.Plugins.Mime
  plugin derivatives: EmAttachments.Plugins.Derivatives

  validates mime: [type: ~w(image/png image/jpeg)]

  def handle(:derivatives, _) do
    %{thumb: {:cmd_stdout, "magick", [:input, "-resize", "5x5!", "png:-"]}}
  end
end

# Returns fixed 800×600 for any file — lets dimension validation tests run
# without needing a real image decoder installed.
defmodule EmAttachments.Test.FixedDimensionsAdapter do
  def dimensions(_path), do: {:ok, %{width: 800, height: 600}}
end

# Validates MIME (png/jpeg only) and dimensions (100–1000 on each axis).
# With FixedDimensionsAdapter, valid PNG/JPEG uploads pass; GIFs fail MIME validation.
defmodule EmAttachments.Test.MimeAndDimensionsUploader do
  use EmAttachments.Uploader

  plugin mime: EmAttachments.Plugins.Mime

  plugin dimensions:
           {EmAttachments.Plugins.Dimensions, adapter: EmAttachments.Test.FixedDimensionsAdapter}

  validates mime: [type: ~w(image/png image/jpeg)]
  validates dimensions: [min_width: 100, max_width: 1000, min_height: 100, max_height: 1000]
end

# Same plugins but max 100×100 — FixedDimensionsAdapter's 800×600 will fail.
defmodule EmAttachments.Test.StrictDimensionsUploader do
  use EmAttachments.Uploader

  plugin mime: EmAttachments.Plugins.Mime

  plugin dimensions:
           {EmAttachments.Plugins.Dimensions, adapter: EmAttachments.Test.FixedDimensionsAdapter}

  validates mime: [type: ~w(image/png image/jpeg)]
  validates dimensions: [max_width: 100, max_height: 100]
end

defmodule EmAttachments.Test.InitAndUploadPlugin do
  use EmAttachments.Plugin

  @impl true
  def init(_source, _ctx) do
    {:ok, %{from_init: true}}
  end

  @impl true
  def upload(_source, {storage, _, _}, ctx) do
    from_init = ctx.deps[ctx.plugin_key][:from_init]
    {:ok, %{saw_init: from_init == true, storage: storage, from_init: from_init}}
  end
end

defmodule EmAttachments.Test.InitAndUploadUploader do
  use EmAttachments.Uploader
  plugin probe: EmAttachments.Test.InitAndUploadPlugin
end

if Code.ensure_loaded?(Ecto.Schema) do
  defmodule EmAttachments.Test.DerivativeRecord do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}

    embedded_schema do
      field(:name, :string)
      field(:avatar, EmAttachments.Test.DerivativeUploader)
    end
  end

  defmodule EmAttachments.Test.CmdStdoutRecord do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}

    embedded_schema do
      field(:name, :string)
      field(:avatar, EmAttachments.Test.CmdStdoutDerivativeUploader)
    end
  end

  defmodule EmAttachments.Test.UserRecord do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}

    embedded_schema do
      field(:name, :string)
      field(:avatar, EmAttachments.Test.BasicUploader)
    end
  end

  defmodule EmAttachments.Test.MimeAndDimensionsRecord do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}

    embedded_schema do
      field(:name, :string)
      field(:avatar, EmAttachments.Test.MimeAndDimensionsUploader)
    end
  end

  defmodule EmAttachments.Test.StrictDimensionsRecord do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}

    embedded_schema do
      field(:name, :string)
      field(:avatar, EmAttachments.Test.StrictDimensionsUploader)
    end
  end
end
