ExUnit.start(exclude: [:external, :db])

tmp_dir = Path.join(System.tmp_dir!(), "em_attachments_test_#{:os.getpid()}")
File.mkdir_p!(tmp_dir)

# ── Backend config — S3 when TEST_S3_BUCKET is set, else Local ────────────
s3_bucket = System.get_env("TEST_S3_BUCKET")

store_backend =
  if s3_bucket do
    {EmAttachments.Backends.S3,
     bucket: s3_bucket,
     prefix: "em_test_store",
     access_key_id: {:env, "AWS_ACCESS_KEY_ID"},
     secret_access_key: {:env, "AWS_SECRET_ACCESS_KEY"},
     region: {:env, "AWS_REGION", "us-east-1"},
     acl: :private}
  else
    {EmAttachments.Backends.Local,
     fs_path: Path.join(tmp_dir, "store"), render_path: "/files/store"}
  end

Application.put_env(:em_attachments, :config,
  store: store_backend,
  secret_key: "test-secret-key-for-hmac-signing"
)

ExUnit.after_suite(fn _ ->
  if is_nil(s3_bucket), do: File.rm_rf!(tmp_dir)
end)

# ── DB / Sandbox setup ─────────────────────────────────────────────────────
db_available? =
  if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) and
       Code.ensure_loaded?(EmAttachments.Test.Repo) do
    Application.put_env(:em_attachments, EmAttachments.Test.Repo,
      url:
        System.get_env("DATABASE_URL") ||
          "postgres://dev:dev@localhost:5437/em_attachments_test",
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 10
    )

    try do
      {:ok, _} = EmAttachments.Test.Repo.start_link()
      migrations_path = Path.join(__DIR__, "support/migrations")
      Ecto.Migrator.run(EmAttachments.Test.Repo, migrations_path, :up, all: true, log: false)
      Ecto.Adapters.SQL.Sandbox.mode(EmAttachments.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("WARNING: Postgres unavailable — DB tests skipped. (#{Exception.message(e)})")
        false
    end
  else
    false
  end

excludes =
  [:external]
  |> then(fn e -> if db_available?, do: e, else: [:db | e] end)
  |> then(fn e -> if s3_bucket, do: [:local_backend | e], else: e end)

ExUnit.configure(exclude: excludes)
