defmodule EmAttachments.Plugins.Derivatives do
  @moduledoc """
  Generates derivative files (thumbnails, variants, etc.).

  Define `cast(:derivatives, temp_file)` in your uploader to produce derivatives:

      def cast(:derivatives, file) do
        {:ok, resized} = Operation.thumbnail(file.path, 80)
        {:ok, small_bin} = Image.write_to_buffer(resized, ".png")
        %{small: small_bin}
      end

  The map values may be:
    - A binary (file content) — written to a temp file automatically
    - A path string — used as-is

  Derivatives may be nested: `%{thumb: %{small: bin, large: bin}}`

  Plugin options:
    - `:async` — if true, derivative upload is deferred to `after_upload_async/4`
  """

  use EmAttachments.Plugin

  @impl true
  def cast(temp_file, uploader, _deps, _opts) do
    if function_exported?(uploader, :cast, 2) do
      derivatives = uploader.cast(:derivatives, temp_file)
      {:ok, %{pending: build_pending(derivatives)}}
    else
      {:ok, %{}}
    end
  end

  @impl true
  def after_upload(file, plugin_key, backend, opts) do
    if opts[:async] do
      {:ok, file}
    else
      process(file, plugin_key, backend)
    end
  end

  @impl true
  def after_upload_async(file, plugin_key, backend, _opts) do
    process(file, plugin_key, backend)
  end

  @impl true
  def url(file, nil, _plugin_key, _plugin_opts, _backend), do: :skip
  def url(file, path, plugin_key, _plugin_opts, {backend_mod, backend_opts}) when is_list(path) do
    derivatives = get_in(file.metadata, [:plugins, plugin_key]) || %{}

    result =
      Enum.reduce_while(path, derivatives, fn key, acc ->
        case acc do
          map when is_map(map) and not :erlang.is_map_key(:id, map) ->
            {:cont, Map.get(map, key)}

          _ ->
            {:halt, acc}
        end
      end)

    case result do
      %{id: id, storage: :store} ->
        backend_mod.url(id, backend_opts)

      _ ->
        :skip
    end
  end

  def url(_, _, _, _, _), do: :skip

  defp process(file, plugin_key, {backend_mod, backend_opts}) do
    own_data = get_in(file.metadata, [:plugins, plugin_key]) || %{}

    case own_data[:pending] do
      nil ->
        {:ok, file}

      pending ->
        case upload_pending(pending, backend_mod, backend_opts) do
          {:ok, uploaded} ->
            new_plugins = Map.put(file.metadata.plugins, plugin_key, uploaded)
            {:ok, %{file | metadata: %{file.metadata | plugins: new_plugins}}}

          {:error, _} = err ->
            err
        end
    end
  end

  defp upload_pending(pending, backend_mod, backend_opts) when is_map(pending) do
    Enum.reduce_while(pending, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case upload_item(value, backend_mod, backend_opts) do
        {:ok, result} -> {:cont, {:ok, Map.put(acc, key, result)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp upload_item(%{path: path, id: _}, backend_mod, backend_opts) do
    id = random_id()

    case backend_mod.put(id, path, backend_opts) do
      :ok ->
        File.rm(path)
        {:ok, %{id: id, storage: :store}}

      {:error, _} = err ->
        err
    end
  end

  defp upload_item(map, backend_mod, backend_opts) when is_map(map) do
    upload_pending(map, backend_mod, backend_opts)
  end

  # Build temp-file structs for each derivative.
  defp build_pending(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, build_item(v)} end)
  end

  defp build_item(content) when is_binary(content) do
    path = Path.join(System.tmp_dir!(), "em_attach_#{random_id()}")
    File.write!(path, content)
    %{path: path, id: random_id()}
  end

  defp build_item(path) when is_binary(path) do
    %{path: path, id: random_id()}
  end

  defp build_item(map) when is_map(map) do
    build_pending(map)
  end

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
