defmodule EmAttachments.Plugin do
  @moduledoc """
  Behaviour and macro for defining uploader plugins.

  ## Callbacks (all optional)

  - `cast/4` — runs synchronously at upload time, has access to the temp file path.
    Returns a metadata fragment stored under the plugin's key.
  - `after_upload/4` — runs synchronously after promotion to store.
  - `after_upload_async/4` — runs asynchronously after promotion (if `async: true` in plugin opts).
    Returns a metadata fragment merged into the stored record.
  - `validate/4` — called when the uploader declares `validates plugin_key: opts`.
    Receives the plugin's own cast result as third argument.
  - `url/5` — called by `resolve_url`. Return `{:ok, url}` to short-circuit, `:skip` to pass.

  ## Usage

      defmodule MyPlugin do
        use EmAttachments.Plugin, depends_on: [mime: EmAttachments.Plugins.Mime]

        def cast(temp_file, _uploader, deps, _opts) do
          {:ok, %{detected: deps[:mime][:type]}}
        end
      end
  """

  @optional_callbacks [cast: 4, after_upload: 4, after_upload_async: 4, validate: 4, url: 5]

  @doc """
  Runs synchronously at upload time. Has access to the temp file (path is readable).
  `deps` is a map of results from declared dependency plugins.
  Returns `{:ok, metadata_fragment}`.
  """
  @callback cast(
              temp_file :: EmAttachments.TempFile.t(),
              uploader :: module(),
              deps :: map(),
              plugin_opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Runs synchronously after promotion to the store backend.
  `plugin_key` is the key under which this plugin is registered in the uploader.
  `backend` is `{backend_mod, backend_opts}`.
  """
  @callback after_upload(
              file :: struct(),
              plugin_key :: atom(),
              backend :: {module(), keyword()},
              plugin_opts :: keyword()
            ) :: {:ok, struct()} | {:error, term()}

  @doc """
  Runs asynchronously after promotion. Called only when `async: true` in plugin opts.
  Returns a metadata fragment merged into `file.metadata.plugins[plugin_key]`.
  """
  @callback after_upload_async(
              file :: struct(),
              plugin_key :: atom(),
              backend :: {module(), keyword()},
              plugin_opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Called when the uploader declares `validates plugin_key: validation_opts`.
  `own_result` is the map returned by this plugin's `cast/4`.
  Return `:ok` or `{:error, message_or_list}`.
  """
  @callback validate(
              validation_opts :: keyword(),
              temp_file :: EmAttachments.TempFile.t(),
              own_result :: map(),
              plugin_opts :: keyword()
            ) :: :ok | {:error, String.t()} | {:error, [String.t()]}

  @doc """
  Called by `resolve_url`. Receives `call_opts[plugin_key]` as `plugin_call_opts`.
  Return `{:ok, url}` to short-circuit, or `:skip` to let the next plugin try.
  `backend` is the store backend `{mod, opts}`.
  """
  @callback url(
              file :: struct(),
              plugin_call_opts :: term(),
              plugin_key :: atom(),
              plugin_opts :: keyword(),
              backend :: {module(), keyword()}
            ) :: {:ok, String.t()} | :skip

  defmacro __using__(opts) do
    deps = opts[:depends_on] || []

    quote do
      @behaviour EmAttachments.Plugin
      @em_plugin_deps unquote(deps)
      @before_compile EmAttachments.Plugin
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      unless Module.defines?(__MODULE__, {:__plugin_deps__, 0}) do
        def __plugin_deps__, do: @em_plugin_deps
      end
    end
  end
end
