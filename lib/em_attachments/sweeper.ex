defmodule EmAttachments.Sweeper do
  @moduledoc """
  GenServer that periodically sweeps the upload tracking table.

  On each tick it performs two passes:

  1. **Cleanup** — deletes expired `:pending` rows: calls the uploader's `delete/1`
     to remove the asset from the backend, then removes the tracking row.
  2. **Finalization** — processes `:permanent` rows: calls `backend.finalize/2` (if
     exported) and each plugin's `after_confirm/2` (if exported), then removes the row.

  If a backend returns `{:error, :not_found}` for either `delete` or `finalize`, the
  row is still removed — no retries are made for assets that no longer exist.

  ## Supervision

      children = [
        {EmAttachments.Sweeper, repo: MyApp.Repo}
      ]

  If no `:repo` is configured (either via opts or `Config.repo/0`), the Sweeper
  does not start and logs a warning.
  """

  use GenServer
  require Logger

  alias EmAttachments.{Config, Upload}
  alias EmAttachments.Uploader.Topo

  @batch_size 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    repo = opts[:repo] || Config.repo()

    if is_nil(repo) do
      Logger.warning("EmAttachments.Sweeper: no :repo configured — sweeper will not run")
      :ignore
    else
      interval = opts[:interval] || Config.sweeper_interval()
      schedule(interval)
      {:ok, %{repo: repo, interval: interval}}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    sweep(state.repo)
    schedule(state.interval)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp sweep(repo) do
    cleanup_expired_pending(repo)
    finalize_permanent(repo)
  end

  defp cleanup_expired_pending(repo) do
    for row <- Upload.expired_pending(repo, @batch_size) do
      uploader = String.to_existing_atom(row.uploader)

      case uploader.deserialize(row.serialized) do
        {:ok, file} ->
          uploader.delete(file)

        {:error, reason} ->
          Logger.error(
            "EmAttachments.Sweeper: failed to deserialize pending row #{row.id}: #{inspect(reason)}"
          )
      end

      Upload.delete_row(repo, row.id)
    end
  end

  defp finalize_permanent(repo) do
    finalize_opts = Config.finalize_opts()

    for row <- Upload.all_permanent(repo, @batch_size) do
      uploader = String.to_existing_atom(row.uploader)

      case uploader.deserialize(row.serialized) do
        {:ok, file} ->
          {backend_mod, backend_opts} = Config.store(uploader.__uploader_opts__())

          if function_exported?(backend_mod, :finalize, 2) do
            case backend_mod.finalize(file.id, finalize_opts) do
              :ok ->
                :ok

              {:error, :not_found} ->
                Logger.warning(
                  "EmAttachments.Sweeper: asset #{row.asset_id} not found during finalize"
                )

              {:error, reason} ->
                Logger.error(
                  "EmAttachments.Sweeper: finalize failed for #{row.asset_id}: #{inspect(reason)}"
                )
            end
          end

          run_after_confirm(uploader, file, {backend_mod, backend_opts})

        {:error, reason} ->
          Logger.error(
            "EmAttachments.Sweeper: failed to deserialize permanent row #{row.id}: #{inspect(reason)}"
          )
      end

      Upload.delete_row(repo, row.id)
    end
  end

  defp run_after_confirm(uploader, file, backend) do
    ordered = Topo.resolve_order!(uploader.__uploader_plugins__())

    for {key, mod, plugin_opts} <- ordered,
        function_exported?(mod, :after_confirm, 2) do
      mod.after_confirm(file, %{plugin_key: key, plugin_opts: plugin_opts, backend: backend})
    end
  end

  defp schedule(interval) do
    Process.send_after(self(), :tick, interval)
  end
end
