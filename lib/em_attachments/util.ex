defmodule EmAttachments.Util do
  @moduledoc false

  def random_id(bytes \\ 16) do
    :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
  end

  def uuid_v7 do
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)
    ts = System.system_time(:millisecond)
    hyphenate(<<ts::48, 7::4, rand_a::12, 2::2, rand_b::62>>)
  end

  defp hyphenate(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    [a, b, c, d, e]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  def atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_atom(k), v} end)
  end

  def atomize_keys(other), do: other

  def deep_atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_atom(k), deep_atomize_keys(v)} end)
  end

  def deep_atomize_keys(other), do: other

  def to_atom(k) when is_atom(k), do: k
  def to_atom(k) when is_binary(k), do: String.to_atom(k)

  def deep_atomize_storage(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, deep_atomize_storage(v)} end)
  end

  def deep_atomize_storage(list) when is_list(list), do: list

  def deep_atomize_storage(s) when is_binary(s) do
    case s do
      "cache" -> :cache
      "store" -> :store
      other -> other
    end
  end

  def deep_atomize_storage(other), do: other
end
