defmodule EmAttachments.Config do
  @moduledoc false

  def all do
    Application.get_env(:em_attachments, :config, [])
  end

  @doc "Returns {backend_mod, opts} for the store, merging global config with uploader overrides."
  def store(uploader_opts \\ []) do
    resolve(:store, uploader_opts[:store])
  end

  @doc "Returns {backend_mod, opts} for the cache, merging global config with uploader overrides."
  def cache(uploader_opts \\ []) do
    resolve(:cache, uploader_opts[:cache])
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

  # nil or :default → use global config as-is
  defp resolve(type, nil), do: resolve(type, :default)

  defp resolve(type, :default) do
    case all()[type] do
      nil ->
        raise "EmAttachments: :#{type} backend is not configured under config :em_attachments, :config"

      # Keyword list for :cache — inherit the store's adapter + opts, merge cache opts on top.
      opts when is_list(opts) and type == :cache ->
        {store_mod, store_opts} = resolve(:store, :default)
        {store_mod, Keyword.merge(store_opts, resolve_opts(opts))}

      {mod, opts} ->
        {mod, resolve_opts(opts)}

      mod when is_atom(mod) ->
        {mod, []}
    end
  end

  # Keyword list as uploader-level cache override — merge over the already-resolved global cache.
  defp resolve(:cache, override_opts) when is_list(override_opts) do
    {base_mod, base_opts} = resolve(:cache, :default)
    {base_mod, Keyword.merge(base_opts, resolve_opts(override_opts))}
  end

  # {mod, opts} → merge with global opts, override module if given
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
