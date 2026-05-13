defmodule EmAttachments.Test.Repo.Migrations.AddUniqueNameToUsers do
  use Ecto.Migration

  def change do
    create unique_index(:users, [:name])
  end
end
