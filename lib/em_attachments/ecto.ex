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
    """

    import Ecto.Changeset

    @doc """
    Casts attachment fields in a changeset.

    Accepts `%Plug.Upload{}`, a JSON string (from AJAX/hidden field), or `nil`.
    Deletion is triggered by a param value containing `_delete: "true"`.

    Promotion from cache to store is registered as a `prepare_changes/2` callback,
    meaning it runs inside the Ecto transaction and is rolled back automatically.
    """
    def cast_attachments(%Ecto.Changeset{} = changeset, keys) do
      Enum.reduce(keys, changeset, &cast_attachment(&2, &1))
    end

    defp cast_attachment(changeset, key) when is_binary(key),
      do: cast_attachment(changeset, String.to_existing_atom(key))

    defp cast_attachment(changeset, key) do
      value = changeset.params[to_string(key)] || changeset.params[key]

      cond do
        is_nil(value) ->
          changeset

        delete?(value) ->
          handle_delete(changeset, key)

        true ->
          handle_upload(changeset, key, value)
      end
    end

    defp delete?(value) when is_map(value) do
      value["_delete"] in [true, "true", "1", "on"] or
        value[:_delete] in [true, "true", "1", "on"]
    end

    defp delete?(_), do: false

    defp handle_delete(changeset, key) do
      prev = Map.get(changeset.data, key)

      changeset
      |> put_change(key, nil)
      |> prepare_changes(fn cs ->
        if prev && prev.id, do: delete_file(prev)
        cs
      end)
    end

    defp handle_upload(changeset, key, value) do
      changeset_ = cast(changeset, %{key => value}, [key])

      if changeset_.valid? do
        cached_file = get_change(changeset_, key)
        prev_file = get_existing_file(changeset_.data, key)

        prepare_changes(changeset_, fn cs ->
          with {:ok, stored_file} <- uploader_for(cached_file).promote(cached_file) do
            if prev_file, do: delete_file(prev_file)
            put_change(cs, key, stored_file)
          else
            {:error, reason} ->
              add_error(cs, key, "upload failed: #{inspect(reason)}")
          end
        end)
      else
        changeset_
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
