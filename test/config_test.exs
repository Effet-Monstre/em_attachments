defmodule EmAttachments.ConfigTest do
  use ExUnit.Case, async: false

  alias EmAttachments.{Backends.Local, Config}

  defp with_config(cfg, fun) do
    original = Application.get_env(:em_attachments, :config, [])

    try do
      Application.put_env(:em_attachments, :config, cfg)
      fun.()
    after
      Application.put_env(:em_attachments, :config, original)
    end
  end

  # ---------------------------------------------------------------------------
  # store/1
  # ---------------------------------------------------------------------------

  describe "store/1" do
    test "resolves explicit {mod, opts}" do
      with_config([store: {Local, fs_path: "/s", render_path: "/store"}, secret_key: "k"], fn ->
        assert {Local, opts} = Config.store()
        assert opts[:fs_path] == "/s"
      end)
    end

    test "raises when not configured" do
      with_config([secret_key: "k"], fn ->
        assert_raise RuntimeError, ~r/:store/, fn -> Config.store() end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # repo/0 and repo!/0
  # ---------------------------------------------------------------------------

  describe "repo/0" do
    test "returns nil when not configured" do
      with_config([store: {Local, fs_path: "/s", render_path: "/s"}, secret_key: "k"], fn ->
        assert Config.repo() == nil
      end)
    end

    test "returns the configured repo" do
      with_config([store: {Local, fs_path: "/s", render_path: "/s"}, repo: SomeRepo, secret_key: "k"], fn ->
        assert Config.repo() == SomeRepo
      end)
    end
  end

  describe "repo!/0" do
    test "raises when not configured" do
      with_config([store: {Local, fs_path: "/s", render_path: "/s"}, secret_key: "k"], fn ->
        assert_raise RuntimeError, ~r/:repo/, fn -> Config.repo!() end
      end)
    end

    test "returns the configured repo" do
      with_config([store: {Local, fs_path: "/s", render_path: "/s"}, repo: SomeRepo, secret_key: "k"], fn ->
        assert Config.repo!() == SomeRepo
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # expiry/0, finalize_opts/0, sweeper_interval/0
  # ---------------------------------------------------------------------------

  describe "expiry/0" do
    test "defaults to 24 hours in milliseconds" do
      with_config([store: {Local, fs_path: "/s", render_path: "/s"}, secret_key: "k"], fn ->
        assert Config.expiry() == :timer.hours(24)
      end)
    end

    test "returns configured value" do
      with_config([store: {Local, fs_path: "/s", render_path: "/s"}, expiry: 5000, secret_key: "k"], fn ->
        assert Config.expiry() == 5000
      end)
    end
  end

  describe "finalize_opts/0" do
    test "defaults to empty list" do
      with_config([store: {Local, fs_path: "/s", render_path: "/s"}, secret_key: "k"], fn ->
        assert Config.finalize_opts() == []
      end)
    end

    test "returns configured opts" do
      with_config(
        [store: {Local, fs_path: "/s", render_path: "/s"}, finalize_opts: [acl: "public-read"], secret_key: "k"],
        fn -> assert Config.finalize_opts() == [acl: "public-read"] end
      )
    end
  end

  describe "sweeper_interval/0" do
    test "defaults to 30 minutes in milliseconds" do
      with_config([store: {Local, fs_path: "/s", render_path: "/s"}, secret_key: "k"], fn ->
        assert Config.sweeper_interval() == :timer.minutes(30)
      end)
    end

    test "returns configured value" do
      with_config(
        [store: {Local, fs_path: "/s", render_path: "/s"}, sweeper_interval: 60_000, secret_key: "k"],
        fn -> assert Config.sweeper_interval() == 60_000 end
      )
    end
  end

  # ---------------------------------------------------------------------------
  # {:env, ...} resolution
  # ---------------------------------------------------------------------------

  describe "resolve_value/1" do
    test "resolves {:env, var} from system env" do
      System.put_env("EM_TEST_VAR", "resolved")
      with_config([store: {Local, fs_path: {:env, "EM_TEST_VAR"}, render_path: "/s"}, secret_key: "k"], fn ->
        {Local, opts} = Config.store()
        assert opts[:fs_path] == "resolved"
      end)
    after
      System.delete_env("EM_TEST_VAR")
    end

    test "resolves {:env, var, default} with fallback" do
      with_config([store: {Local, fs_path: {:env, "EM_MISSING_VAR", "/default"}, render_path: "/s"}, secret_key: "k"], fn ->
        {Local, opts} = Config.store()
        assert opts[:fs_path] == "/default"
      end)
    end
  end
end
