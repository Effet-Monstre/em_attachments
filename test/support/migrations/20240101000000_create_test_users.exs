defmodule EmAttachments.Test.Repo.Migrations.CreateTestUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :name, :string
      add :avatar, :map
      timestamps(type: :utc_datetime_usec)
    end
  end
end
