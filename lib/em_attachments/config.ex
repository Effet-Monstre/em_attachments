defmodule EmAttachments.Config do
  @moduledoc false

  @default_expiry :timer.hours(24)
  @default_sweeper_interval :timer.minutes(30)

  def all do
    Application.get_env(:em_attachments, :config, [])
  end

  @doc "Returns {backend_mod, opts} for the store, merging global config with uploader overrides."
  def store(uploader_opts \\ []) do
    resolve(:store, uploader_opts[:store])
  end

  @doc "Returns the configured Ecto repo module, or nil if not set."
  def repo do
    all()[:repo]
  end

  @doc "Returns the configured Ecto repo module, raising if not set."
  def repo! do
    case all()[:repo] do
      nil ->
        raise "EmAttachments: :repo is not configured under config :em_attachments, :config. " <>
                "Add `repo: MyApp.Repo` to your config and run `mix em_attachments.gen.migration`."

      r ->
        r
    end
  end

  @doc "Returns the pending upload expiry in milliseconds (default: 24h)."
  def expiry do
    all()[:expiry] || @default_expiry
  end

  @doc "Returns the opts forwarded to backend.finalize/2 (default: [])."
  def finalize_opts do
    all()[:finalize_opts] || []
  end

  @doc "Returns the sweeper tick interval in milliseconds (default: 30m)."
  def sweeper_interval do
    all()[:sweeper_interval] || @default_sweeper_interval
  end

  @doc "Returns the uploads schema name (default: nil — no schema)."
  def schema_name do
    all()[:schema_name]
  end

  @doc "Returns the uploads table name. Defaults to \"uploads\" when a schema is configured, \"em_attachments_uploads\" otherwise."
  def table_name do
    case all()[:table_name] do
      nil -> if schema_name(), do: "uploads", else: "em_attachments_uploads"
      name -> name
    end
  end

  @doc """
  Returns the default plugins prepended to every uploader's plugin list.

  Built-in defaults include the three cast plugins (PlugUpload when Plug is
  available, UrlUpload, Binary). Override entirely with:

      config :em_attachments, :config, default_plugins: [...]

  Set to `[]` to opt out of all defaults.
  """
  def default_plugins do
    case all()[:default_plugins] do
      nil ->
        plug =
          if Code.ensure_loaded?(Plug.Upload),
            do: [plug_upload: EmAttachments.Plugins.PlugUpload],
            else: []

        plug ++
          [
            url_upload: EmAttachments.Plugins.UrlUpload,
            binary: EmAttachments.Plugins.Binary
          ]

      list ->
        list
    end
  end

  def secret_key! do
    case all()[:secret_key] do
      nil ->
        raise "EmAttachments: :secret_key is not configured under config :em_attachments, :config"

      key ->
        resolve_value(key)
    end
  end

  @doc """
  Resolves a config value, expanding `{:env, "VAR_NAME"}` tuples via `System.get_env/1`.

  Raises if the env var is not set and no default is given.
  Accepts `{:env, "VAR"}` or `{:env, "VAR", default}`.
  """
  def resolve_value({:env, var}) when is_binary(var) do
    System.get_env(var) ||
      raise "EmAttachments: environment variable #{inspect(var)} is not set"
  end

  def resolve_value({:env, var, default}) when is_binary(var) do
    System.get_env(var) || default
  end

  def resolve_value(value), do: value

  defp resolve_opts(opts) do
    Enum.map(opts, fn {k, v} -> {k, resolve_value(v)} end)
  end

  defp resolve(type, nil), do: resolve(type, :default)

  defp resolve(type, :default) do
    case all()[type] do
      nil ->
        raise "EmAttachments: :#{type} backend is not configured under config :em_attachments, :config"

      {mod, opts} ->
        {mod, resolve_opts(opts)}

      mod when is_atom(mod) ->
        {mod, []}
    end
  end

  defp resolve(type, {override_mod, override_opts}) do
    {global_mod, global_opts} =
      case all()[type] do
        {m, o} -> {m, o}
        m when is_atom(m) -> {m, []}
        nil -> {nil, []}
      end

    mod = override_mod || global_mod

    if is_nil(mod) do
      raise "EmAttachments: no backend module resolved for :#{type}"
    end

    {mod, Keyword.merge(resolve_opts(global_opts), resolve_opts(override_opts))}
  end
end
