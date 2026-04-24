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

      - `%Plug.Upload{}` — new file upload. After casting the change is a signed
        JSON string so `form[:logo].value` is directly usable as an HTML input
        value. On save the file is promoted from cache to store.
      - `nil` — explicit deletion. Sets the field to `nil` and schedules removal
        of the previously stored file inside the Ecto transaction.
      - A JSON string produced by a prior serialize call — used to re-submit a
        cached file when form validation fails. If the encoded file ID matches the
        current field value the cast is a no-op. Cache files are promoted on save.
      - A bare file ID string — if it matches the current field's ID the cast is a
        no-op; otherwise an error is added.
      - Key absent from params — always a no-op (unless `promote: true`, see below).

    ## Options

      - `promote: false` — skip promotion during save; the file is persisted in
        `:cache` state. Promote later by calling `cast_attachments/3` with
        `promote: true` (e.g. from a background job).
      - `promote: true` — if the existing field already holds a `:cache` file and
        no new upload param is present, register a `prepare_changes` callback to
        promote it. Use this to drive deferred promotion.
      - `reprocess: true` — if the existing field holds a `:store` file and no new
        upload param is present, re-run the full upload pipeline on the existing file
        and replace the field with the result.
      - Any plugin key (atom) with a keyword list — merged into that plugin's
        compile-time options for this call only.
    """

    import Ecto.Changeset

    @doc """
    Casts attachment fields in a changeset.

    Accepts `%Plug.Upload{}`, a JSON string (signed cache payload or bare file
    ID), a map, or `nil` (explicit delete). When a key is absent from params the
    field is left untouched.

    After a successful upload the changeset change is stored as a signed JSON
    string so that `form[:field].value` can be used directly as an HTML hidden
    input value without any extra serialization. The string is replaced by the
    final stored-file struct inside the `prepare_changes` callback that runs
    within the Ecto transaction.

    Pass `promote: false` to skip promotion and keep the file in `:cache` state.
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

        {:ok, %Plug.Upload{} = upload} ->
          handle_upload(changeset, key, upload, opts)

        {:ok, value} when is_binary(value) ->
          case Jason.decode(value) do
            {:ok, map} when is_map(map) -> handle_file_map(changeset, key, value, map, opts)
            {:error, _} -> handle_bare_id(changeset, key, value)
          end

        {:ok, value} when is_map(value) ->
          handle_file_map(changeset, key, Jason.encode!(value), value, opts)

        {:ok, _} ->
          add_error(changeset, key, "invalid attachment")
      end
    end

    defp handle_upload(changeset, key, upload, opts) do
      call_opts = build_call_opts(opts)
      changeset_ = cast(changeset, %{key => upload}, [key])

      if changeset_.valid? do
        cached_file = get_change(changeset_, key)
        prev_file = get_existing_file(changeset_.data, key)

        if opts[:promote] == false do
          changeset_
        else
          prepare_changes(changeset_, fn cs ->
            with {:ok, stored_file} <- uploader_for(cached_file).promote(cached_file, call_opts) do
              if prev_file, do: delete_file(prev_file)
              put_change(cs, key, stored_file)
            else
              {:error, reason} ->
                add_error(cs, key, "upload failed: #{inspect(reason)}")
            end
          end)
        end
      else
        changeset_
      end
    end

    defp handle_file_map(changeset, key, json, map, opts) do
      current_id = get_current_id(changeset.data, key)
      file_id = map["id"] || map[:id]
      storage = map["storage"] || map[:storage]

      cond do
        file_id == current_id ->
          changeset

        storage in ["cache", :cache] ->
          handle_cached_resubmit(changeset, key, json, map, opts)

        true ->
          add_error(changeset, key, "no file provided")
      end
    end

    defp handle_cached_resubmit(changeset, key, json, map, opts) do
      uploader_name = map["uploader"] || map[:uploader]
      uploader = String.to_existing_atom(uploader_name)

      case uploader.deserialize(json) do
        {:ok, cached_file} ->
          call_opts = build_call_opts(opts)
          prev_file = get_existing_file(changeset.data, key)

          if opts[:promote] == false do
            put_change(changeset, key, cached_file)
          else
            changeset_ = put_change(changeset, key, cached_file)

            prepare_changes(changeset_, fn cs ->
              with {:ok, stored_file} <- uploader.promote(cached_file, call_opts) do
                if prev_file, do: delete_file(prev_file)
                put_change(cs, key, stored_file)
              else
                {:error, reason} ->
                  add_error(cs, key, "promote failed: #{inspect(reason)}")
              end
            end)
          end

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

    defp handle_deferred_promote(changeset, key, opts) do
      existing = get_existing_file(changeset.data, key)

      case existing do
        %{storage: :cache} = cached_file ->
          call_opts = build_call_opts(opts)

          prepare_changes(changeset, fn cs ->
            with {:ok, stored_file} <- uploader_for(cached_file).promote(cached_file, call_opts) do
              put_change(cs, key, stored_file)
            else
              {:error, reason} ->
                add_error(cs, key, "promote failed: #{inspect(reason)}")
            end
          end)

        _ ->
          changeset
      end
    end

    defp build_call_opts(opts), do: Keyword.drop(opts, [:promote, :reprocess])

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
