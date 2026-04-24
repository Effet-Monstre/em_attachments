defmodule EmAttachments.Plugins.Derivatives do
  @moduledoc """
  Generates derivative files (thumbnails, variants, etc.).

  Define `handle/2` in your uploader to produce derivatives. The first argument
  is the plugin key as declared in the uploader (not necessarily `:derivatives`).
  The second is a map that always contains `:file` (a `EmAttachments.SourceFile.t()`)
  and optionally a `:store` key indicating the phase.

  Use `EmAttachments.SourceFile.local_path!/1` to get a filesystem path:

  ## Generic handler (same derivatives for both cache and store)

  Use the map pattern without a `:store` key. The plugin will copy the cached
  derivatives to store during promotion — no re-generation needed:

      def handle(:derivatives, %{file: file}) do
        path = EmAttachments.SourceFile.local_path!(file)
        {:ok, resized} = Operation.thumbnail(path, 80)
        {:ok, small_bin} = Image.write_to_buffer(resized, ".png")
        %{small: small_bin}
      end

  ## Phase-specific handlers (different derivatives per phase)

  Match on `store: :cache` and `store: :store` to generate different assets for
  each phase. During promotion the plugin calls the `:store` clause, then falls
  back to the generic clause if it returns `:skip`:

      def handle(:derivatives, %{file: file, store: :cache}) do
        path = EmAttachments.SourceFile.local_path!(file)
        %{thumb: thumb(path)}
      end

      def handle(:derivatives, %{file: file, store: :store}) do
        path = EmAttachments.SourceFile.local_path!(file)
        %{original: path, thumb: thumb(path)}
      end

  Map values may be:
    - A binary (file content) — written to a temp file automatically
    - A path string — used as-is

  Derivatives may be nested: `%{thumb: %{small: bin, large: bin}}`
  """

  use EmAttachments.Plugin

  alias EmAttachments.{BackendFile, TempFile, Util}

  @impl true
  # Cache phase: generate and upload to cache backend.
  # First tries handle(key, %{file: f}) — the "generic" form that implies the same
  # derivatives are valid for store (copy_to_store: true).
  # Falls back to handle(key, %{file: f, store: :cache}) — the cache-specific form,
  # meaning a separate store handler exists (copy_to_store: false).
  def upload(
        source,
        {:cache, backend_mod, backend_opts},
        ctx
      ) do
    if not function_exported?(ctx.uploader, :handle, 2) do
      :skip
    else
      case try_cache_handle(ctx.uploader, ctx.plugin_key, source) do
        {map, copy_to_store} when is_map(map) ->
          case upload_derivatives(map, backend_mod, backend_opts, :cache) do
            {:ok, uploaded} -> {:ok, %{variants: uploaded, copy_to_store: copy_to_store}}
            {:error, _} = err -> err
          end

        :skip ->
          :skip
      end
    end
  end

  # Store phase: promote or re-generate derivatives into the store backend.
  # `deps` during promote is the full plugin_results starting from file.metadata.plugins,
  # so deps[plugin_key] contains our own cache-phase metadata.
  def upload(
        source,
        {:store, backend_mod, backend_opts},
        ctx
      ) do
    own_cache = ctx.deps[ctx.plugin_key] || %{}

    cond do
      # Nothing was generated during cache phase — skip
      not is_map(own_cache) or not Map.has_key?(own_cache, :variants) ->
        :skip

      # Generic handler was used for cache — copy cached derivatives to store.
      # When source is a BackendFile (normal promotion), read the cache backend from it
      # and copy each variant via the backend's put (enabling S3 server-side copy).
      # Fall back to re-running the handler for non-BackendFile sources (e.g. reprocess).
      own_cache[:copy_to_store] ->
        case source do
          %BackendFile{} = bf ->
            state = BackendFile.state(bf)

            copy_variants_to_store(
              own_cache.variants,
              state.backend_mod,
              state.backend_opts,
              backend_mod,
              backend_opts
            )

          _ ->
            case ctx.uploader.handle(ctx.plugin_key, %{file: source}) do
              map when is_map(map) -> do_upload_to_store(map, backend_mod, backend_opts)
              :skip -> :skip
            end
        end

      # Cache-specific handler was used — try store-specific, then fall back to generic
      true ->
        case try_store_handle(ctx.uploader, ctx.plugin_key, source) do
          map when is_map(map) -> do_upload_to_store(map, backend_mod, backend_opts)
          :skip -> :skip
        end
    end
  end

  @impl true
  def destroy(file, ctx) do
    {backend_mod, backend_opts} = ctx.backend
    own_data = get_in(file.metadata, [:plugins, ctx.plugin_key]) || %{}

    collect_store_ids(own_data)
    |> Enum.each(fn id -> backend_mod.delete(id, backend_opts) end)

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

  defp try_cache_handle(uploader, plugin_key, source) do
    case uploader.handle(plugin_key, %{file: source}) do
      :skip ->
        case uploader.handle(plugin_key, %{file: source, store: :cache}) do
          map when is_map(map) -> {map, false}
          :skip -> :skip
        end

      map when is_map(map) ->
        {map, true}
    end
  end

  defp try_store_handle(uploader, plugin_key, source) do
    case uploader.handle(plugin_key, %{file: source, store: :store}) do
      :skip -> uploader.handle(plugin_key, %{file: source})
      result -> result
    end
  end

  defp do_upload_to_store(map, backend_mod, backend_opts) do
    case upload_derivatives(map, backend_mod, backend_opts, :store) do
      {:ok, uploaded} -> {:ok, %{variants: uploaded}}
      err -> err
    end
  end

  # Copies already-uploaded cache derivatives to the store backend in parallel.
  # Each cached variant gets its own BackendFile so the backend can decide to
  # do a server-side copy (e.g. S3 CopyObject) rather than downloading locally.
  defp copy_variants_to_store(variants, cache_mod, cache_opts, store_mod, store_opts) do
    flat = collect_cache_ids(variants)

    flat
    |> Task.async_stream(
      fn {key_path, cache_id} ->
        bf = BackendFile.new(cache_mod, cache_opts, cache_id, "", nil)
        new_id = Util.random_id(8)
        result = store_mod.put(new_id, bf, store_opts)
        BackendFile.cleanup(bf)
        {key_path, new_id, result}
      end,
      ordered: true
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {key_path, new_id, :ok}}, {:ok, acc} ->
        {:cont, {:ok, [{key_path, %{id: new_id, storage: :store}} | acc]}}

      {:ok, {_, _, {:error, _} = err}}, _ ->
        {:halt, err}

      {:exit, reason}, _ ->
        {:halt, {:error, {:task_exit, reason}}}
    end)
    |> case do
      {:ok, results} -> {:ok, %{variants: reconstruct_tree(Enum.reverse(results))}}
      err -> err
    end
  end

  # Flattens the variant tree to [{[key_path], cache_id}] for parallel copy.
  defp collect_cache_ids(variants, prefix \\ []) when is_map(variants) do
    Enum.flat_map(variants, fn {key, value} ->
      path = prefix ++ [key]

      case value do
        %{id: id, storage: :cache} -> [{path, id}]
        nested when is_map(nested) -> collect_cache_ids(nested, path)
        _ -> []
      end
    end)
  end

  # Uploads a map of handler outputs in parallel.
  # build_pending converts binaries to TempFiles; nested maps are recursed.
  # All leaf TempFiles are collected flat, uploaded concurrently, then the
  # original tree shape is reconstructed from the results.
  defp upload_derivatives(map, backend_mod, backend_opts, storage) when is_map(map) do
    pending = build_pending(map)
    flat = collect_items(pending)

    flat
    |> Task.async_stream(
      fn {key_path, %TempFile{} = source} ->
        id = Util.random_id(8)
        result = backend_mod.put(id, source, backend_opts)
        if result == :ok, do: File.rm(source.path)
        {key_path, id, result}
      end,
      ordered: true
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {key_path, id, :ok}}, {:ok, acc} ->
        {:cont, {:ok, [{key_path, %{id: id, storage: storage}} | acc]}}

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

  # Flattens a pending map (built from build_pending) to [{[key_path], TempFile}].
  defp collect_items(map, prefix \\ []) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      path = prefix ++ [key]

      case value do
        %TempFile{} = tf -> [{path, tf}]
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

  defp build_item(content) when is_binary(content) do
    path = Path.join(System.tmp_dir!(), "em_attach_#{Util.random_id(8)}")
    File.write!(path, content)
    TempFile.new(path, "derivative")
  end

  defp build_item(map) when is_map(map), do: build_pending(map)

  defp collect_store_ids(map) when is_map(map) do
    Enum.flat_map(map, fn {_k, v} ->
      case v do
        %{id: id, storage: :store} -> [id]
        nested when is_map(nested) -> collect_store_ids(nested)
        _ -> []
      end
    end)
  end

  defp collect_store_ids(_), do: []
end
