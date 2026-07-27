defmodule EmAttachments.Plugins.Derivatives do
  @moduledoc """
  Generates derivative files (thumbnails, variants, etc.).

  Define `handle/2` in your uploader to produce derivatives. The first argument
  is the plugin key as declared in the uploader (not necessarily `:derivatives`).
  The second is a map containing:

    - `:file` — a `EmAttachments.SourceFile.t()`
    - `:plugins` — the data produced by every plugin that ran before this one,
      keyed by plugin key (e.g. `%{mime: %{type: "image/png", extension: "png"}}`)

  Use `EmAttachments.SourceFile.local_path!/1` to get a filesystem path:

      def handle(:derivatives, %{file: file}) do
        path = EmAttachments.SourceFile.local_path!(file)
        {:ok, resized} = Operation.thumbnail(path, 80)
        {:ok, small_bin} = Image.write_to_buffer(resized, ".png")
        %{small: small_bin}
      end

  Read another plugin's data with `EmAttachments.plugin_data/2` rather than
  re-detecting it (the `:mime` plugin must be declared before this one):

      def handle(:derivatives, %{file: file} = ctx) do
        case EmAttachments.plugin_data(ctx, :mime) do
          %{type: "image/" <> _} -> %{thumb: thumbnail(file)}
          _ -> :skip
        end
      end

  Map values may be:
    - A binary (file content) — written to a temp file automatically
    - A path string — used as-is

  Derivatives may be nested: `%{thumb: %{small: bin, large: bin}}`

  Plugin options:
    - `:max_concurrency` — maximum simultaneous backend uploads (default: 2)
    - `:timeout` — per-upload task timeout (default: `:infinity`)
  """

  use EmAttachments.Plugin

  require Logger

  alias EmAttachments.{Cmd, MemoryFile, SourceFile, TempFile, Util}

  @impl true
  def upload(source, {backend_mod, backend_opts}, ctx) do
    if not function_exported?(ctx.uploader, :handle, 2) do
      :skip
    else
      case ctx.uploader.handle(ctx.plugin_key, %{file: source, plugins: ctx.plugins}) do
        map when is_map(map) ->
          case upload_derivatives(map, backend_mod, backend_opts, source, ctx.plugin_opts) do
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
  # prepare_pending expands commands and immediately materializes binaries to managed files.
  # All leaf TempFiles/MemoryFiles are collected flat, uploaded concurrently, then
  # the original tree shape is reconstructed from the results.
  defp upload_derivatives(map, backend_mod, backend_opts, source, plugin_opts)
       when is_map(map) do
    pending = prepare_pending(map, source)
    flat = collect_items(pending)
    max_concurrency = Keyword.get(plugin_opts, :max_concurrency, 2)
    timeout = Keyword.get(plugin_opts, :timeout, :infinity)

    try do
      {uploaded, error} =
        flat
        |> Task.async_stream(
          fn {key_path, item} -> upload_item(key_path, item, backend_mod, backend_opts) end,
          ordered: false,
          max_concurrency: max_concurrency,
          timeout: timeout
        )
        |> Enum.reduce({[], nil}, fn
          {:ok, {:ok, key_path, id}}, {uploaded, error} ->
            {[{key_path, %{id: id, storage: :store}} | uploaded], error}

          {:ok, {:error, reason}}, {uploaded, nil} ->
            {uploaded, reason}

          {:ok, {:error, _reason}}, acc ->
            acc

          {:exit, reason}, {uploaded, nil} ->
            {uploaded, {:task_exit, reason}}

          {:exit, _reason}, acc ->
            acc
        end)

      if error do
        rollback_uploaded(uploaded, backend_mod, backend_opts)
        {:error, error}
      else
        {:ok, reconstruct_tree(Enum.reverse(uploaded))}
      end
    after
      Enum.each(flat, fn {_key_path, item} -> cleanup_source(item) end)
    end
  end

  defp upload_item(key_path, item, backend_mod, backend_opts) do
    id = Util.random_id(8)

    try do
      case backend_mod.put(id, item, backend_opts) do
        :ok ->
          {:ok, key_path, id}

        {:error, reason} ->
          safe_delete(backend_mod, id, backend_opts)
          {:error, reason}
      end
    rescue
      exception ->
        safe_delete(backend_mod, id, backend_opts)
        {:error, {:task_exit, {exception, __STACKTRACE__}}}
    catch
      kind, reason ->
        safe_delete(backend_mod, id, backend_opts)
        {:error, {:task_exit, {kind, reason}}}
    end
  end

  defp rollback_uploaded(uploaded, backend_mod, backend_opts) do
    Enum.each(uploaded, fn {_path, %{id: id}} ->
      safe_delete(backend_mod, id, backend_opts)
    end)
  end

  defp safe_delete(backend_mod, id, backend_opts) do
    try do
      backend_mod.delete(id, backend_opts)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
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

  defp prepare_pending(map, source) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      try do
        Map.put(acc, key, prepare_item(value, source))
      rescue
        exception ->
          cleanup_resolved(acc)
          reraise exception, __STACKTRACE__
      end
    end)
  end

  defp prepare_item({:cmd, cmd, args}, source),
    do: prepare_item({:cmd, cmd, args, []}, source)

  defp prepare_item({:cmd, cmd, args, opts}, source),
    do: Cmd.run!(cmd, args, SourceFile.local_path!(source), opts)

  defp prepare_item({:cmd_stdout, cmd, args}, source),
    do: prepare_item({:cmd_stdout, cmd, args, []}, source)

  defp prepare_item({:cmd_stdout, cmd, args, opts}, source),
    do: Cmd.run_stdout!(cmd, args, SourceFile.local_path!(source), opts)

  defp prepare_item(%TempFile{} = tf, _source), do: tf
  defp prepare_item(%MemoryFile{} = mf, _source), do: mf

  defp prepare_item(content, _source) when is_binary(content) do
    path = Path.join(System.tmp_dir!(), "em_attach_#{Util.random_id(8)}")

    try do
      File.write!(path, content)
      TempFile.managed(path, "derivative")
    rescue
      exception ->
        File.rm(path)
        reraise exception, __STACKTRACE__
    end
  end

  defp prepare_item(map, source) when is_map(map), do: prepare_pending(map, source)

  defp cleanup_source(%TempFile{path: path}), do: File.rm(path)
  defp cleanup_source(%MemoryFile{} = mf), do: MemoryFile.cleanup(mf)

  defp cleanup_resolved(%TempFile{} = source), do: cleanup_source(source)
  defp cleanup_resolved(%MemoryFile{} = source), do: cleanup_source(source)

  defp cleanup_resolved(map) when is_map(map) do
    Enum.each(map, fn {_key, value} -> cleanup_resolved(value) end)
  end

  defp cleanup_resolved(_other), do: :ok

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
