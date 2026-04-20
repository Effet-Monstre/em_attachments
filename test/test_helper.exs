ExUnit.start()

# Configure a test backend using the local filesystem.
tmp_dir = Path.join(System.tmp_dir!(), "em_attachments_test_#{:os.getpid()}")
File.mkdir_p!(tmp_dir)

Application.put_env(:em_attachments, :config,
  store: {EmAttachments.Backends.Local, fs_path: Path.join(tmp_dir, "store"), render_path: "/files/store"},
  cache: {EmAttachments.Backends.Local, fs_path: Path.join(tmp_dir, "cache"), render_path: "/files/cache"},
  secret_key: "test-secret-key-for-hmac-signing"
)

ExUnit.after_suite(fn _ -> File.rm_rf!(tmp_dir) end)
