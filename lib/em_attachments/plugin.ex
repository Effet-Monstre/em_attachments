defmodule EmAttachments.Plugin do
  @moduledoc """
  Behaviour and macro for defining uploader plugins.

  ## Callbacks (all optional)

  - `upload/6` — called for both the cache phase (during `upload/1`) and the store phase
    (during `promote/1`). Receives the storage type (`:cache` or `:store`) and the active
    backend. Return `{:ok, fragment}` to store metadata under this plugin's key, or `:skip`
    to leave existing metadata unchanged.
  - `validate/4` — called when the uploader declares `validates plugin_key: opts`.
    Receives the plugin's own upload result as third argument.
  - `destroy/4` — called when the parent file is deleted. Use it to clean up any
    derived assets stored by this plugin.
  - `url/5` — called by `resolve_url`. Return `{:ok, url}` to short-circuit, `:skip` to pass.

  ## Usage

      defmodule MyPlugin do
        use EmAttachments.Plugin, depends_on: [mime: EmAttachments.Plugins.Mime]

        def upload(temp_file, _plugin_key, _uploader, deps, _opts, {:cache, _mod, _opts}) do
          {:ok, %{detected: deps[:mime][:type]}}
        end

        def upload(_temp_file, _plugin_key, _uploader, _deps, _opts, {:store, _mod, _opts}) do
          :skip
        end
      end
  """

  @optional_callbacks [init: 5, upload: 6, validate: 4, destroy: 4, url: 5]

  @doc """
  Runs once per upload lifecycle, in the cache phase only.

  If this plugin's result is already in the accumulator (i.e. the file is in the store phase
  and the cache-phase result was seeded in), `init/5` is skipped. The result is placed into
  `deps` under this plugin's own key before `upload/6` is called, so `upload/6` can build on it.

  When both `init/5` and `upload/6` are defined: `upload/6` result takes precedence; if
  `upload/6` returns `:skip`, the `init/5` result is used.
  """
  @callback init(
              source :: EmAttachments.SourceFile.t(),
              plugin_key :: atom(),
              uploader :: module(),
              deps :: map(),
              plugin_opts :: keyword()
            ) :: {:ok, map()} | :skip | {:error, term()}

  @doc """
  Called during both the cache upload and store promotion phases.

  `storage` is `:cache` or `:store`. `backend_mod` and `backend_opts` are the active backend.
  `deps` is a map of results from declared dependency plugins for the current phase.

  Return `{:ok, fragment}` to set this plugin's metadata, or `:skip` to leave it unchanged.
  """
  @callback upload(
              source :: EmAttachments.SourceFile.t(),
              plugin_key :: atom(),
              uploader :: module(),
              deps :: map(),
              plugin_opts :: keyword(),
              {storage :: :cache | :store, backend_mod :: module(), backend_opts :: keyword()}
            ) :: {:ok, map()} | :skip | {:error, term()}

  @doc """
  Called when the uploader declares `validates plugin_key: validation_opts`.
  `own_result` is the map returned by this plugin's `upload/6` during the cache phase.
  Return `:ok` or `{:error, message_or_list}`.
  """
  @callback validate(
              validation_opts :: keyword(),
              source :: EmAttachments.SourceFile.t(),
              own_result :: map(),
              plugin_opts :: keyword()
            ) :: :ok | {:error, String.t()} | {:error, [String.t()]}

  @doc """
  Called when the parent file is being deleted.
  Use this to clean up derived assets (e.g. stored derivative files).
  """
  @callback destroy(
              file :: struct(),
              plugin_key :: atom(),
              backend :: {module(), keyword()},
              plugin_opts :: keyword()
            ) :: :ok | {:error, term()}

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
