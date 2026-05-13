defmodule EmAttachments.Migration do
  @moduledoc """
  Ecto migration helpers for em_attachments.

  Import this module inside an `Ecto.Migration` to get the
  `create_uploads_table/1` macro.

      defmodule MyApp.Repo.Migrations.CreateEmAttachmentsUploads do
        use Ecto.Migration
        import EmAttachments.Migration

        def change do
          create_uploads_table()
        end
      end

  Pass an atom to use a custom table name:

      create_uploads_table(:my_uploads)
  """

  defmacro create_uploads_table(table_name \\ :em_attachments_uploads) do
    quote do
      create table(unquote(table_name)) do
        add(:asset_id, :string, null: false)
        add(:uploader, :string, null: false)
        add(:serialized, :text, null: false)
        add(:status, :string, null: false, default: "pending")
        add(:expires_at, :utc_datetime_usec, null: false)
        timestamps(updated_at: false)
      end

      create(index(unquote(table_name), [:status, :expires_at]))
      create(unique_index(unquote(table_name), [:asset_id]))
    end
  end
end
