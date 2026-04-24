defmodule EmAttachments.Plugins.Dimensions do
  @moduledoc """
  Reads image dimensions using an `EmAttachments.ImageAdapter` module or an anonymous function.

  Upload result: `%{width: 800, height: 600}`

  Plugin options:
    - `:adapter` — a module implementing `EmAttachments.ImageAdapter`, or a
      1-arity function `fn path -> {:ok, %{width: w, height: h}} end` (required)

  Validation options:
    - `:min_width`, `:max_width`, `:min_height`, `:max_height`
  """

  use EmAttachments.Plugin

  @impl true
  def init(source, _plugin_key, _uploader, _deps, opts) do
    path = EmAttachments.SourceFile.local_path!(source)

    case opts[:adapter] do
      nil ->
        {:error, "dimensions plugin requires an adapter: opt — pass a module or fn/1"}

      adapter when is_function(adapter, 1) ->
        adapter.(path)

      adapter ->
        if Code.ensure_loaded?(adapter) do
          adapter.dimensions(path)
        else
          {:error, "image adapter #{inspect(adapter)} is not available"}
        end
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
