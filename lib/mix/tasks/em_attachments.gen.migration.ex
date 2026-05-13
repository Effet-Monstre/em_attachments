defmodule Mix.Tasks.EmAttachments.Gen.Migration do
  use Mix.Task

  @shortdoc "Generates migration for the em_attachments upload tracking table"

  @moduledoc """
  Generates an Ecto migration for the `em_attachments` uploads tracking table.

      mix em_attachments.gen.migration

  The migration is written to `priv/repo/migrations/` with a timestamp prefix.
  Run `mix ecto.migrate` afterwards.

  ## Options

    * `-r`, `--repo` - the repo to generate the migration for. Defaults to the
      first repo listed in `config :your_app, ecto_repos: [...]`.

  ## Schema detection

  On PostgreSQL repos the migration defaults to creating a dedicated
  `em_attachments` schema with an `uploads` table inside it. On other adapters
  the flat table name `em_attachments_uploads` is used instead.

  Override by setting in your config:

      config :em_attachments, :config,
        schema_name: "my_schema",   # or false to disable
        table_name: "my_uploads"

  ## Custom schema / table

  You can also pass `--schema` and `--table` flags:

      mix em_attachments.gen.migration --schema my_schema --table my_uploads
  """

  @switches [repo: :string, schema: :string, table: :string]
  @aliases [r: :repo]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    Mix.Task.run("loadconfig")

    repo = repo_module(opts)
    migrations_path = migrations_path(repo)
    File.mkdir_p!(migrations_path)

    migration_opts = build_migration_opts(repo, opts)
    table_call = render_table_call(migration_opts)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_create_em_attachments_uploads.exs"
    path = Path.join(migrations_path, filename)

    mod = Module.concat([repo, Migrations, "CreateEmAttachmentsUploads"])

    File.write!(path, migration_content(mod, table_call))
    Mix.shell().info([:green, "* creating ", :reset, path])
  end

  defp build_migration_opts(repo, cli_opts) do
    config_schema = EmAttachments.Config.schema_name()
    config_table = Application.get_env(:em_attachments, :config, [])[:table_name]

    schema =
      cond do
        s = cli_opts[:schema] -> s
        config_schema == false -> nil
        config_schema != nil -> config_schema
        postgres?(repo) -> "em_attachments"
        true -> nil
      end

    table = cli_opts[:table] || config_table

    [schema: schema, table: table && String.to_atom(table)]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp render_table_call([]), do: "create_uploads_table()"

  defp render_table_call(opts) do
    inner =
      opts
      |> Enum.map(fn
        {:schema, v} -> "schema: #{inspect(v)}"
        {:table, v} -> "table: #{inspect(v)}"
      end)
      |> Enum.join(", ")

    "create_uploads_table(#{inner})"
  end

  defp postgres?(repo) do
    Code.ensure_loaded?(repo) and
      function_exported?(repo, :__adapter__, 0) and
      repo.__adapter__() == Ecto.Adapters.Postgres
  end

  defp repo_module(opts) do
    cond do
      repo = opts[:repo] ->
        Module.concat([repo])

      repo = detect_repo() ->
        repo

      true ->
        Mix.raise("""
        Could not determine the Ecto repo. Either:
          - Configure it: config :your_app, ecto_repos: [MyApp.Repo]
          - Or pass it explicitly: mix em_attachments.gen.migration --repo MyApp.Repo
        """)
    end
  end

  defp detect_repo do
    app = Mix.Project.config()[:app]

    if app do
      case Application.get_env(app, :ecto_repos, []) do
        [repo | _] -> repo
        [] -> nil
      end
    end
  end

  defp migrations_path(repo) do
    config = repo.config()
    priv = config[:priv] || "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}"
    Path.join(priv, "migrations")
  rescue
    _ -> "priv/repo/migrations"
  end

  defp migration_content(mod, table_call) do
    """
    defmodule #{inspect(mod)} do
      use Ecto.Migration
      import EmAttachments.Migration

      def change do
        #{table_call}
      end
    end
    """
  end
end
