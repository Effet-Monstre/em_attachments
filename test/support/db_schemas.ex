if Code.ensure_loaded?(Ecto.Schema) and Code.ensure_loaded?(Ecto.Adapters.Postgres) do
  defmodule EmAttachments.Test.DbUser do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "users" do
      field :name, :string
      field :avatar, EmAttachments.Test.BasicUploader
      timestamps(type: :utc_datetime_usec)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> cast(attrs, [:name])
      |> unique_constraint(:name)
    end
  end

  defmodule EmAttachments.Test.CmdStdoutDbUser do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "users" do
      field :name, :string
      field :avatar, EmAttachments.Test.CmdStdoutDerivativeUploader
      timestamps(type: :utc_datetime_usec)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      cast(user, attrs, [:name])
    end
  end
end
