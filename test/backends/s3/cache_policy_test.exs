defmodule EmAttachments.Backends.S3.CachePolicyTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Integration tests for S3.finalize/2 (PutObjectAcl).

  These tests require a real S3 bucket and are tagged :external.
  Run with: TEST_S3_BUCKET=my-bucket mix test --include external
  """

  @moduletag :external

  alias EmAttachments.Backends.S3
  alias EmAttachments.Test.Fixtures

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp s3_opts do
    bucket = System.get_env("TEST_S3_BUCKET") || raise "TEST_S3_BUCKET not set"

    [
      bucket: bucket,
      prefix: "em_test_acl",
      access_key_id: {:env, "AWS_ACCESS_KEY_ID"},
      secret_access_key: {:env, "AWS_SECRET_ACCESS_KEY"},
      region: {:env, "AWS_REGION", "us-east-1"},
      acl: :private
    ]
    |> Enum.map(fn {k, v} -> {k, EmAttachments.Config.resolve_value(v)} end)
  end

  defp unique, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  # ---------------------------------------------------------------------------
  # finalize/2 — PutObjectAcl
  # ---------------------------------------------------------------------------

  @tag :external
  test "finalize/2 returns :ok when changing an existing object's ACL to public-read" do
    opts = s3_opts()
    id = "finalize-test-#{unique()}"

    # Upload a private object
    content = File.read!(Fixtures.png_path())
    source = EmAttachments.TempFile.new(Fixtures.png_path(), "test.png")
    assert :ok = S3.put(id, source, opts)

    # Finalize: promote to public-read
    public_opts = Keyword.put(opts, :acl, :public_read)
    assert :ok = S3.finalize(id, public_opts)

    # Object should now be publicly accessible without signing
    public_url = "https://#{opts[:bucket]}.s3.#{opts[:region] || "us-east-1"}.amazonaws.com/em_test_acl/#{id}"

    case Req.get(public_url) do
      {:ok, %{status: 200, body: body}} ->
        assert body == content

      {:ok, %{status: status}} ->
        # Some bucket configurations may not allow public access at the bucket level;
        # at minimum the PutObjectAcl call must have returned :ok.
        assert status != 403, "Got 403 — bucket-level policy may block public access"

      {:error, reason} ->
        flunk("Unexpected error fetching public URL: #{inspect(reason)}")
    end

    # Cleanup
    S3.delete(id, opts)
  end

  @tag :external
  test "finalize/2 returns {:error, :not_found} for a non-existent object" do
    opts = s3_opts()
    id = "finalize-missing-#{unique()}"

    assert {:error, :not_found} = S3.finalize(id, opts)
  end

  @tag :external
  test "finalize/2 re-applies the same ACL without error (idempotent)" do
    opts = s3_opts()
    id = "finalize-idempotent-#{unique()}"

    source = EmAttachments.TempFile.new(Fixtures.png_path(), "test.png")
    assert :ok = S3.put(id, source, opts)

    # Apply same private ACL twice — must be idempotent
    assert :ok = S3.finalize(id, opts)
    assert :ok = S3.finalize(id, opts)

    S3.delete(id, opts)
  end
end
