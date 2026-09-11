defmodule EmAttachments.Plugins.Mime do
  @moduledoc """
  Detects the real MIME type from magic bytes (not from file extension or browser-provided content-type).

  Upload result: `%{type: "image/png", extension: "png"}`

  Validation options:
    - `:type` — list of allowed MIME types
    - `:extension` — list of allowed extensions
  """

  use EmAttachments.Plugin

  @impl true
  def init(source, _ctx) do
    case EmAttachments.Mime.detect_source(source) do
      {:ok, {type, ext}} -> {:ok, %{type: type, extension: ext}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def validate(_source, own_result, ctx) do
    errors =
      []
      |> check_type(ctx.validation_opts[:type], own_result[:type])
      |> check_extension(ctx.validation_opts[:extension], own_result[:extension])

    case errors do
      [] -> :ok
      [single] -> {:error, single}
      many -> {:error, many}
    end
  end

  defp check_type(errors, nil, _), do: errors

  defp check_type(errors, allowed, detected) do
    if detected in allowed,
      do: errors,
      else: [
        "invalid MIME type #{inspect(detected)}, allowed: #{Enum.join(allowed, ", ")}" | errors
      ]
  end

  defp check_extension(errors, nil, _), do: errors

  defp check_extension(errors, allowed, detected) do
    if detected in allowed,
      do: errors,
      else: [
        "invalid extension #{inspect(detected)}, allowed: #{Enum.join(allowed, ", ")}" | errors
      ]
  end
end
