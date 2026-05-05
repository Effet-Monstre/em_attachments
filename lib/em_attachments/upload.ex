if Code.ensure_loaded?(Ecto.Schema) do
  defmodule EmAttachments.Upload do
    @moduledoc false

    use Ecto.Schema
    import Ecto.Changeset
    import Ecto.Query

    @primary_key {:id, :id, autogenerate: true}

    @em_config Application.compile_env(:em_attachments, :config, [])
    schema Keyword.get(@em_config, :table_name, "em_attachments_uploads") do
      field :asset_id, :string
      field :uploader, :string
      field :serialized, :string
      field :status, :string, default: "pending"
      field :expires_at, :utc_datetime_usec
      timestamps(updated_at: false)
    end

    def insert_pending(repo, attrs) do
      %__MODULE__{}
      |> cast(attrs, [:asset_id, :uploader, :serialized, :status, :expires_at])
      |> validate_required([:asset_id, :uploader, :serialized, :expires_at])
      |> repo.insert()
    end

    def mark_permanent(nil, _asset_id), do: :ok

    def mark_permanent(repo, asset_id) do
      repo.update_all(
        from(u in __MODULE__, where: u.asset_id == ^asset_id),
        set: [status: "permanent"]
      )

      :ok
    end

    def expired_pending(repo, limit) do
      now = DateTime.utc_now()

      repo.all(
        from(u in __MODULE__,
          where: u.status == "pending" and u.expires_at < ^now,
          limit: ^limit
        )
      )
    end

    def all_permanent(repo, limit) do
      repo.all(
        from(u in __MODULE__,
          where: u.status == "permanent",
          limit: ^limit
        )
      )
    end

    def delete_row(repo, id) do
      repo.delete_all(from(u in __MODULE__, where: u.id == ^id))
      :ok
    end
  end
end
