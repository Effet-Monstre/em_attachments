defmodule EmAttachments.Backends.S3.FinalizeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Unit test for S3.finalize/2 ACL behavior. Unlike cache_policy_test.exs, this
  does not require a real bucket: with no `:acl` configured, finalize/2 must
  short-circuit to :ok without issuing any request.
  """

  alias EmAttachments.Backends.S3

  test "finalize/2 is a no-op (:ok) when no :acl is configured" do
    # No network call is made for the nil-acl path, so a dummy bucket is fine.
    opts = [bucket: "example-bucket", prefix: "uploads", region: "us-east-1"]

    assert :ok = S3.finalize("some-id", opts)
  end
end
