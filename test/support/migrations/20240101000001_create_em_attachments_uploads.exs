defmodule EmAttachments.Test.Repo.Migrations.CreateEmAttachmentsUploads do
  use Ecto.Migration

  def change do
    create table(:em_attachments_uploads) do
      add :asset_id, :string, null: false
      add :uploader, :string, null: false
      add :serialized, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(updated_at: false)
    end

    create index(:em_attachments_uploads, [:status, :expires_at])
    create unique_index(:em_attachments_uploads, [:asset_id])
  end
end
