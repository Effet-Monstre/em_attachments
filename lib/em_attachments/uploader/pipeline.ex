defmodule EmAttachments.Uploader.Pipeline do
  @moduledoc false

  alias EmAttachments.{
    BackendFile,
    Config,
    MemoryFile,
    Signer,
    SourceFile,
    TempFile,
    Upload,
    Util
  }

  alias EmAttachments.Uploader.Topo

  # ---------------------------------------------------------------------------
  # Public API (called from uploader macro-generated functions)
  # ---------------------------------------------------------------------------

  def upload(uploader, input, call_opts \\ []) do
    with {:ok, source} <- to_source_file(input) do
      try do
        do_upload(uploader, source, call_opts)
      after
        cleanup_source(source)
      end
    end
  end

  defp do_upload(uploader, source, call_opts) do
    if too_large?(source, call_opts[:max_size]),
      do: {:error, :too_large},
      else: run_upload(uploader, source, call_opts)
  end

  defp too_large?(_source, nil), do: false

  defp too_large?(source, max_size) do
    size =
      SourceFile.size(source) ||
        case SourceFile.fetch_local_path(source) do
          {:ok, path} -> File.stat!(path).size
          {:error, _} -> 0
        end

    size > max_size
  end

  defp run_upload(uploader, source, call_opts) do
    ordered = Topo.resolve_order!(uploader.__uploader_plugins__())
    backend = Config.store(uploader.__uploader_opts__())
    results_key = {__MODULE__, make_ref()}
    Process.put(results_key, %{})

    try do
      case run_plugins(source, uploader, ordered, call_opts, backend, %{}, results_key) do
        {:ok, plugin_results} ->
          finish_upload(
            source,
            uploader,
            ordered,
            call_opts,
            backend,
            plugin_results
          )

        {:error, reason} ->
          rollback_plugin_assets(uploader, ordered, Process.get(results_key, %{}), backend)
          {:error, reason}
      end
    rescue
      exception ->
        rollback_plugin_assets(uploader, ordered, Process.get(results_key, %{}), backend)
        reraise exception, __STACKTRACE__
    after
      Process.delete(results_key)
    end
  end

  defp finish_upload(
         source,
         uploader,
         ordered,
         call_opts,
         {store_mod, store_opts} = backend,
         plugin_results
       ) do
    validation_result =
      with :ok <-
             run_validations(
               source,
               validations(uploader, call_opts),
               ordered,
               plugin_results,
               call_opts
             ),
           :ok <- run_custom_validate(source, plugin_results, uploader) do
        :ok
      end

    case validation_result do
      :ok ->
        {content_type, extension} = detect_mime(source, ordered, plugin_results)
        id = Util.uuid_v7() <> EmAttachments.Mime.extension_suffix(extension)
        put_opts = EmAttachments.Backend.put_opts(store_opts, source, content_type)

        file =
          struct(uploader, %{
            id: id,
            storage: :store,
            metadata: %{
              size: SourceFile.size(source),
              filename: Util.sanitize_filename(SourceFile.filename(source)),
              plugins: plugin_results
            },
            uploader: to_string(uploader)
          })

        put_result =
          try do
            store_mod.put(id, source, put_opts)
          rescue
            exception ->
              safe_delete(store_mod, id, store_opts)
              reraise exception, __STACKTRACE__
          catch
            kind, reason ->
              safe_delete(store_mod, id, store_opts)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        case put_result do
          :ok ->
            try do
              maybe_insert_pending(uploader, id, file)
              {:ok, file}
            rescue
              exception ->
                safe_delete(store_mod, id, store_opts)
                reraise exception, __STACKTRACE__
            end

          {:error, reason} ->
            safe_delete(store_mod, id, store_opts)
            rollback_plugin_assets(uploader, ordered, plugin_results, backend)
            {:error, reason}
        end

      {:error, _} = error ->
        rollback_plugin_assets(uploader, ordered, plugin_results, backend)
        error
    end
  end

  defp rollback_plugin_assets(uploader, ordered, plugin_results, {backend_mod, backend_opts}) do
    file =
      struct(uploader, %{
        storage: :store,
        metadata: %{plugins: plugin_results},
        uploader: to_string(uploader)
      })

    ordered
    |> Enum.flat_map(fn {key, mod, plugin_opts} ->
      if function_exported?(mod, :asset_ids, 2) do
        try do
          mod.asset_ids(file, %{plugin_key: key, plugin_opts: plugin_opts})
        rescue
          _ -> []
        catch
          _, _ -> []
        end
      else
        []
      end
    end)
    |> Enum.uniq()
    |> Enum.each(&safe_delete(backend_mod, &1, backend_opts))
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

  defp detect_mime(source, ordered, plugin_results) do
    case mime_plugin_result(ordered, plugin_results) do
      %{} = result -> {result[:type], result[:extension]}
      nil -> EmAttachments.Mime.type_and_extension(source)
    end
  end

  defp mime_plugin_result(ordered, plugin_results) do
    Enum.find_value(ordered, fn
      {key, EmAttachments.Plugins.Mime, _opts} -> plugin_results[key]
      _ -> nil
    end)
  end

  defp cleanup_source(%MemoryFile{} = source), do: MemoryFile.cleanup(source)
  defp cleanup_source(%BackendFile{} = source), do: BackendFile.cleanup(source)
  defp cleanup_source(%TempFile{} = source), do: TempFile.cleanup(source)

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
      with {:ok, new_file} <- upload(uploader, source) do
        store_mod.delete(old_id, store_opts)
        {:ok, new_file}
      end

    BackendFile.cleanup(source)
    result
  end

  def resolve_url(_uploader, nil, _call_opts), do: nil

  def resolve_url(uploader, file, call_opts) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    ordered = Topo.resolve_order!(uploader.__uploader_plugins__())
    plugin_keys = Enum.map(ordered, &elem(&1, 0))
    backend_opts = Keyword.merge(store_opts, Keyword.drop(call_opts, plugin_keys))

    plugin_url =
      Enum.reduce_while(ordered, :skip, fn {key, mod, plugin_opts}, _ ->
        if function_exported?(mod, :url, 3) do
          plugin_call_opts = call_opts[key]

          case mod.url(file, plugin_call_opts, %{
                 plugin_key: key,
                 plugin_opts: plugin_opts,
                 backend: {store_mod, backend_opts}
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
        url_opts = Keyword.put_new(backend_opts, :filename, file.metadata[:filename])

        case store_mod.url(file.id, url_opts) do
          {:ok, url} -> url
          _ -> nil
        end
    end
  end

  def presign_upload(uploader) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    store_mod.presign_upload(Util.uuid_v7(), store_opts)
  end

  # ---------------------------------------------------------------------------
  # Signed files and direct uploads
  # ---------------------------------------------------------------------------

  @file_salt "file"
  @slot_salt "upload"
  @url_salt "url"
  @url_period 7 * 24 * 3600

  @doc "A token for a stored file, accepted by `cast_attachments/3` until the upload expires."
  def sign(uploader, file) do
    Signer.sign(@file_salt, %{"f" => serialize(uploader, file)}, Config.expiry_seconds())
  end

  @doc "The file of a token from `sign/2`, signed for this uploader."
  def verify_file(uploader, token) do
    name = to_string(uploader)

    with {:ok, %{"f" => json}} when is_binary(json) <- Signer.verify(@file_salt, token),
         {:ok, %{"uploader" => ^name}} <- Jason.decode(json) do
      deserialize(uploader, json)
    else
      {:error, reason} when reason in [:invalid, :expired] -> {:error, reason}
      _other -> {:error, :invalid}
    end
  end

  @doc """
  A token naming a stored file in a URL (`EmAttachments.Plug.File`): its asset id and the name
  it downloads as (`:name`). Whoever holds it reaches the file while it's held by a record
  (tracked: `permanent`), so the application hands it only to who may see that record.

  It's valid for one to two `:max_age` (seconds, 7 days by default), and the same for a file,
  name and period: a page reloaded gets the same URL, which the browser keeps.
  """
  def url_token(uploader, file, opts \\ []) do
    period = opts[:max_age] || @url_period
    expires = (div(System.system_time(:second), period) + 2) * period
    data = %{"i" => file.id, "n" => opts[:name]}

    data =
      if Config.repo(), do: data, else: Map.put(data, "f", serialize(uploader, file))

    Signer.sign_until(@url_salt, data, expires)
  end

  @doc """
  The file a URL token names, and its name: `{:ok, file, name}`, or `{:error, :invalid |
  :expired | :not_found}` (a file released, by its record deleted or its file replaced).
  """
  def verify_url_token(uploader, token) do
    with {:ok, %{"i" => id} = data} when is_binary(id) <- Signer.verify(@url_salt, token),
         {:ok, file} <- url_file(uploader, id, data) do
      {:ok, file, data["n"]}
    else
      {:ok, _data} -> {:error, :invalid}
      {:error, _reason} = error -> error
    end
  end

  defp url_file(uploader, _id, %{"f" => json}) when is_binary(json),
    do: deserialize(uploader, json)

  defp url_file(uploader, id, _data) do
    case Upload.permanent(Config.repo!(), id, to_string(uploader)) do
      nil -> {:error, :not_found}
      json -> deserialize(uploader, json)
    end
  end

  @doc """
  A slot for a direct upload: where to POST the file (`url`, `fields`) and the token that
  completes it (`complete/3`). The slot is tracked as a pending asset, so the Sweeper removes
  an upload never completed.

  Options: `:max_size` (bytes), `:expires_in` (seconds, 3600), `:upload_url` (the Local
  backend's target, given by `EmAttachments.Plug.Upload`).
  """
  def presign(uploader, opts \\ []) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())
    id = Util.uuid_v7()
    expires_in = opts[:expires_in] || 3600
    max_size = opts[:max_size]

    token =
      Signer.sign(
        @slot_salt,
        %{"u" => to_string(uploader), "id" => id, "m" => max_size},
        expires_in + 3600
      )

    presign_opts =
      Keyword.merge(store_opts,
        url_expires_in: expires_in,
        max_size: max_size,
        upload_url: opts[:upload_url],
        slot_token: token
      )

    with {:ok, %{url: url, fields: fields}} <- store_mod.presign_upload(id, presign_opts) do
      track_slot(uploader, id, expires_in)
      {:ok, %{url: url, fields: fields, token: token}}
    end
  end

  @doc "The slot of a token from `presign/2`: `%{id: id, max_size: max_size}`."
  def verify_slot(uploader, token) do
    name = to_string(uploader)

    case Signer.verify(@slot_salt, token) do
      {:ok, %{"u" => ^name, "id" => id} = data} when is_binary(id) ->
        {:ok, %{id: id, max_size: data["m"]}}

      {:ok, _other} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Writes a file into a slot from `presign/2` through the application (the Local backend's
  target, `EmAttachments.Plug.Upload`).
  """
  def fill_slot(uploader, token, source) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())

    with {:ok, %{id: id, max_size: max_size}} <- verify_slot(uploader, token) do
      if too_large?(source, max_size),
        do: {:error, :too_large},
        else: store_mod.put(id, source, store_opts)
    end
  end

  @doc """
  Turns a filled slot into a stored file: the object is checked (size, and the uploader's
  validations from its first bytes), copied to its asset id, and the slot removed, accepted or
  not. Options: `:filename` (the client's, sanitized), `:validates`, plugin options.
  """
  def complete(uploader, token, opts \\ []) do
    {store_mod, store_opts} = Config.store(uploader.__uploader_opts__())

    with {:ok, %{id: slot_id, max_size: max_size}} <- verify_slot(uploader, token),
         true <- function_exported?(store_mod, :head, 2) || {:error, :not_supported},
         {:ok, %{size: size}} <- store_mod.head(slot_id, store_opts) do
      result =
        if is_integer(max_size) and size > max_size do
          {:error, :too_large}
        else
          filename = Util.sanitize_filename(opts[:filename])
          source = BackendFile.new(store_mod, store_opts, slot_id, filename, size)
          upload(uploader, source, Keyword.drop(opts, [:filename]))
        end

      safe_delete(store_mod, slot_id, store_opts)
      Upload.delete_asset(tracking_repo(), slot_id)
      result
    end
  end

  defp track_slot(uploader, id, expires_in) do
    if repo = tracking_repo() do
      Upload.insert_pending(repo, %{
        asset_id: id,
        uploader: to_string(uploader),
        serialized: Jason.encode!(%{id: id, storage: "store", uploader: to_string(uploader)}),
        status: "pending",
        expires_at: DateTime.add(DateTime.utc_now(), expires_in + 2 * 3600, :second)
      })
    end
  end

  defp tracking_repo do
    if Code.ensure_loaded?(Upload), do: Config.repo()
  end

  defp validations(uploader, call_opts) do
    Keyword.merge(uploader.__validations__(), call_opts[:validates] || [])
  end

  def serialize(_uploader, file) do
    file |> Map.from_struct() |> Jason.encode!()
  end

  def deserialize(uploader, json) do
    with {:ok, data} <- Jason.decode(json),
         data <- Util.atomize_keys(data) do
      {:ok, load_file(uploader, data)}
    end
  end

  @doc """
  Marks the main file and every plugin-stored asset (e.g. derivatives) as permanent.

  Calls `Upload.mark_permanent/2` for the root file ID, then iterates plugins that
  export `asset_ids/2` and marks each returned ID as well.
  """
  def mark_pending_for_deletion(repo, uploader, file) do
    now = DateTime.utc_now()

    EmAttachments.Upload.upsert_pending(repo, %{
      asset_id: file.id,
      uploader: to_string(uploader),
      serialized: serialize(uploader, file),
      status: "pending",
      expires_at: now
    })

    :ok
  end

  def mark_permanent(repo, uploader, file) do
    EmAttachments.Upload.mark_permanent(repo, file.id)

    ordered = Topo.resolve_order!(uploader.__uploader_plugins__())

    for {key, mod, plugin_opts} <- ordered,
        function_exported?(mod, :asset_ids, 2) do
      ids = mod.asset_ids(file, %{plugin_key: key, plugin_opts: plugin_opts})

      for id <- ids do
        EmAttachments.Upload.mark_permanent(repo, id)
      end
    end

    :ok
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

  defp maybe_insert_pending(uploader, id, file) do
    if Code.ensure_loaded?(EmAttachments.Upload) do
      case Config.repo() do
        nil ->
          :ok

        repo ->
          expires_at = DateTime.add(DateTime.utc_now(), Config.expiry(), :millisecond)

          EmAttachments.Upload.insert_pending(repo, %{
            asset_id: id,
            uploader: to_string(uploader),
            serialized: serialize(uploader, file),
            status: "pending",
            expires_at: expires_at
          })

          ordered = Topo.resolve_order!(uploader.__uploader_plugins__())

          for {key, mod, plugin_opts} <- ordered,
              function_exported?(mod, :asset_ids, 2) do
            plugin_ids = mod.asset_ids(file, %{plugin_key: key, plugin_opts: plugin_opts})

            for plugin_id <- plugin_ids do
              EmAttachments.Upload.insert_pending(repo, %{
                asset_id: plugin_id,
                uploader: to_string(uploader),
                serialized:
                  Jason.encode!(%{
                    id: plugin_id,
                    storage: "store",
                    uploader: to_string(uploader)
                  }),
                status: "pending",
                expires_at: expires_at
              })
            end
          end
      end
    end
  end

  defp run_plugins(
         source,
         uploader,
         ordered_plugins,
         call_opts,
         backend_context,
         initial_results,
         results_key
       ) do
    Enum.reduce_while(ordered_plugins, {:ok, initial_results}, fn {key, mod, compile_opts},
                                                                  {:ok, results} ->
      plugin_opts = merge_plugin_opts(compile_opts, call_opts, key)
      deps = build_deps(mod.__plugin_deps__(), results)

      init_out =
        if function_exported?(mod, :init, 2) and not Map.has_key?(results, key) do
          mod.init(source, %{
            plugin_key: key,
            uploader: uploader,
            deps: deps,
            plugins: results,
            plugin_opts: plugin_opts
          })
        else
          :skip
        end

      case init_out do
        {:error, _} = err ->
          {:halt, err}

        _ ->
          deps =
            case init_out do
              {:ok, fragment} -> Map.put(deps, key, fragment)
              :skip -> deps
            end

          upload_out =
            if function_exported?(mod, :upload, 3) do
              mod.upload(source, backend_context, %{
                plugin_key: key,
                uploader: uploader,
                deps: deps,
                plugins: results,
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
                {:ok, f} ->
                  updated = Map.put(results, key, f)
                  Process.put(results_key, updated)
                  {:cont, {:ok, updated}}

                :skip ->
                  {:cont, {:ok, results}}
              end
          end
      end
    end)
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
