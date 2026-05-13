defmodule EmAttachments.Uploader do
  @moduledoc """
  Macro for defining uploaders.

  ## Basic usage

      defmodule MyApp.AvatarUploader do
        use EmAttachments.Uploader

        plugin mime: EmAttachments.Plugins.Mime
        plugin dimensions: EmAttachments.Plugins.Dimensions
        plugin derivatives: EmAttachments.Plugins.Derivatives

        validates mime: [type: ~w(image/png image/jpeg), extension: ~w(png jpg jpeg)]
        validates dimensions: [max_width: 4000, max_height: 4000]

        # Override store backend for this uploader only:
        # use EmAttachments.Uploader, store: {Backends.S3, acl: :public_read}

        # Custom validation (receives the source file and all plugin results):
        def validate(source, plugin_results) do
          case plugin_results[:dimensions] do
            %{width: w, height: h} when w != h -> {:error, "must be square"}
            _ -> :ok
          end
        end

        # Generate derivatives (called by EmAttachments.Plugins.Derivatives):
        def handle(:derivatives, %{file: file}) do
          path = EmAttachments.SourceFile.local_path!(file)
          {:ok, resized} = Operation.thumbnail(path, 80)
          {:ok, small} = Image.write_to_buffer(resized, ".png")
          %{small: small}
        end
      end

  ## Deferred promotion

  To skip marking a file permanent during Ecto save and do it later (e.g. in a background job):

      # In your changeset — file is uploaded to store but stays pending
      cast_attachments(changeset, [:avatar], promote: false)

      # Later, in a background job — marks the pending file as permanent
      cast_attachments(changeset, [:avatar], promote: true)

  ## Reprocessing

  To re-run all plugins (including derivative generation) on an already-stored file:

      {:ok, new_file} = MyUploader.reprocess(stored_file)

  This downloads the original from the store, runs the full upload pipeline, uploads the
  result back to store, and deletes the original.

  ## Ecto integration

  When `ecto` is a dependency, the uploader module is also an `Ecto.Type` and
  can be used directly as a field type. Use `cast_attachments/2` from
  `EmAttachments.Ecto` in your changeset.
  """

  alias EmAttachments.Uploader.Topo

  defmacro __using__(opts) do
    quote do
      import EmAttachments.Uploader, only: [validates: 1, plugin: 1]

      @em_uploader_opts unquote(opts)
      @em_validations []
      @em_plugins []

      @before_compile EmAttachments.Uploader

      defstruct [:id, :storage, :metadata, :uploader]

      defimpl String.Chars do
        def to_string(%{id: id} = file) when is_binary(id),
          do: String.to_existing_atom(file.uploader).serialize(file)

        def to_string(_), do: ""
      end

      if Code.ensure_loaded?(Phoenix.HTML.Safe) do
        defimpl Phoenix.HTML.Safe do
          def to_iodata(file), do: Phoenix.HTML.Safe.to_iodata(Kernel.to_string(file))
        end
      end

      def __uploader_opts__, do: @em_uploader_opts
    end
  end

  @doc """
  Declares a plugin for this uploader.

      plugin mime: EmAttachments.Plugins.Mime

  """
  defmacro plugin(keyword_list) do
    entries =
      Enum.map(keyword_list, fn {plugin_key, plugin_val} ->
        quote do
          @em_plugins [{unquote(plugin_key), unquote(plugin_val)} | @em_plugins]
        end
      end)

    quote do
      (unquote_splicing(entries))
    end
  end

  @doc """
  Declares validation rules dispatched to the named plugin.

      validates mime: [type: ~w(image/png), extension: ~w(png jpg jpeg)]
  """
  defmacro validates(keyword_list) do
    entries =
      Enum.map(keyword_list, fn {plugin_key, validation_opts} ->
        quote do
          @em_validations [{unquote(plugin_key), unquote(validation_opts)} | @em_validations]
        end
      end)

    quote do
      (unquote_splicing(entries))
    end
  end

  defmacro __before_compile__(env) do
    validations =
      env.module
      |> Module.get_attribute(:em_validations, [])
      |> Enum.reverse()

    plugins =
      env.module
      |> Module.get_attribute(:em_plugins, [])
      |> Enum.reverse()

    normalized = Topo.normalize_plugins(plugins)

    case Topo.resolve_order(normalized) do
      {:error, :cycle} ->
        raise CompileError,
          description: "Circular plugin dependency in #{inspect(env.module)}",
          file: env.file,
          line: env.line

      _ ->
        :ok
    end

    ecto_code =
      if Code.ensure_loaded?(Ecto.Type) do
        quote do
          use Ecto.Type

          def type, do: :map

          def cast(json) when is_binary(json) do
            case __MODULE__.deserialize(json) do
              {:ok, file} -> {:ok, file}
              {:error, _} -> :error
            end
          end

          def cast(%__MODULE__{} = file), do: {:ok, file}
          def cast(_), do: :error

          def load(data) when is_map(data) do
            {:ok, EmAttachments.Uploader.Pipeline.load_file(__MODULE__, data)}
          end

          def load(_), do: :error

          def dump(%__MODULE__{} = file) do
            {:ok,
             file
             |> Map.from_struct()
             |> Map.update(:storage, nil, &to_string/1)}
          end

          def dump(_), do: :error

          defoverridable cast: 1
        end
      else
        quote do
        end
      end

    quote do
      def __validations__, do: unquote(validations)
      def __uploader_plugins__, do: unquote(Macro.escape(normalized))

      def __cast_plugins__ do
        declared = __uploader_plugins__()
        declared_keys = MapSet.new(declared, &elem(&1, 0))

        defaults =
          EmAttachments.Config.default_plugins()
          |> Enum.map(fn
            {k, mod} when is_atom(mod) -> {k, mod, []}
            {k, {mod, plugin_opts}} -> {k, mod, plugin_opts}
          end)
          |> Enum.reject(fn {k, _, _} -> MapSet.member?(declared_keys, k) end)

        defaults ++ declared
      end

      def upload(input, call_opts \\ []) do
        EmAttachments.Uploader.Pipeline.upload(__MODULE__, input, call_opts)
      end

      def delete(file) do
        EmAttachments.Uploader.Pipeline.delete(__MODULE__, file)
      end

      def mark_permanent(repo, file) do
        EmAttachments.Uploader.Pipeline.mark_permanent(repo, __MODULE__, file)
      end

      def mark_pending_for_deletion(repo, file) do
        EmAttachments.Uploader.Pipeline.mark_pending_for_deletion(repo, __MODULE__, file)
      end

      def reprocess(file) do
        EmAttachments.Uploader.Pipeline.reprocess(__MODULE__, file)
      end

      def url(file, opts \\ []) do
        EmAttachments.Uploader.Pipeline.resolve_url(__MODULE__, file, opts)
      end

      def presign_upload do
        EmAttachments.Uploader.Pipeline.presign_upload(__MODULE__)
      end

      def serialize(file) do
        EmAttachments.Uploader.Pipeline.serialize(__MODULE__, file)
      end

      def deserialize(json) do
        EmAttachments.Uploader.Pipeline.deserialize(__MODULE__, json)
      end

      def handle(_, _), do: :skip
      defoverridable handle: 2

      unquote(ecto_code)
    end
  end
end
