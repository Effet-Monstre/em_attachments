defmodule EmAttachments.Error do
  @moduledoc """
  A storage failure told briefly enough to show someone: `"S3 301 PermanentRedirect"`,
  `"timeout"`, `"not_found"`. Backends answer `{:error, reason}` with whatever their transport
  gave (an S3 status and its XML body, a `Req` exception, a POSIX atom); this reads them all.
  """

  @spec message(term()) :: String.t()
  def message({status, body}) when is_integer(status) do
    case is_binary(body) && Regex.run(~r/<Code>([^<]{1,100})<\/Code>/, body) do
      [_match, code] -> "S3 #{status} #{code}"
      _other -> "S3 #{status}"
    end
  end

  def message(%{__exception__: true} = exception), do: Exception.message(exception)
  def message(reason) when is_atom(reason), do: Atom.to_string(reason)
  def message(reason) when is_binary(reason), do: reason
  def message(reason), do: inspect(reason, limit: 5, printable_limit: 100)
end
