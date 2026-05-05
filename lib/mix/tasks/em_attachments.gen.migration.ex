defmodule Mix.Tasks.EmAttachments.Gen.Migration do
  use Mix.Task

  @shortdoc "Generates migration for the em_attachments upload tracking table"

  @moduledoc """
  Generates an Ecto migration for the `em_attachments_uploads` tracking table.

      mix em_attachments.gen.migration

  The migration is written to `priv/repo/migrations/` with a timestamp prefix.
  Run `mix ecto.migrate` afterwards.

  ## Options

    * `-r`, `--repo` - the repo to generate the migration for. Defaults to the
      first repo listed in `config :your_app, ecto_repos: [...]`.

  ## Custom table name

  If you have configured a custom table name:

      config :em_attachments, :config, table_name: :my_uploads

  The generated migration will call `create_em_attachments_uploads_table(:my_uploads)`.
  """

  @switches [repo: :string]
  @aliases [r: :repo]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    repo = repo_module(opts)
    migrations_path = migrations_path(repo)
    File.mkdir_p!(migrations_path)

    Mix.Task.run("loadconfig")

    table_name = EmAttachments.Config.table_name()
    default_table = "em_attachments_uploads"

    table_arg =
      if table_name == default_table,
        do: "",
        else: "(#{inspect(String.to_atom(table_name))})"

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_create_em_attachments_uploads.exs"
    path = Path.join(migrations_path, filename)

    mod = Module.concat([repo, Migrations, "CreateEmAttachmentsUploads"])

    File.write!(path, migration_content(mod, table_arg))
    Mix.shell().info([:green, "* creating ", :reset, path])
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
      Mix.Task.run("loadconfig")

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

  defp migration_content(mod, table_arg) do
    """
    defmodule #{inspect(mod)} do
      use Ecto.Migration
      import EmAttachments.Migration

      def change do
        create_em_attachments_uploads_table#{table_arg}
      end
    end
    """
  end
end
