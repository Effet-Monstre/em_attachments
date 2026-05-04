if Code.ensure_loaded?(Ecto.Changeset) do
  defmodule EmAttachments.Ecto do
    @moduledoc """
    Ecto integration helpers. Import this in your schema modules.

        import EmAttachments.Ecto

        def changeset(record, attrs) do
          record
          |> cast(attrs, [:name])
          |> cast_attachments([:logo])
        end

    ## Param values accepted for each attachment field

      - `%Plug.Upload{}` — new file upload. The file is uploaded directly to the store
        backend as a pending asset. A `prepare_changes` callback marks it permanent
        atomically with the Ecto transaction. The serialized struct is available as
        `form[:logo].value` for use as an HTML hidden input on re-render.
      - `nil` — explicit deletion. Sets the field to `nil` and schedules removal
        of the previously stored file inside the Ecto transaction.
      - A JSON string produced by a prior serialize call — used to re-submit a
        pending file when form validation fails. The file is marked permanent on save.
      - A bare file ID string — if it matches the current field's ID the cast is a
        no-op; otherwise an error is added.
      - Key absent from params — always a no-op (unless `promote: true`, see below).

    ## Options

      - `promote: false` — skip marking the file permanent during save; the pending
        row stays in the tracking table for the Sweeper to pick up. Mark it permanent
        later by calling `cast_attachments/3` with `promote: true`.
      - `promote: true` — if the existing field holds a file and no new upload param
        is present, register a `prepare_changes` callback to mark it permanent.
        Use this to drive deferred confirmation.
      - `reprocess: true` — if the existing field holds a file and no new upload param
        is present, re-run the full upload pipeline on the existing file and replace
        the field with the result.
      - Any plugin key (atom) with a keyword list — merged into that plugin's
        compile-time options for this call only.
    """

    import Ecto.Changeset

    @doc """
    Casts attachment fields in a changeset.

    Accepts `%Plug.Upload{}`, a JSON string (pending file payload or bare file ID),
    a map, or `nil` (explicit delete). When a key is absent from params the field
    is left untouched.

    After a successful upload the changeset change is stored as the file struct.
    `to_string(file)` serializes it to JSON so that `form[:field].value` can be used
    directly as an HTML hidden input value without any extra work.

    Pass `promote: false` to skip marking the file permanent and keep it as pending.
    """
    def cast_attachments(%Ecto.Changeset{} = changeset, keys, opts \\ []) do
      Enum.reduce(keys, changeset, &cast_attachment(&2, &1, opts))
    end

    defp cast_attachment(changeset, key, opts) when is_binary(key),
      do: cast_attachment(changeset, String.to_existing_atom(key), opts)

    defp cast_attachment(changeset, key, opts) do
      promote_opt = Keyword.get(opts, :promote, :default)
      params = changeset.params || %{}

      fetched =
        with :error <- Map.fetch(params, to_string(key)) do
          Map.fetch(params, key)
        end

      case fetched do
        :error ->
          cond do
            promote_opt == true -> handle_deferred_promote(changeset, key, opts)
            opts[:reprocess] == true -> handle_reprocess(changeset, key)
            true -> changeset
          end

        {:ok, value} when value in [nil, ""] ->
          handle_delete(changeset, key)

        {:ok, value} when is_binary(value) ->
          case Jason.decode(value) do
            {:ok, map} when is_map(map) -> handle_file_map(changeset, key, value, map, opts)
            {:error, _} -> handle_bare_id(changeset, key, value)
          end

        {:ok, value} when is_map(value) and not is_struct(value) ->
          handle_file_map(changeset, key, Jason.encode!(value), value, opts)

        {:ok, value} ->
          handle_with_plugins(changeset, key, value, opts)
      end
    end

    defp handle_file_map(changeset, key, json, map, opts) do
      current_id = get_current_id(changeset.data, key)
      file_id = map["id"] || map[:id]
      storage = map["storage"] || map[:storage]

      cond do
        file_id == current_id ->
          changeset

        storage in ["store", :store] ->
          handle_pending_resubmit(changeset, key, json, map, opts)

        true ->
          add_error(changeset, key, "no file provided")
      end
    end

    defp handle_pending_resubmit(changeset, key, json, map, opts) do
      uploader_name = map["uploader"] || map[:uploader]
      uploader = String.to_existing_atom(uploader_name)

      case uploader.deserialize(json) do
        {:ok, file} ->
          prev_file = get_existing_file(changeset.data, key)
          schedule_mark_permanent(changeset, key, file, prev_file, opts)

        {:error, reason} ->
          add_error(changeset, key, "invalid attachment: #{inspect(reason)}")
      end
    end

    defp handle_bare_id(changeset, key, id) do
      if id == get_current_id(changeset.data, key) do
        changeset
      else
        add_error(changeset, key, "no file provided")
      end
    end

    defp handle_delete(changeset, key) do
      prev = Map.get(changeset.data, key)

      changeset
      |> put_change(key, nil)
      |> prepare_changes(fn cs ->
        if prev && prev.id, do: delete_file(prev)
        cs
      end)
    end

    defp handle_deferred_promote(changeset, key, _opts) do
      case get_existing_file(changeset.data, key) do
        %{id: _} = file ->
          changeset
          |> force_change(key, file)
          |> prepare_changes(fn cs ->
            EmAttachments.Upload.mark_permanent(cs.repo, file.id)
            cs
          end)

        _ ->
          changeset
      end
    end

    defp handle_source_upload(changeset, key, source, opts) do
      uploader = changeset.types[key]

      case uploader.upload(source) do
        {:ok, file} ->
          prev_file = get_existing_file(changeset.data, key)
          schedule_mark_permanent(changeset, key, file, prev_file, opts)

        {:error, reason} ->
          add_error(changeset, key, "upload failed: #{inspect(reason)}")
      end
    end

    defp handle_with_plugins(changeset, key, value, opts) do
      uploader = changeset.types[key]

      result =
        Enum.find_value(uploader.__cast_plugins__(), :no_cast, fn {plugin_key, plugin_mod, plugin_opts} ->
          if Code.ensure_loaded?(plugin_mod) and function_exported?(plugin_mod, :cast, 2) do
            ctx = %{uploader: uploader, plugin_key: plugin_key, plugin_opts: plugin_opts}

            case plugin_mod.cast(value, ctx) do
              {:ok, _} = ok -> ok
              {:error, _} = err -> err
              :skip -> nil
            end
          end
        end)

      case result do
        {:ok, source} -> handle_source_upload(changeset, key, source, opts)
        {:error, reason} -> add_error(changeset, key, reason)
        :no_cast -> add_error(changeset, key, "invalid attachment")
      end
    end

    defp schedule_mark_permanent(changeset, key, file, prev_file, opts) do
      if opts[:promote] == false do
        put_change(changeset, key, file)
      else
        changeset
        |> put_change(key, file)
        |> prepare_changes(fn cs ->
          EmAttachments.Upload.mark_permanent(cs.repo, file.id)
          if prev_file, do: delete_file(prev_file)
          cs
        end)
      end
    end

    defp handle_reprocess(changeset, key) do
      case get_existing_file(changeset.data, key) do
        %{storage: :store} = stored_file ->
          uploader = uploader_for(stored_file)

          prepare_changes(changeset, fn cs ->
            with {:ok, new_file} <- uploader.reprocess(stored_file) do
              put_change(cs, key, new_file)
            else
              {:error, reason} ->
                add_error(cs, key, "reprocess failed: #{inspect(reason)}")
            end
          end)

        _ ->
          changeset
      end
    end

    defp get_current_id(data, key) do
      case Map.get(data, key) do
        %{id: id} when not is_nil(id) -> id
        _ -> nil
      end
    end

    defp get_existing_file(data, key) do
      case Map.get(data, key) do
        %{id: id} = file when not is_nil(id) -> file
        _ -> nil
      end
    end

    defp uploader_for(%{uploader: uploader_str}) when is_binary(uploader_str) do
      String.to_existing_atom(uploader_str)
    end

    defp delete_file(file) do
      uploader = uploader_for(file)
      if Code.ensure_loaded?(uploader), do: uploader.delete(file)
    end
  end
end
