defmodule Mix.Tasks.EmAttachments.Gen.Migration do
  use Mix.Task

  @shortdoc "Generates migration for the em_attachments upload tracking table"

  @moduledoc """
  Generates an Ecto migration for the `em_attachments_uploads` tracking table.

      mix em_attachments.gen.migration

  The migration is written to `priv/repo/migrations/` with a timestamp prefix.
  Run `mix ecto.migrate` afterwards.
  """

  @impl Mix.Task
  def run(_args) do
    migrations_path = "priv/repo/migrations"
    File.mkdir_p!(migrations_path)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_create_em_attachments_uploads.exs"
    path = Path.join(migrations_path, filename)

    File.write!(path, migration_content())
    Mix.shell().info([:green, "* creating ", :reset, path])
  end

  defp migration_content do
    """
    defmodule YourApp.Repo.Migrations.CreateEmAttachmentsUploads do
      use Ecto.Migration

      def change do
        create table(:em_attachments_uploads) do
          add :asset_id,   :string,            null: false
          add :uploader,   :string,            null: false
          add :serialized, :text,              null: false
          add :status,     :string,            null: false, default: "pending"
          add :expires_at, :utc_datetime_usec, null: false
          timestamps(updated_at: false)
        end

        create index(:em_attachments_uploads, [:status, :expires_at])
        create unique_index(:em_attachments_uploads, [:asset_id])
      end
    end
    """
  end
end
