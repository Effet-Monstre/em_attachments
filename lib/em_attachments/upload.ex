if Code.ensure_loaded?(Ecto.Schema) do
  defmodule EmAttachments.Upload do
    @moduledoc false

    use Ecto.Schema
    import Ecto.Changeset
    import Ecto.Query

    @primary_key {:id, :id, autogenerate: true}

    # Compile-time table name is the flat default. All queries override both the
    # source table and schema prefix at runtime via em_source/0 and em_prefix/0,
    # so this value is only used if someone inspects the struct metadata directly.
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
      |> Ecto.put_meta(source: em_source(), prefix: em_prefix())
      |> cast(attrs, [:asset_id, :uploader, :serialized, :status, :expires_at])
      |> validate_required([:asset_id, :uploader, :serialized, :expires_at])
      |> repo.insert()
    end

    def mark_permanent(nil, _asset_id), do: :ok

    def mark_permanent(repo, asset_id) do
      repo.update_all(
        from(u in {em_source(), __MODULE__}, where: u.asset_id == ^asset_id),
        [set: [status: "permanent"]],
        prefix: em_prefix()
      )

      :ok
    end

    def expired_pending(repo, limit) do
      now = DateTime.utc_now()

      repo.all(
        from(u in {em_source(), __MODULE__},
          where: u.status == "pending" and u.expires_at < ^now,
          limit: ^limit
        ),
        prefix: em_prefix()
      )
    end

    def all_permanent(repo, limit) do
      repo.all(
        from(u in {em_source(), __MODULE__},
          where: u.status == "permanent",
          limit: ^limit
        ),
        prefix: em_prefix()
      )
    end

    def delete_row(repo, id) do
      repo.delete_all(
        from(u in {em_source(), __MODULE__}, where: u.id == ^id),
        prefix: em_prefix()
      )

      :ok
    end

    defp em_source, do: EmAttachments.Config.table_name()
    defp em_prefix, do: EmAttachments.Config.schema_name()
  end
end
