defmodule EmAttachments.Test.Repo.Migrations.CreateEmAttachmentsUploads do
  use Ecto.Migration
  import EmAttachments.Migration

  def change do
    create_uploads_table()
  end
end
