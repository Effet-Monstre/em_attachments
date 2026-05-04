defmodule EmAttachments.Plugins.Derivatives do
  @moduledoc """
  Generates derivative files (thumbnails, variants, etc.).

  Define `handle/2` in your uploader to produce derivatives. The first argument
  is the plugin key as declared in the uploader (not necessarily `:derivatives`).
  The second is a map containing `:file` (a `EmAttachments.SourceFile.t()`).

  Use `EmAttachments.SourceFile.local_path!/1` to get a filesystem path:

      def handle(:derivatives, %{file: file}) do
        path = EmAttachments.SourceFile.local_path!(file)
        {:ok, resized} = Operation.thumbnail(path, 80)
        {:ok, small_bin} = Image.write_to_buffer(resized, ".png")
        %{small: small_bin}
      end

  Map values may be:
    - A binary (file content) — written to a temp file automatically
    - A path string — used as-is

  Derivatives may be nested: `%{thumb: %{small: bin, large: bin}}`
  """

  use EmAttachments.Plugin

  require Logger

  alias EmAttachments.{Cmd, MemoryFile, SourceFile, TempFile, Util}

  @impl true
  def upload(source, {backend_mod, backend_opts}, ctx) do
    if not function_exported?(ctx.uploader, :handle, 2) do
      :skip
    else
      case ctx.uploader.handle(ctx.plugin_key, %{file: source}) do
        map when is_map(map) ->
          case upload_derivatives(map, backend_mod, backend_opts, source) do
            {:ok, uploaded} -> {:ok, %{variants: uploaded}}
            {:error, _} = err -> err
          end

        :skip ->
          :skip
      end
    end
  end

  @impl true
  def destroy(file, ctx) do
    {backend_mod, backend_opts} = ctx.backend
    own_data = get_in(file.metadata, [:plugins, ctx.plugin_key]) || %{}

    collect_ids(own_data)
    |> Enum.each(fn id -> backend_mod.delete(id, backend_opts) end)

    :ok
  end

  @impl true
  def asset_ids(file, ctx) do
    own_data = get_in(file.metadata, [:plugins, ctx.plugin_key]) || %{}
    collect_ids(own_data)
  end

  @impl true
  def after_confirm(file, ctx) do
    {backend_mod, backend_opts} = ctx.backend

    if function_exported?(backend_mod, :finalize, 2) do
      finalize_opts = Map.get(ctx, :finalize_opts, [])
      merged_opts = Keyword.merge(backend_opts, finalize_opts)
      own_data = get_in(file.metadata, [:plugins, ctx.plugin_key]) || %{}

      for id <- collect_ids(own_data) do
        case backend_mod.finalize(id, merged_opts) do
          :ok ->
            :ok

          {:error, :not_found} ->
            Logger.warning(
              "EmAttachments.Plugins.Derivatives: asset #{id} not found during after_confirm"
            )

          {:error, reason} ->
            Logger.error(
              "EmAttachments.Plugins.Derivatives: finalize failed for #{id}: #{inspect(reason)}"
            )
        end
      end
    end

    :ok
  end

  @impl true
  def url(_file, nil, _ctx), do: :skip

  def url(file, path, ctx) when is_list(path) do
    {backend_mod, backend_opts} = ctx.backend
    plugin_data = get_in(file.metadata, [:plugins, ctx.plugin_key]) || %{}
    derivatives = plugin_data[:variants] || %{}

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
      %{id: id} ->
        backend_mod.url(id, backend_opts)

      _ ->
        :skip
    end
  end

  def url(_, _, _), do: :skip

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Uploads a map of handler outputs in parallel.
  # resolve_cmds expands {:cmd,...}/{:cmd_stdout,...} tuples using the source file.
  # build_pending converts binaries to TempFiles; nested maps are recursed.
  # All leaf TempFiles/MemoryFiles are collected flat, uploaded concurrently, then
  # the original tree shape is reconstructed from the results.
  defp upload_derivatives(map, backend_mod, backend_opts, source) when is_map(map) do
    resolved = resolve_cmds(map, source)
    pending = build_pending(resolved)
    flat = collect_items(pending)

    flat
    |> Task.async_stream(
      fn {key_path, item} ->
        id = Util.random_id(8)
        result = backend_mod.put(id, item, backend_opts)
        if result == :ok, do: cleanup_source(item)
        {key_path, id, result}
      end,
      ordered: true
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {key_path, id, :ok}}, {:ok, acc} ->
        {:cont, {:ok, [{key_path, %{id: id, storage: :store}} | acc]}}

      {:ok, {_, _, {:error, _} = err}}, _ ->
        {:halt, err}

      {:exit, reason}, _ ->
        {:halt, {:error, {:task_exit, reason}}}
    end)
    |> case do
      {:ok, results} -> {:ok, reconstruct_tree(Enum.reverse(results))}
      err -> err
    end
  end

  # Flattens a pending map (built from build_pending) to [{[key_path], TempFile | MemoryFile}].
  defp collect_items(map, prefix \\ []) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      path = prefix ++ [key]

      case value do
        %TempFile{} = tf -> [{path, tf}]
        %MemoryFile{} = mf -> [{path, mf}]
        nested when is_map(nested) -> collect_items(nested, path)
      end
    end)
  end

  # Reconstructs the nested map shape from a flat [{[key_path], value}] list.
  defp reconstruct_tree(items) do
    Enum.reduce(items, %{}, fn {path, value}, acc -> put_in_path(acc, path, value) end)
  end

  defp put_in_path(map, [key], value), do: Map.put(map, key, value)

  defp put_in_path(map, [key | rest], value) do
    Map.update(map, key, put_in_path(%{}, rest, value), &put_in_path(&1, rest, value))
  end

  defp build_pending(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, build_item(v)} end)
  end

  defp build_item(%TempFile{} = tf), do: tf
  defp build_item(%MemoryFile{} = mf), do: mf

  defp build_item(content) when is_binary(content) do
    path = Path.join(System.tmp_dir!(), "em_attach_#{Util.random_id(8)}")
    File.write!(path, content)
    TempFile.new(path, "derivative")
  end

  defp build_item(map) when is_map(map), do: build_pending(map)

  defp resolve_cmds(map, source) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, resolve_cmd_item(v, source)} end)
  end

  defp resolve_cmd_item({:cmd, cmd, args}, source),
    do: resolve_cmd_item({:cmd, cmd, args, []}, source)

  defp resolve_cmd_item({:cmd, cmd, args, opts}, source) do
    Cmd.run!(cmd, args, SourceFile.local_path!(source), opts)
  end

  defp resolve_cmd_item({:cmd_stdout, cmd, args}, source),
    do: resolve_cmd_item({:cmd_stdout, cmd, args, []}, source)

  defp resolve_cmd_item({:cmd_stdout, cmd, args, opts}, source) do
    Cmd.run_stdout!(cmd, args, SourceFile.local_path!(source), opts)
  end

  defp resolve_cmd_item(%TempFile{} = tf, _source), do: tf
  defp resolve_cmd_item(%MemoryFile{} = mf, _source), do: mf
  defp resolve_cmd_item(map, source) when is_map(map), do: resolve_cmds(map, source)
  defp resolve_cmd_item(other, _source), do: other

  defp cleanup_source(%TempFile{path: path}), do: File.rm(path)
  defp cleanup_source(%MemoryFile{} = mf), do: MemoryFile.cleanup(mf)

  defp collect_ids(map) when is_map(map) do
    Enum.flat_map(map, fn {_k, v} ->
      case v do
        %{id: id} -> [id]
        nested when is_map(nested) -> collect_ids(nested)
        _ -> []
      end
    end)
  end

  defp collect_ids(_), do: []
end
