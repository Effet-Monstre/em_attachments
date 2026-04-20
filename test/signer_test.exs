defmodule EmAttachments.SignerTest do
  use ExUnit.Case, async: true

  alias EmAttachments.Signer

  @secret "my-test-secret"

  test "sign produces a dotted id.signature string" do
    signed = Signer.sign("abc123", @secret)
    assert String.contains?(signed, ".")
    [id, _sig] = String.split(signed, ".", parts: 2)
    assert id == "abc123"
  end

  test "verify accepts a valid signed id" do
    signed = Signer.sign("abc123", @secret)
    assert {:ok, "abc123"} = Signer.verify(signed, @secret)
  end

  test "verify rejects tampered id" do
    signed = Signer.sign("abc123", @secret)
    [_id, sig] = String.split(signed, ".", parts: 2)
    tampered = "evil_id.#{sig}"
    assert {:error, :invalid_signature} = Signer.verify(tampered, @secret)
  end

  test "verify rejects tampered signature" do
    signed = Signer.sign("abc123", @secret)
    [id, _sig] = String.split(signed, ".", parts: 2)
    assert {:error, :invalid_signature} = Signer.verify("#{id}.invalidsig", @secret)
  end

  test "verify rejects wrong secret" do
    signed = Signer.sign("abc123", @secret)
    assert {:error, :invalid_signature} = Signer.verify(signed, "wrong-secret")
  end

  test "verify rejects string without a dot" do
    assert {:error, :invalid_signature} = Signer.verify("nodot", @secret)
  end

  test "sign is deterministic for the same input" do
    assert Signer.sign("x", @secret) == Signer.sign("x", @secret)
  end
end
