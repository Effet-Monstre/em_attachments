defmodule EmAttachments.Uploader do
  @moduledoc """
  Macro for defining uploaders.

  ## Basic usage

      defmodule MyApp.AvatarUploader do
        use EmAttachments.Uploader,
          plugins: [
            mime: EmAttachments.Plugins.Mime,
            dimensions: EmAttachments.Plugins.Dimensions,
            derivatives: {EmAttachments.Plugins.Derivatives, async: false}
          ]

        validates mime: [type: ~w(image/png image/jpeg), extension: ~w(png jpg jpeg)]
        validates dimensions: [max_width: 4000, max_height: 4000]

        # Override store/cache backend for this uploader only:
        # use EmAttachments.Uploader, store: {Backends.S3, acl: :public_read}, ...

        # Custom validation (receives temp_file and all plugin results):
        def validate(temp_file, plugin_results) do
          case plugin_results[:dimensions] do
            %{width: w, height: h} when w != h -> {:error, "must be square"}
            _ -> :ok
          end
        end

        # Generate derivatives:
        def cast(:derivatives, file) do
          {:ok, resized} = Operation.thumbnail(file.path, 80)
          {:ok, small} = Image.write_to_buffer(resized, ".png")
          %{small: small}
        end
      end

  ## Ecto integration

  When `ecto` is a dependency, the uploader module is also an `Ecto.Type` and
  can be used directly as a field type. Use `cast_attachments/2` from
  `EmAttachments.Ecto` in your changeset.
  """

  alias EmAttachments.Uploader.Pipeline

  defmacro __using__(opts) do
    quote do
      import EmAttachments.Uploader, only: [validates: 1]

      @em_uploader_opts unquote(opts)
      @em_validations []

      @before_compile EmAttachments.Uploader

      defstruct [:id, :storage, :metadata, :uploader]

      def __uploader_opts__, do: @em_uploader_opts

      def __uploader_plugins__ do
        EmAttachments.Uploader.Pipeline.normalize_plugins(
          @em_uploader_opts[:plugins] || []
        )
      end
    end
  end

  @doc """
  Declares validation rules dispatched to the named plugin.

      validates mime: [type: ~w(image/png), extension: ~w(png jpg)]
  """
  defmacro validates(keyword_list) do
    entries =
      Enum.map(keyword_list, fn {plugin_key, validation_opts} ->
        quote do
          @em_validations [{unquote(plugin_key), unquote(validation_opts)} | @em_validations]
        end
      end)

    quote do
      unquote_splicing(entries)
    end
  end

  defmacro __before_compile__(env) do
    validations =
      env.module
      |> Module.get_attribute(:em_validations, [])
      |> Enum.reverse()

    plugins =
      env.module
      |> Module.get_attribute(:em_uploader_opts, [])
      |> Keyword.get(:plugins, [])

    normalized = Pipeline.normalize_plugins(plugins)

    # Cycle detection at compile time.
    case Pipeline.resolve_order(normalized) do
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
        plug_cast =
          if Code.ensure_loaded?(Plug.Upload) do
            quote do
              def cast(%Plug.Upload{} = upload) do
                __MODULE__.upload(upload)
              end
            end
          else
            quote do
            end
          end

        quote do
          use Ecto.Type

          def type, do: :map

          unquote(plug_cast)

          def cast(json) when is_binary(json) do
            case __MODULE__.deserialize(json) do
              {:ok, %{storage: :cache} = file} -> {:ok, file}
              {:ok, _} -> :error
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

      def upload(input) do
        EmAttachments.Uploader.Pipeline.upload(__MODULE__, input)
      end

      def promote(cached_file) do
        EmAttachments.Uploader.Pipeline.promote(__MODULE__, cached_file)
      end

      def delete(file) do
        EmAttachments.Uploader.Pipeline.delete(__MODULE__, file)
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

      unquote(ecto_code)
    end
  end
end
