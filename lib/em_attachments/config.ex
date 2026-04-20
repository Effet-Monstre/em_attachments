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

  def secret_key! do
    case all()[:secret_key] do
      nil -> raise "EmAttachments: :secret_key is not configured under config :em_attachments, :config"
      key -> key
    end
  end

  def image_adapter do
    all()[:image_adapter]
  end

  def async_dispatcher do
    all()[:async_dispatcher] || :inline
  end

  # nil or :default → use global config as-is
  defp resolve(type, nil), do: resolve(type, :default)

  defp resolve(type, :default) do
    case all()[type] do
      nil ->
        raise "EmAttachments: :#{type} backend is not configured under config :em_attachments, :config"

      {mod, opts} ->
        {mod, opts}

      mod when is_atom(mod) ->
        {mod, []}
    end
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

    {mod, Keyword.merge(global_opts, override_opts)}
  end
end
