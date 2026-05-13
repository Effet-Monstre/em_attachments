defmodule Mix.Tasks.EmAttachments.Install do
  use Mix.Task

  @shortdoc "Installs em_attachments: generates migration and injects Sweeper into supervision tree"

  @moduledoc """
  Installs em_attachments into the host application.

      mix em_attachments.install

  This task performs two steps:

  1. Runs `mix em_attachments.gen.migration` (all flags are forwarded).
  2. Injects `{EmAttachments.Sweeper, repo: MyApp.Repo}` as the first child
     in the host application's supervision tree (`lib/<app>/application.ex`).

  If automatic injection fails, a warning with copy-paste instructions is shown.

  ## Options

    * `-r`, `--repo` — forwarded to `mix em_attachments.gen.migration`.

  """

  @switches [repo: :string, schema: :string, table: :string]
  @aliases [r: :repo]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("em_attachments.gen.migration", args)

    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)
    repo = detect_repo(opts)
    inject_sweeper(repo)
  end

  # ---------------------------------------------------------------------------
  # Repo detection
  # ---------------------------------------------------------------------------

  defp detect_repo(opts) do
    cond do
      repo = opts[:repo] -> Module.concat([repo])
      repo = auto_detect_repo() -> repo
      true -> nil
    end
  end

  defp auto_detect_repo do
    app = Mix.Project.config()[:app]

    if app do
      case Application.get_env(app, :ecto_repos, []) do
        [repo | _] -> repo
        [] -> nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Sweeper injection
  # ---------------------------------------------------------------------------

  defp inject_sweeper(repo) do
    repo_str = if repo, do: inspect(repo), else: "MyApp.Repo"
    sweeper_entry = "{EmAttachments.Sweeper, repo: #{repo_str}}"

    case find_application_file() do
      {:ok, path} ->
        content = File.read!(path)

        cond do
          String.contains?(content, "EmAttachments.Sweeper") ->
            Mix.shell().info([
              :green,
              "* skipping ",
              :reset,
              "#{path} (EmAttachments.Sweeper already present)"
            ])

          true ->
            case do_inject(content, sweeper_entry) do
              {:ok, new_content} ->
                File.write!(path, new_content)
                Mix.shell().info([:green, "* updated ", :reset, path])

              {:error, _} ->
                warn_manual(path, sweeper_entry)
            end
        end

      {:error, _} ->
        warn_manual(nil, sweeper_entry)
    end
  end

  defp find_application_file do
    app = Mix.Project.config()[:app]
    primary = app && Path.join(["lib", Atom.to_string(app), "application.ex"])

    cond do
      primary && File.exists?(primary) ->
        {:ok, primary}

      true ->
        case Path.wildcard("lib/**/*.ex") |> Enum.find(&use_application?/1) do
          nil -> {:error, :not_found}
          path -> {:ok, path}
        end
    end
  end

  defp use_application?(path) do
    case File.read(path) do
      {:ok, content} -> String.contains?(content, "use Application")
      _ -> false
    end
  end

  defp do_inject(content, sweeper_entry) do
    case Regex.split(~r/(\bchildren\s*=\s*\[\s*\n)/, content,
           include_captures: true,
           parts: 2
         ) do
      [before, opener, rest] ->
        indent =
          case Regex.run(~r/^( +)children/m, before <> opener, capture: :all_but_first) do
            [i] -> i <> "  "
            _ -> "      "
          end

        {:ok, before <> opener <> "#{indent}#{sweeper_entry},\n" <> rest}

      _ ->
        {:error, :no_children_list}
    end
  end

  defp warn_manual(path, sweeper_entry) do
    loc = path || "lib/<your_app>/application.ex"

    Mix.shell().info([
      :yellow,
      "* warning: ",
      :reset,
      "Could not automatically inject EmAttachments.Sweeper into #{loc}.\n" <>
        "  Add the following to your children list:\n\n" <>
        "      #{sweeper_entry}\n\n" <>
        "  Example:\n\n" <>
        "      children = [\n" <>
        "        #{sweeper_entry},\n" <>
        "        ...\n" <>
        "      ]\n"
    ])
  end
end
