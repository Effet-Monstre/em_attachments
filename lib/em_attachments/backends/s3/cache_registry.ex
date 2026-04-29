defmodule EmAttachments.Backends.S3.CacheRegistry do
  @moduledoc """
  GenServer that manages deletion timers for S3 cache-policy uploads and runs periodic
  cleanup scans to recover files whose timers were lost across application restarts.

  Add to your supervision tree:

      children = [
        EmAttachments.Backends.S3.CacheRegistry
      ]

  When started with no options, the registry discovers S3 cache backends automatically
  from `config :em_attachments, :config` (any backend with `policy: :cache`).

  You can also pass an explicit list:

      {EmAttachments.Backends.S3.CacheRegistry,
       backends: [[bucket: "my-bucket", prefix: "uploads", ..., cache_ttl: 1800]],
       cleanup_interval: :timer.hours(24)}

  Options:
    - `:backends` — list of backend opts keyword lists to scan at startup and periodically.
      When omitted, auto-discovers from `EmAttachments.Config`.
    - `:cleanup_interval` — milliseconds between periodic scans. Defaults to 24 hours.
  """

  use GenServer

  alias EmAttachments.Backends.S3
  alias EmAttachments.Config

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a cache file for timed deletion after `ttl_seconds`.
  No-op if the registry is not running.
  """
  def register(bucket, id, backend_opts, ttl_seconds) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:register, bucket, id, backend_opts, ttl_seconds})
    end

    :ok
  end

  @doc """
  Cancels the deletion timer for a cache file.
  Returns `:cancelled` if a timer was found and cancelled, `:not_found` otherwise.
  """
  def cancel(bucket, id) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:cancel, bucket, id})
    else
      :not_found
    end
  end

  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    backends =
      case Keyword.fetch(opts, :backends) do
        {:ok, list} -> list
        :error -> discover_backends()
      end

    cleanup_interval = opts[:cleanup_interval] || :timer.hours(24)

    if backends != [] do
      # Async startup scan so we don't block supervision tree startup
      Process.send_after(self(), {:cleanup_scan, backends}, 0)
    end

    {:ok, %{timers: %{}, backends: backends, cleanup_interval: cleanup_interval}}
  end

  @impl true
  def handle_cast({:register, bucket, id, backend_opts, ttl_seconds}, state) do
    timer_ref = Process.send_after(self(), {:expire, bucket, id}, ttl_seconds * 1000)
    timers = Map.put(state.timers, {bucket, id}, {timer_ref, backend_opts})
    {:noreply, %{state | timers: timers}}
  end

  @impl true
  def handle_call({:cancel, bucket, id}, _from, state) do
    case Map.pop(state.timers, {bucket, id}) do
      {nil, _} ->
        {:reply, :not_found, state}

      {{timer_ref, _opts}, timers} ->
        Process.cancel_timer(timer_ref)
        {:reply, :cancelled, %{state | timers: timers}}
    end
  end

  @impl true
  def handle_info({:expire, bucket, id}, state) do
    case Map.pop(state.timers, {bucket, id}) do
      {nil, _} ->
        # Timer was cancelled but message already in the mailbox — ignore
        {:noreply, state}

      {{_ref, backend_opts}, timers} ->
        Task.start(fn -> S3.expire_cache_file(id, backend_opts) end)
        {:noreply, %{state | timers: timers}}
    end
  end

  def handle_info({:cleanup_scan, backends}, state) do
    Task.start(fn -> run_cleanup_scan(backends) end)
    Process.send_after(self(), {:cleanup_scan, state.backends}, state.cleanup_interval)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------

  defp discover_backends do
    [&Config.cache/0, &Config.store/0]
    |> Enum.flat_map(fn resolver ->
      with {S3, opts} <- safe_call(resolver),
           :cache <- opts[:policy] do
        [opts]
      else
        _ -> []
      end
    end)
    |> Enum.uniq_by(&{&1[:bucket], &1[:prefix]})
  end

  defp safe_call(f) do
    f.()
  rescue
    _ -> nil
  end

  defp run_cleanup_scan(backends) do
    for backend_opts <- backends do
      prefix = backend_opts[:prefix] || "uploads"
      cache_prefix = "#{prefix}/cache/"
      cache_ttl = backend_opts[:cache_ttl] || 1800

      case S3.list_cache_objects(backend_opts, cache_prefix) do
        {:ok, objects} ->
          cutoff = DateTime.add(DateTime.utc_now(), -cache_ttl, :second)

          for {key, last_modified} <- objects,
              DateTime.before?(last_modified, cutoff) do
            id = String.replace_prefix(key, cache_prefix, "")
            S3.expire_cache_file(id, backend_opts)
          end

        {:error, _} ->
          :ok
      end
    end
  end
end
