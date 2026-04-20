defmodule EmAttachments.Uploader.Pipeline do
  @moduledoc false

  alias EmAttachments.{Config, Signer, TempFile}

  # ---------------------------------------------------------------------------
  # Public API (called from uploader macro-generated functions)
  # ---------------------------------------------------------------------------

  def upload(uploader, input) do
    with {:ok, temp_file} <- to_temp_file(input),
         ordered <- resolve_order!(uploader.__uploader_plugins__()),
         {:ok, plugin_results} <- run_cast(temp_file, uploader, ordered),
         :ok <- run_validations(temp_file, uploader.__validations__(), ordered, plugin_results),
         :ok <- run_custom_validate(temp_file, plugin_results, uploader) do
      {cache_mod, cache_opts} = Config.cache(uploader.__uploader_opts__())
      id = random_id()

      file =
        struct(uploader, %{
          id: id,
          storage: :cache,
          metadata: %{size: temp_file.size, filename: temp_file.filename, plugins: plugin_results},
          uploader: to_string(uploader)
        })

      case cache_mod.put(id, temp_file.path, cache_opts) do
        :ok -> {:ok, file}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def promote(uploader, %{storage: :cache} = cached_file) do
    {cache_mod, cache_opts} = Config.cache(uploader.__uploader_opts__())
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    ordered = resolve_order!(uploader.__uploader_plugins__())
    tmp = tmp_path()

    result =
      with {:ok, content} <- cache_mod.get(cached_file.id, cache_opts),
           :ok <- File.write(tmp, content) do
        stored_file = %{cached_file | storage: :store}

        with :ok <- store_mod.put(cached_file.id, tmp, store_opts),
             {:ok, stored_file} <- run_after_upload(stored_file, ordered, {store_mod, store_opts}) do
          stored_file = dispatch_async(stored_file, ordered, {store_mod, store_opts}, uploader)
          cache_mod.delete(cached_file.id, cache_opts)
          {:ok, stored_file}
        end
      end

    File.rm(tmp)
    result
  end

  def promote(_uploader, %{storage: :store} = file), do: {:ok, file}

  def delete(uploader, file) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    ordered = resolve_order!(uploader.__uploader_plugins__())

    for {key, mod, plugin_opts} <- ordered,
        function_exported?(mod, :after_upload, 4) do
      mod.after_upload(%{file | metadata: %{file.metadata | plugins: Map.put(file.metadata.plugins, key, :delete)}}, key, {store_mod, store_opts}, plugin_opts)
    end

    store_mod.delete(file.id, store_opts)
    :ok
  end

  def resolve_url(uploader, file, call_opts) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    ordered = resolve_order!(uploader.__uploader_plugins__())

    plugin_url =
      Enum.reduce_while(ordered, :skip, fn {key, mod, plugin_opts}, _ ->
        if function_exported?(mod, :url, 5) do
          plugin_call_opts = call_opts[key]

          case mod.url(file, plugin_call_opts, key, plugin_opts, {store_mod, store_opts}) do
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
        # Fallback: original file URL from the backend.
        # Drop plugin keys from call_opts, pass the rest to the backend (e.g. expires_in).
        plugin_keys = Enum.map(ordered, &elem(&1, 0))
        backend_call_opts = Keyword.drop(call_opts, plugin_keys)
        merged_opts = Keyword.merge(store_opts, backend_call_opts)

        case store_mod.url(file.id, merged_opts) do
          {:ok, url} -> url
          _ -> nil
        end
    end
  end

  def presign_upload(uploader) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    id = random_id()
    store_mod.presign_upload(id, store_opts)
  end

  def serialize(uploader, %{storage: :cache} = file) do
    secret = Config.secret_key!()
    signed_id = Signer.sign(file.id, secret)
    file |> Map.from_struct() |> Map.put(:id, signed_id) |> Jason.encode!()
  end

  def serialize(_uploader, file) do
    file |> Map.from_struct() |> Jason.encode!()
  end

  def deserialize(uploader, json) do
    with {:ok, data} <- Jason.decode(json),
         data <- atomize_keys(data),
         :cache <- to_atom(data[:storage]) do
      secret = Config.secret_key!()

      case Signer.verify(data[:id], secret) do
        {:ok, real_id} ->
          {:ok, load_file(uploader, Map.put(data, :id, real_id))}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :store -> {:error, :cannot_deserialize_store_file}
      {:error, reason} -> {:error, reason}
    end
  end

  def load_file(uploader, data) when is_map(data) do
    data = atomize_keys(data)

    metadata =
      if m = data[:metadata] do
        m = atomize_keys(m)
        plugins = atomize_keys(m[:plugins] || %{}) |> deep_atomize_storage()
        %{size: m[:size], filename: m[:filename], plugins: plugins}
      end

    struct(uploader, %{
      id: data[:id],
      storage: to_atom(data[:storage]),
      metadata: metadata,
      uploader: data[:uploader]
    })
  end

  # ---------------------------------------------------------------------------
  # Compile-time helpers (called from __before_compile__)
  # ---------------------------------------------------------------------------

  @doc "Resolves plugin execution order via Kahn's topological sort. Raises CompileError on cycle."
  def resolve_order!(plugins) do
    case resolve_order(plugins) do
      {:ok, ordered} -> ordered
      {:error, :cycle} -> raise "EmAttachments: circular plugin dependency detected"
    end
  end

  @doc "Same as resolve_order!/1 but returns {:ok, list} | {:error, :cycle}."
  def resolve_order(plugins) do
    # plugins :: [{key, mod, opts}]
    keys = Enum.map(plugins, &elem(&1, 0))
    key_set = MapSet.new(keys)
    plugin_map = Map.new(plugins, fn {k, m, o} -> {k, {m, o}} end)

    # deps_map: key → [dep_keys declared in this plugin that exist in the uploader]
    deps_map =
      Map.new(plugins, fn {key, mod, _opts} ->
        dep_keys =
          mod.__plugin_deps__()
          |> Keyword.keys()
          |> Enum.filter(&MapSet.member?(key_set, &1))

        {key, dep_keys}
      end)

    in_degree = Map.new(keys, fn k -> {k, length(deps_map[k])} end)

    # reverse_deps: dep_key → [keys that depend on it]
    reverse_deps =
      Enum.reduce(plugins, Map.new(keys, fn k -> {k, []} end), fn {key, _m, _o}, acc ->
        Enum.reduce(deps_map[key], acc, fn dep_key, inner ->
          Map.update!(inner, dep_key, &[key | &1])
        end)
      end)

    queue = keys |> Enum.filter(&(in_degree[&1] == 0)) |> :queue.from_list()
    kahn(queue, in_degree, reverse_deps, plugin_map, [])
  end

  # ---------------------------------------------------------------------------
  # Normalize plugins list [{key, mod} | {key, {mod, opts}}] → [{key, mod, opts}]
  # ---------------------------------------------------------------------------

  def normalize_plugins(plugins) do
    Enum.map(plugins, fn
      {key, mod} when is_atom(mod) -> {key, mod, []}
      {key, {mod, opts}} when is_atom(mod) -> {key, mod, opts}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp to_temp_file(%TempFile{} = t), do: {:ok, t}

  defp to_temp_file(input) do
    cond do
      Code.ensure_loaded?(Plug.Upload) and match?(%Plug.Upload{}, input) ->
        {:ok, TempFile.from_plug(input)}

      is_map(input) and (Map.has_key?(input, :path) or Map.has_key?(input, "path")) ->
        {:ok, TempFile.from_map(input)}

      true ->
        {:error, :invalid_input}
    end
  end

  defp run_cast(temp_file, uploader, ordered_plugins) do
    Enum.reduce_while(ordered_plugins, {:ok, %{}}, fn {key, mod, opts}, {:ok, results} ->
      if function_exported?(mod, :cast, 4) do
        deps = build_deps(mod.__plugin_deps__(), results)

        case mod.cast(temp_file, uploader, deps, opts) do
          {:ok, fragment} -> {:cont, {:ok, Map.put(results, key, fragment)}}
          {:error, _} = err -> {:halt, err}
        end
      else
        {:cont, {:ok, results}}
      end
    end)
  end

  defp build_deps(declared_deps, plugin_results) do
    Map.new(declared_deps, fn {dep_key, _dep_mod} ->
      {dep_key, plugin_results[dep_key]}
    end)
  end

  defp run_validations(temp_file, validations, ordered_plugins, plugin_results) do
    errors =
      Enum.flat_map(validations, fn {plugin_key, validation_opts} ->
        with {mod, plugin_opts} <- find_plugin(ordered_plugins, plugin_key),
             true <- function_exported?(mod, :validate, 4) do
          own_result = plugin_results[plugin_key] || %{}

          case mod.validate(validation_opts, temp_file, own_result, plugin_opts) do
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

  defp run_custom_validate(temp_file, plugin_results, uploader) do
    if function_exported?(uploader, :validate, 2) do
      case uploader.validate(temp_file, plugin_results) do
        :ok -> :ok
        {:error, _} = err -> err
      end
    else
      :ok
    end
  end

  defp run_after_upload(file, ordered_plugins, backend) do
    Enum.reduce_while(ordered_plugins, {:ok, file}, fn {key, mod, plugin_opts}, {:ok, acc} ->
      if function_exported?(mod, :after_upload, 4) and not plugin_opts[:async] do
        case mod.after_upload(acc, key, backend, plugin_opts) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          {:error, _} = err -> {:halt, err}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp dispatch_async(file, ordered_plugins, backend, uploader) do
    case Config.async_dispatcher() do
      :inline ->
        Enum.reduce(ordered_plugins, file, fn {key, mod, plugin_opts}, acc ->
          if plugin_opts[:async] and function_exported?(mod, :after_upload_async, 4) do
            case mod.after_upload_async(acc, key, backend, plugin_opts) do
              {:ok, fragment} when is_map(fragment) ->
                new_plugins = Map.put(acc.metadata.plugins, key, fragment)
                %{acc | metadata: %{acc.metadata | plugins: new_plugins}}

              {:ok, updated_file} when is_struct(updated_file) ->
                updated_file

              _ ->
                acc
            end
          else
            acc
          end
        end)

      dispatcher ->
        for {key, mod, plugin_opts} <- ordered_plugins,
            plugin_opts[:async],
            function_exported?(mod, :after_upload_async, 4) do
          dispatcher.enqueue(%{
            uploader: uploader,
            file_id: file.id,
            plugin_key: key,
            plugin_mod: mod,
            plugin_opts: plugin_opts
          })
        end

        file
    end
  end

  defp find_plugin(ordered_plugins, key) do
    case List.keyfind(ordered_plugins, key, 0) do
      {_key, mod, opts} -> {mod, opts}
      nil -> nil
    end
  end

  defp kahn(queue, in_degree, reverse_deps, plugin_map, result) do
    case :queue.out(queue) do
      {:empty, _} ->
        processed = length(result)
        total = map_size(plugin_map)

        if processed == total do
          {:ok, Enum.reverse(result)}
        else
          {:error, :cycle}
        end

      {{:value, key}, rest} ->
        {mod, opts} = plugin_map[key]
        new_result = [{key, mod, opts} | result]

        {new_queue, new_in_degree} =
          Enum.reduce(reverse_deps[key], {rest, in_degree}, fn dep_key, {q, id} ->
            updated = Map.update!(id, dep_key, &(&1 - 1))

            if updated[dep_key] == 0 do
              {:queue.in(dep_key, q), updated}
            else
              {q, updated}
            end
          end)

        kahn(new_queue, new_in_degree, reverse_deps, plugin_map, new_result)
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp tmp_path do
    Path.join(System.tmp_dir!(), "em_attach_#{random_id()}")
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_atom(k), v} end)
  end

  defp atomize_keys(other), do: other

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_atom(k)

  # Recursively converts "storage" string values inside derivative maps to atoms.
  defp deep_atomize_storage(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, deep_atomize_storage(v)} end)
  end

  defp deep_atomize_storage(list) when is_list(list), do: list

  defp deep_atomize_storage(s) when is_binary(s) do
    case s do
      "cache" -> :cache
      "store" -> :store
      other -> other
    end
  end

  defp deep_atomize_storage(other), do: other
end
