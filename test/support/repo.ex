if Code.ensure_loaded?(Ecto.Repo) and Code.ensure_loaded?(Ecto.Adapters.Postgres) do
  defmodule EmAttachments.Test.Repo do
    use Ecto.Repo,
      otp_app: :em_attachments,
      adapter: Ecto.Adapters.Postgres
  end
end
