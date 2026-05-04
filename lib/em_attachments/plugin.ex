defmodule EmAttachments.Plugin do
  @moduledoc """
  Behaviour and macro for defining uploader plugins.

  ## Callbacks (all optional)

  - `upload/3` — called during the upload pipeline. `storage` is `{backend_mod, backend_opts}`.
    `ctx` carries `plugin_key`, `uploader`, `deps`, and `plugin_opts`.
    Return `{:ok, fragment}` to store metadata under this plugin's key, or `:skip`
    to leave existing metadata unchanged.
  - `validate/3` — called when the uploader declares `validates plugin_key: opts`.
    `ctx` carries `plugin_key`, `plugin_opts`, and `validation_opts`.
  - `destroy/2` — called when the parent file is deleted. `ctx` carries `plugin_key`,
    `plugin_opts`, and `backend`. Use it to clean up any derived assets stored by this plugin.
  - `url/3` — called by `resolve_url`. Return `{:ok, url}` to short-circuit, `:skip` to pass.
    `ctx` carries `plugin_key`, `plugin_opts`, and `backend`.
  - `after_confirm/2` — called by the Sweeper when a permanent row is finalized.
    Use it for post-confirmation work such as changing ACLs on derived assets.

  ## Usage

      defmodule MyPlugin do
        use EmAttachments.Plugin, depends_on: [mime: EmAttachments.Plugins.Mime]

        def upload(temp_file, {_backend_mod, _backend_opts}, ctx) do
          {:ok, %{detected: ctx.deps[:mime][:type]}}
        end
      end
  """

  @optional_callbacks [cast: 2, init: 2, upload: 3, validate: 3, destroy: 2, url: 3, after_confirm: 2]

  @doc """
  Called by `cast_attachments` before the upload pipeline to convert a raw changeset
  value into a `SourceFile`. Return `{:ok, source}` to claim the value, `:skip` to
  pass it to the next plugin, or `{:error, message}` to fail with that message.
  """
  @callback cast(
              value :: term(),
              ctx :: %{uploader: module(), plugin_key: atom(), plugin_opts: keyword()}
            ) :: {:ok, EmAttachments.SourceFile.t()} | :skip | {:error, String.t()}

  @doc """
  Runs once per upload lifecycle before `upload/3`.

  The result is placed into `deps` under this plugin's own key before `upload/3` is called.
  When both `init/2` and `upload/3` are defined: `upload/3` result takes precedence; if
  `upload/3` returns `:skip`, the `init/2` result is used.
  """
  @callback init(
              source :: EmAttachments.SourceFile.t(),
              ctx :: %{plugin_key: atom(), uploader: module(), deps: map(), plugin_opts: keyword()}
            ) :: {:ok, map()} | :skip | {:error, term()}

  @doc """
  Called during the upload pipeline.

  `storage` is `{backend_mod, backend_opts}`. `ctx.deps` is a map of results
  from declared dependency plugins.

  Return `{:ok, fragment}` to set this plugin's metadata, or `:skip` to leave it unchanged.
  """
  @callback upload(
              source :: EmAttachments.SourceFile.t(),
              storage :: {backend_mod :: module(), backend_opts :: keyword()},
              ctx :: %{plugin_key: atom(), uploader: module(), deps: map(), plugin_opts: keyword()}
            ) :: {:ok, map()} | :skip | {:error, term()}

  @doc """
  Called when the uploader declares `validates plugin_key: validation_opts`.
  `own_result` is the map returned by this plugin's `upload/3`.
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

  @doc """
  Called by the Sweeper after a pending upload row is confirmed as permanent.

  Use this for post-confirmation side effects such as updating ACLs on derived assets.
  `ctx.backend` is `{backend_mod, backend_opts}`.
  """
  @callback after_confirm(
              file :: struct(),
              ctx :: %{plugin_key: atom(), plugin_opts: keyword(), backend: {module(), keyword()}}
            ) :: :ok | {:error, term()}

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
