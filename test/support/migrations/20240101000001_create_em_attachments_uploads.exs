defmodule EmAttachments.Test.Repo.Migrations.CreateEmAttachmentsUploads do
  use Ecto.Migration

  def change do
    execute("CREATE SCHEMA IF NOT EXISTS \"em_attachments\"")

    create table(:uploads, prefix: "em_attachments") do
      add(:asset_id, :string, null: false)
      add(:uploader, :string, null: false)
      add(:serialized, :text, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:expires_at, :utc_datetime_usec, null: false)
      timestamps(updated_at: false)
    end

    create(index(:uploads, [:status, :expires_at], prefix: "em_attachments"))
    create(unique_index(:uploads, [:asset_id], prefix: "em_attachments"))
  end
end
