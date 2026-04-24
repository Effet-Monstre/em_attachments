defmodule EmAttachments.Plugin do
  @moduledoc """
  Behaviour and macro for defining uploader plugins.

  ## Callbacks (all optional)

  - `upload/3` — called for both the cache phase (during `upload/1`) and the store phase
    (during `promote/1`). `ctx` carries `plugin_key`, `uploader`, `deps`, and `plugin_opts`.
    Return `{:ok, fragment}` to store metadata under this plugin's key, or `:skip`
    to leave existing metadata unchanged.
  - `validate/3` — called when the uploader declares `validates plugin_key: opts`.
    `ctx` carries `plugin_key`, `plugin_opts`, and `validation_opts`.
  - `destroy/2` — called when the parent file is deleted. `ctx` carries `plugin_key`,
    `plugin_opts`, and `backend`. Use it to clean up any derived assets stored by this plugin.
  - `url/3` — called by `resolve_url`. Return `{:ok, url}` to short-circuit, `:skip` to pass.
    `ctx` carries `plugin_key`, `plugin_opts`, and `backend`.

  ## Usage

      defmodule MyPlugin do
        use EmAttachments.Plugin, depends_on: [mime: EmAttachments.Plugins.Mime]

        def upload(temp_file, {:cache, _mod, _opts}, ctx) do
          {:ok, %{detected: ctx.deps[:mime][:type]}}
        end

        def upload(_temp_file, {:store, _mod, _opts}, _ctx) do
          :skip
        end
      end
  """

  @optional_callbacks [init: 2, upload: 3, validate: 3, destroy: 2, url: 3]

  @doc """
  Runs once per upload lifecycle, in the cache phase only.

  If this plugin's result is already in the accumulator (i.e. the file is in the store phase
  and the cache-phase result was seeded in), `init/2` is skipped. The result is placed into
  `deps` under this plugin's own key before `upload/3` is called, so `upload/3` can build on it.

  When both `init/2` and `upload/3` are defined: `upload/3` result takes precedence; if
  `upload/3` returns `:skip`, the `init/2` result is used.
  """
  @callback init(
              source :: EmAttachments.SourceFile.t(),
              ctx :: %{plugin_key: atom(), uploader: module(), deps: map(), plugin_opts: keyword()}
            ) :: {:ok, map()} | :skip | {:error, term()}

  @doc """
  Called during both the cache upload and store promotion phases.

  `storage` is `{:cache | :store, backend_mod, backend_opts}`. `ctx.deps` is a map of results
  from declared dependency plugins for the current phase.

  Return `{:ok, fragment}` to set this plugin's metadata, or `:skip` to leave it unchanged.
  """
  @callback upload(
              source :: EmAttachments.SourceFile.t(),
              storage :: {:cache | :store, backend_mod :: module(), backend_opts :: keyword()},
              ctx :: %{plugin_key: atom(), uploader: module(), deps: map(), plugin_opts: keyword()}
            ) :: {:ok, map()} | :skip | {:error, term()}

  @doc """
  Called when the uploader declares `validates plugin_key: validation_opts`.
  `own_result` is the map returned by this plugin's `upload/3` during the cache phase.
  Return `:ok` or `{:error, message_or_list}`.
  """
  @callback validate(
              source :: EmAttachments.SourceFile.t(),
              own_result :: map(),
              ctx :: %{plugin_key: atom(), plugin_opts: keyword(), validation_opts: keyword()}
            ) :: :ok | {:error, String.t()} | {:error, [String.t()]}

  @doc """
  Called when the parent file is being deleted.
  Use this to clean up derived assets (e.g. stored derivative files).
  `ctx.backend` is the store backend `{mod, opts}`.
  """
  @callback destroy(
              file :: struct(),
              ctx :: %{plugin_key: atom(), plugin_opts: keyword(), backend: {module(), keyword()}}
            ) :: :ok | {:error, term()}

  @doc """
  Called by `resolve_url`. Return `{:ok, url}` to short-circuit, or `:skip` to let the next
  plugin try. `plugin_call_opts` is `call_opts[plugin_key]`. `ctx.backend` is the store backend.
  """
  @callback url(
              file :: struct(),
              plugin_call_opts :: term(),
              ctx :: %{plugin_key: atom(), plugin_opts: keyword(), backend: {module(), keyword()}}
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
