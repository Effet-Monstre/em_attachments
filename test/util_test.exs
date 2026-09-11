defmodule EmAttachments.UtilTest do
  use ExUnit.Case, async: true

  alias EmAttachments.Util

  @uuid_v7 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  describe "uuid_v7/0" do
    test "renders a canonical v7 uuid with the right version and variant nibbles" do
      assert Util.uuid_v7() =~ @uuid_v7
    end

    test "encodes the current time in the leading 48 bits" do
      before = System.system_time(:millisecond)
      <<hex::binary-8, "-", rest::binary-4, _::binary>> = Util.uuid_v7()
      after_ = System.system_time(:millisecond)

      {ts, ""} = Integer.parse(hex <> rest, 16)
      assert ts >= before and ts <= after_
    end

    test "sorts chronologically across milliseconds" do
      ids =
        Enum.map(1..5, fn _ ->
          Process.sleep(2)
          Util.uuid_v7()
        end)

      assert ids == Enum.sort(ids)
    end

    test "does not guarantee ordering within a single millisecond" do
      ids = Enum.map(1..200, fn _ -> Util.uuid_v7() end)

      assert Enum.map(ids, &String.slice(&1, 0, 13)) |> Enum.sort() ==
               Enum.map(ids, &String.slice(&1, 0, 13))
    end

    test "is unique across many calls" do
      ids = Enum.map(1..5_000, fn _ -> Util.uuid_v7() end)
      assert length(Enum.uniq(ids)) == 5_000
    end
  end
end
