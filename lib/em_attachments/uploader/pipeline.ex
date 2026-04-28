defmodule EmAttachments.Uploader.Pipeline do
  @moduledoc false

  alias EmAttachments.{BackendFile, Config, SourceFile, TempFile, Util}
  alias EmAttachments.Uploader.Topo

  # ---------------------------------------------------------------------------
  # Public API (called from uploader macro-generated functions)
  # ---------------------------------------------------------------------------

  # call_opts keys:
  #   :storage — :store to skip cache and write directly to store backend
  #   :promote — false | true (default true); controls whether promote/3 runs promotion
  #   any plugin key (atom) — keyword list merged into that plugin's compile-time opts
  def upload(uploader, input, call_opts \\ []) do
    if call_opts[:storage] == :store do
      upload_direct_to_store(uploader, input, call_opts)
    else
      upload_to_cache(uploader, input, call_opts)
    end
  end

  defp upload_to_cache(uploader, input, call_opts) do
    with {:ok, source} <- to_source_file(input),
         ordered <- Topo.resolve_order!(uploader.__uploader_plugins__()),
         {cache_mod, cache_opts} = Config.cache(uploader.__uploader_opts__()),
         {:ok, plugin_results} <-
           run_plugins(source, uploader, ordered, call_opts, {:cache, cache_mod, cache_opts}, %{}),
         :ok <-
           run_validations(source, uploader.__validations__(), ordered, plugin_results, call_opts),
         :ok <- run_custom_validate(source, plugin_results, uploader) do
      id = Util.random_id()

      file =
        struct(uploader, %{
          id: id,
          storage: :cache,
          metadata: %{
            size: SourceFile.size(source),
            filename: SourceFile.filename(source),
            plugins: plugin_results
          },
          uploader: to_string(uploader)
        })

      case cache_mod.put(id, source, cache_opts) do
        :ok -> {:ok, file}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp upload_direct_to_store(uploader, input, call_opts) do
    with {:ok, source} <- to_source_file(input),
         ordered <- Topo.resolve_order!(uploader.__uploader_plugins__()),
         {store_mod, store_opts} = Config.store(uploader.__uploader_opts__()),
         {:ok, plugin_results} <-
           run_plugins(source, uploader, ordered, call_opts, {:store, store_mod, store_opts}, %{}),
         :ok <-
           run_validations(source, uploader.__validations__(), ordered, plugin_results, call_opts),
         :ok <- run_custom_validate(source, plugin_results, uploader) do
      id = Util.random_id()

      file =
        struct(uploader, %{
          id: id,
          storage: :store,
          metadata: %{
            size: SourceFile.size(source),
            filename: SourceFile.filename(source),
            plugins: plugin_results
          },
          uploader: to_string(uploader)
        })

      case store_mod.put(id, source, store_opts) do
        :ok -> {:ok, file}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def promote(uploader, cached_file, call_opts \\ [])

  def promote(uploader, %{storage: :cache} = cached_file, call_opts) do
    if call_opts[:promote] == false do
      {:ok, cached_file}
    else
      {cache_mod, cache_opts} = Config.cache(uploader.__uploader_opts__())
      {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
      ordered = Topo.resolve_order!(uploader.__uploader_plugins__())

      source =
        BackendFile.new(
          cache_mod,
          cache_opts,
          cached_file.id,
          cached_file.metadata[:filename] || "",
          cached_file.metadata[:size]
        )

      result =
        with :ok <- store_mod.put(cached_file.id, source, store_opts) do
          stored_file = %{cached_file | storage: :store}
          # Store phase: start accumulation from existing metadata so plugins can read
          # their own cache-phase data via deps[plugin_key].
          initial_results = cached_file.metadata[:plugins] || %{}

          with {:ok, stored_file} <-
                 run_plugins(
                   source,
                   uploader,
                   ordered,
                   call_opts,
                   {:store, store_mod, store_opts},
                   initial_results,
                   stored_file
                 ) do
            cache_mod.delete(cached_file.id, cache_opts)
            {:ok, stored_file}
          end
        end

      BackendFile.cleanup(source)
      result
    end
  end

  def promote(_uploader, %{storage: :store} = file, _call_opts), do: {:ok, file}

  def delete(uploader, file) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    ordered = Topo.resolve_order!(uploader.__uploader_plugins__())

    for {key, mod, plugin_opts} <- ordered,
        function_exported?(mod, :destroy, 2) do
      mod.destroy(file, %{
        plugin_key: key,
        plugin_opts: plugin_opts,
        backend: {store_mod, store_opts}
      })
    end

    store_mod.delete(file.id, store_opts)
    :ok
  end

  def reprocess(uploader, %{storage: :store} = file) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    old_id = file.id

    source =
      BackendFile.new(
        store_mod,
        store_opts,
        old_id,
        file.metadata[:filename] || "",
        file.metadata[:size]
      )

    result =
      with {:ok, cached_file} <- upload(uploader, source),
           {:ok, new_stored_file} <- promote(uploader, cached_file) do
        store_mod.delete(old_id, store_opts)
        {:ok, new_stored_file}
      end

    BackendFile.cleanup(source)
    result
  end

  def resolve_url(_uploader, nil, _call_opts), do: nil

  def resolve_url(uploader, file, call_opts) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    ordered = Topo.resolve_order!(uploader.__uploader_plugins__())

    backend =
      if file.storage == :cache,
        do: Config.cache(uploader.__uploader_opts__()),
        else: {store_mod, store_opts}

    plugin_url =
      Enum.reduce_while(ordered, :skip, fn {key, mod, plugin_opts}, _ ->
        if function_exported?(mod, :url, 3) do
          plugin_call_opts = call_opts[key]

          case mod.url(file, plugin_call_opts, %{
                 plugin_key: key,
                 plugin_opts: plugin_opts,
                 backend: backend
               }) do
            {:ok, url} -> {:halt, {:ok, url}}
            :skip -> {:cont, :skip}
          end
        else
          {:cont, :skip}
        end
      end)

    case plugin_url do
      {:ok, url} ->
        url

      :skip ->
        plugin_keys = Enum.map(ordered, &elem(&1, 0))
        backend_call_opts = Keyword.drop(call_opts, plugin_keys)

        {backend_mod, backend_opts} = backend

        merged_opts = Keyword.merge(backend_opts, backend_call_opts)

        case backend_mod.url(file.id, merged_opts) do
          {:ok, url} -> url
          _ -> nil
        end
    end
  end

  def presign_upload(uploader) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    id = Util.random_id()
    store_mod.presign_upload(id, store_opts)
  end

  # def serialize(_uploader, %{storage: :cache} = file) do
  #   secret = Config.secret_key!()
  #   signed_id = Signer.sign(file.id, secret)
  #   file |> Map.from_struct() |> Map.put(:id, signed_id) |> Jason.encode!()
  # end

  def serialize(_uploader, file) do
    file |> Map.from_struct() |> Jason.encode!()
  end

  def deserialize(uploader, json) do
    with {:ok, data} <- Jason.decode(json),
         data <- Util.atomize_keys(data),
         :cache <- Util.to_atom(data[:storage]) do
      # secret = Config.secret_key!()

      {:ok, load_file(uploader, Map.put(data, :id, data[:id]))}

      # case Signer.verify(data[:id], secret) do
      #   {:ok, real_id} ->
      #     {:ok, load_file(uploader, Map.put(data, :id, real_id))}

      #   {:error, reason} ->
      #     {:error, reason}
      # end
    else
      :store -> {:error, :cannot_deserialize_store_file}
      {:error, reason} -> {:error, reason}
    end
  end

  def load_file(uploader, data) when is_map(data) do
    data = Util.atomize_keys(data)

    metadata =
      if m = data[:metadata] do
        m = Util.atomize_keys(m)
        plugins = (m[:plugins] || %{}) |> Util.deep_atomize_keys() |> Util.deep_atomize_storage()
        %{size: m[:size], filename: m[:filename], plugins: plugins}
      end

    struct(uploader, %{
      id: data[:id],
      storage: Util.to_atom(data[:storage]),
      metadata: metadata,
      uploader: data[:uploader]
    })
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run_plugins(source, uploader, ordered_plugins, call_opts, store_context, initial_results) do
    Enum.reduce_while(ordered_plugins, {:ok, initial_results}, fn {key, mod, compile_opts},
                                                                  {:ok, results} ->
      plugin_opts = merge_plugin_opts(compile_opts, call_opts, key)

      # During the store phase, pass the full accumulator as deps so plugins
      # can access their own cache-phase metadata via deps[plugin_key].
      # During the cache phase, only pass declared dependency results.
      deps =
        case store_context do
          {:cache, _, _} -> build_deps(mod.__plugin_deps__(), results)
          {:store, _, _} -> results
        end

      # init runs once per lifecycle — skipped if a prior-phase result already exists
      init_out =
        if function_exported?(mod, :init, 2) and not Map.has_key?(results, key) do
          mod.init(source, %{
            plugin_key: key,
            uploader: uploader,
            deps: deps,
            plugin_opts: plugin_opts
          })
        else
          :skip
        end

      case init_out do
        {:error, _} = err ->
          {:halt, err}

        _ ->
          # Pipe init result into deps under plugin's own key
          deps =
            case init_out do
              {:ok, fragment} -> Map.put(deps, key, fragment)
              :skip -> deps
            end

          upload_out =
            if function_exported?(mod, :upload, 3) do
              mod.upload(source, store_context, %{
                plugin_key: key,
                uploader: uploader,
                deps: deps,
                plugin_opts: plugin_opts
              })
            else
              :skip
            end

          case upload_out do
            {:error, _} = err ->
              {:halt, err}

            _ ->
              final =
                case {init_out, upload_out} do
                  {_, {:ok, f}} -> {:ok, f}
                  {{:ok, f}, :skip} -> {:ok, f}
                  {:skip, :skip} -> :skip
                end

              case final do
                {:ok, f} -> {:cont, {:ok, Map.put(results, key, f)}}
                :skip -> {:cont, {:ok, results}}
              end
          end
      end
    end)
  end

  # Store phase: takes the file struct and updates its plugins metadata.
  defp run_plugins(
         source,
         uploader,
         ordered_plugins,
         call_opts,
         store_context,
         initial_results,
         file
       ) do
    case run_plugins(source, uploader, ordered_plugins, call_opts, store_context, initial_results) do
      {:ok, new_plugins} -> {:ok, %{file | metadata: %{file.metadata | plugins: new_plugins}}}
      {:error, _} = err -> err
    end
  end

  defp merge_plugin_opts(compile_opts, call_opts, key) do
    runtime_opts = Keyword.get(call_opts, key, [])
    Keyword.merge(compile_opts, List.wrap(runtime_opts))
  end

  defp to_source_file(%TempFile{} = t), do: {:ok, t}
  defp to_source_file(%BackendFile{} = bf), do: {:ok, bf}
  defp to_source_file(%EmAttachments.MemoryFile{} = mf), do: {:ok, mf}

  defp to_source_file(input) when is_map(input) do
    if Map.has_key?(input, :path) or Map.has_key?(input, "path") do
      {:ok, TempFile.from_map(input)}
    else
      {:error, :invalid_input}
    end
  end

  defp to_source_file(_), do: {:error, :invalid_input}

  defp build_deps(declared_deps, plugin_results) do
    Map.new(declared_deps, fn {dep_key, _dep_mod} ->
      {dep_key, plugin_results[dep_key]}
    end)
  end

  defp run_validations(source, validations, ordered_plugins, plugin_results, call_opts) do
    errors =
      Enum.flat_map(validations, fn {plugin_key, validation_opts} ->
        with {mod, compile_opts} <- find_plugin(ordered_plugins, plugin_key),
             true <- function_exported?(mod, :validate, 3) do
          plugin_opts = merge_plugin_opts(compile_opts, call_opts, plugin_key)
          own_result = plugin_results[plugin_key] || %{}

          case mod.validate(source, own_result, %{
                 plugin_key: plugin_key,
                 plugin_opts: plugin_opts,
                 validation_opts: validation_opts
               }) do
            :ok -> []
            {:error, msg} when is_binary(msg) -> [msg]
            {:error, msgs} when is_list(msgs) -> msgs
          end
        else
          _ -> []
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp run_custom_validate(source, plugin_results, uploader) do
    if function_exported?(uploader, :validate, 2) do
      case uploader.validate(source, plugin_results) do
        :ok -> :ok
        {:error, _} = err -> err
      end
    else
      :ok
    end
  end

  defp find_plugin(ordered_plugins, key) do
    case List.keyfind(ordered_plugins, key, 0) do
      {_key, mod, opts} -> {mod, opts}
      nil -> nil
    end
  end
end
