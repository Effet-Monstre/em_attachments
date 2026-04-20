defmodule EmAttachments.Signer do
  @moduledoc false

  @doc """
  Signs a cache file ID with HMAC-SHA256.
  Returns "id.signature" suitable for browser submission.
  """
  def sign(id, secret) do
    sig =
      :crypto.mac(:hmac, :sha256, secret, "cache:#{id}")
      |> Base.url_encode64(padding: false)

    "#{id}.#{sig}"
  end

  @doc """
  Verifies a signed cache ID. Returns `{:ok, id}` or `{:error, :invalid_signature}`.
  """
  def verify(signed_id, secret) do
    case String.split(signed_id, ".", parts: 2) do
      [id, provided_sig] ->
        expected_sig =
          :crypto.mac(:hmac, :sha256, secret, "cache:#{id}")
          |> Base.url_encode64(padding: false)

        if secure_compare(provided_sig, expected_sig) do
          {:ok, id}
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :invalid_signature}
    end
  end

  # XOR-based constant-time comparison to prevent timing attacks.
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.exor(a, b) == String.duplicate(<<0>>, byte_size(a))
  end

  defp secure_compare(_, _), do: false
end
