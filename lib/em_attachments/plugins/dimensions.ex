defmodule EmAttachments.Plugins.Dimensions do
  @moduledoc """
  Reads image dimensions using a configured `EmAttachments.ImageAdapter`.

  Cast result: `%{width: 800, height: 600}`

  Plugin options:
    - `:adapter` — override the globally configured image adapter

  Validation options:
    - `:min_width`, `:max_width`, `:min_height`, `:max_height`
  """

  use EmAttachments.Plugin

  @impl true
  def cast(temp_file, _uploader, _deps, opts) do
    adapter = opts[:adapter] || EmAttachments.Config.image_adapter()

    cond do
      is_nil(adapter) ->
        {:error, "no image adapter configured — set :image_adapter in config or pass adapter: opt"}

      not Code.ensure_loaded?(adapter) ->
        {:error, "image adapter #{inspect(adapter)} is not available"}

      true ->
        adapter.dimensions(temp_file.path)
    end
  end

  @impl true
  def validate(validation_opts, _temp_file, own_result, _plugin_opts) do
    w = own_result[:width] || 0
    h = own_result[:height] || 0

    errors =
      []
      |> validate_bound(:max_width, w, validation_opts[:max_width], :lte)
      |> validate_bound(:min_width, w, validation_opts[:min_width], :gte)
      |> validate_bound(:max_height, h, validation_opts[:max_height], :lte)
      |> validate_bound(:min_height, h, validation_opts[:min_height], :gte)

    case errors do
      [] -> :ok
      [single] -> {:error, single}
      many -> {:error, many}
    end
  end

  defp validate_bound(errors, _key, _val, nil, _op), do: errors

  defp validate_bound(errors, key, val, limit, :lte) do
    if val <= limit, do: errors, else: ["#{key}: #{val} exceeds maximum of #{limit}" | errors]
  end

  defp validate_bound(errors, key, val, limit, :gte) do
    if val >= limit, do: errors, else: ["#{key}: #{val} below minimum of #{limit}" | errors]
  end
end
