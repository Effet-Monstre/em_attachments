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
        backend as a pending asset. A `prepare_changes` callback claims it atomically with
        the Ecto transaction. Its signed token is `form[:logo].value`, for an HTML hidden
        input on re-render.
      - A signed token (`MyUploader.sign/1`, what `EmAttachments.Plug.Upload` answers): a
        file already stored, claimed on save. A file is claimed once: a second record given
        the same token, or a token whose upload expired or was released, gets an error.
      - The uploader's struct, from server code (never from params, which can't hold one):
        a file the application stored itself, claimed the same way.
      - `nil` — explicit deletion. Sets the field to `nil` and schedules removal
        of the previously stored file inside the Ecto transaction.
      - The current file's ID (bare, or in its serialized JSON) — a no-op. Any other
        unsigned value, a serialized file included, is refused: nothing a client sends is
        trusted unless it was signed.
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

    @doc """
    Releases files whose records are deleted outside a changeset (`Repo.delete/1` on a
    struct, `delete_all`): each is marked for deletion, removed by the Sweeper. `nil`s are
    skipped.
    """
    def release(repo, files) do
      for %{__struct__: uploader, id: id} = file <- List.wrap(files), is_binary(id) do
        uploader.mark_pending_for_deletion(repo, file)
      end

      :ok
    end

    defp cast_attachment(changeset, key, opts) when is_binary(key),
      do: cast_attachment(changeset, String.to_existing_atom(key), opts)

    defp cast_attachment(changeset, key, opts) do
      changeset = register_delete_cleanup(changeset, key)
      promote_opt = Keyword.get(opts, :promote, :default)
      params = changeset.params || %{}
      uploader = changeset.types[key]

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
          handle_token(changeset, key, uploader, value, opts)

        {:ok, %^uploader{} = file} ->
          handle_stored(changeset, key, file, opts)

        {:ok, value} when is_map(value) and not is_struct(value) ->
          handle_unsigned(changeset, key, value["id"] || value[:id])

        {:ok, value} ->
          handle_with_plugins(changeset, key, value, opts)
      end
    end

    defp handle_token(changeset, key, uploader, value, opts) do
      case uploader.verify(value) do
        {:ok, file} ->
          handle_stored(changeset, key, file, opts)

        {:error, :expired} ->
          add_error(changeset, key, "has expired")

        {:error, :invalid} ->
          id =
            case Jason.decode(value) do
              {:ok, %{"id" => id}} -> id
              _ -> value
            end

          handle_unsigned(changeset, key, id)
      end
    end

    defp handle_stored(changeset, key, file, opts) do
      if file.id == get_current_id(changeset.data, key) do
        changeset
      else
        prev_file = get_existing_file(changeset.data, key)
        schedule_mark_permanent(changeset, key, file, prev_file, opts)
      end
    end

    # An unsigned value only ever names the current file again.
    defp handle_unsigned(changeset, key, id) do
      if is_binary(id) and id == get_current_id(changeset.data, key),
        do: changeset,
        else: add_error(changeset, key, "is invalid")
    end

    defp register_delete_cleanup(changeset, key) do
      case get_existing_file(changeset.data, key) do
        %{id: _} = file ->
          prepare_changes(changeset, fn cs ->
            if cs.action == :delete do
              file.__struct__.mark_pending_for_deletion(cs.repo, file)
            end

            cs
          end)

        _ ->
          changeset
      end
    end

    defp handle_delete(changeset, key) do
      prev = Map.get(changeset.data, key)

      changeset
      |> put_change(key, nil)
      |> prepare_changes(fn cs ->
        if prev && prev.id, do: prev.__struct__.mark_pending_for_deletion(cs.repo, prev)
        cs
      end)
    end

    defp handle_deferred_promote(changeset, key, _opts) do
      case get_existing_file(changeset.data, key) do
        %{id: _} = file ->
          changeset
          |> force_change(key, file)
          |> prepare_changes(fn cs ->
            file.__struct__.mark_permanent(cs.repo, file)
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
        Enum.find_value(uploader.__cast_plugins__(), :no_cast, fn {plugin_key, plugin_mod,
                                                                   plugin_opts} ->
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
          case claim(cs.repo, file) do
            :ok ->
              file.__struct__.mark_permanent(cs.repo, file)
              if prev_file, do: prev_file.__struct__.mark_pending_for_deletion(cs.repo, prev_file)
              cs

            :error ->
              add_error(cs, key, "has already been used or has expired")
          end
        end)
      end
    end

    # Without tracking (no `:repo` configured) no row was written to claim.
    defp claim(repo, file) do
      if EmAttachments.Config.repo(),
        do: EmAttachments.Upload.claim(repo, file.id),
        else: :ok
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
  end
end
