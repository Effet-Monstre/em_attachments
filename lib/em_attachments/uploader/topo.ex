defmodule EmAttachments.Uploader.Topo do
  @moduledoc false

  def normalize_plugins(plugins) do
    Enum.map(plugins, fn
      {key, mod} when is_atom(mod) -> {key, mod, []}
      {key, {mod, opts}} when is_atom(mod) -> {key, mod, opts}
    end)
  end

  @doc "Resolves plugin execution order via Kahn's topological sort. Raises on cycle."
  def resolve_order!(plugins) do
    case resolve_order(plugins) do
      {:ok, ordered} -> ordered
      {:error, :cycle} -> raise "EmAttachments: circular plugin dependency detected"
    end
  end

  @doc "Same as resolve_order!/1 but returns {:ok, list} | {:error, :cycle}."
  def resolve_order(plugins) do
    keys = Enum.map(plugins, &elem(&1, 0))
    key_set = MapSet.new(keys)
    plugin_map = Map.new(plugins, fn {k, m, o} -> {k, {m, o}} end)

    deps_map =
      Map.new(plugins, fn {key, mod, _opts} ->
        dep_keys =
          mod.__plugin_deps__()
          |> Keyword.keys()
          |> Enum.filter(&MapSet.member?(key_set, &1))

        {key, dep_keys}
      end)

    in_degree = Map.new(keys, fn k -> {k, length(deps_map[k])} end)

    reverse_deps =
      Enum.reduce(plugins, Map.new(keys, fn k -> {k, []} end), fn {key, _m, _o}, acc ->
        Enum.reduce(deps_map[key], acc, fn dep_key, inner ->
          Map.update!(inner, dep_key, &[key | &1])
        end)
      end)

    queue = keys |> Enum.filter(&(in_degree[&1] == 0)) |> :queue.from_list()
    kahn(queue, in_degree, reverse_deps, plugin_map, [])
  end

  defp kahn(queue, in_degree, reverse_deps, plugin_map, result) do
    case :queue.out(queue) do
      {:empty, _} ->
        processed = length(result)
        total = map_size(plugin_map)

        if processed == total do
          {:ok, Enum.reverse(result)}
        else
          {:error, :cycle}
        end

      {{:value, key}, rest} ->
        {mod, opts} = plugin_map[key]
        new_result = [{key, mod, opts} | result]

        {new_queue, new_in_degree} =
          Enum.reduce(reverse_deps[key], {rest, in_degree}, fn dep_key, {q, id} ->
            updated = Map.update!(id, dep_key, &(&1 - 1))

            if updated[dep_key] == 0 do
              {:queue.in(dep_key, q), updated}
            else
              {q, updated}
            end
          end)

        kahn(new_queue, new_in_degree, reverse_deps, plugin_map, new_result)
    end
  end
end
