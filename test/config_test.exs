defmodule EmAttachments.ConfigTest do
  use ExUnit.Case, async: false

  alias EmAttachments.{Backends.Local, Config}

  # Swap global config for the duration of a test, restore after.
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
  # Global config — explicit {mod, opts} form (existing behaviour)
  # ---------------------------------------------------------------------------

  describe "explicit {mod, opts}" do
    test "store and cache each use their own opts" do
      with_config(
        [
          store: {Local, fs_path: "/s", render_path: "/store"},
          cache: {Local, fs_path: "/c", render_path: "/cache"},
          secret_key: "k"
        ],
        fn ->
          {Local, s_opts} = Config.store()
          {Local, c_opts} = Config.cache()
          assert s_opts[:fs_path] == "/s"
          assert c_opts[:fs_path] == "/c"
        end
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Global config — keyword-list form for cache (new behaviour)
  # ---------------------------------------------------------------------------

  describe "keyword-list cache config" do
    test "inherits store's adapter module" do
      with_config(
        [
          store: {Local, fs_path: "/s", render_path: "/store"},
          cache: [fs_path: "/c", render_path: "/cache"],
          secret_key: "k"
        ],
        fn ->
          {cache_mod, _} = Config.cache()
          assert cache_mod == Local
        end
      )
    end

    test "inherits store opts and overrides only the specified keys" do
      with_config(
        [
          store: {Local, fs_path: "/s", render_path: "/store", extra: "shared"},
          cache: [fs_path: "/c", render_path: "/cache"],
          secret_key: "k"
        ],
        fn ->
          {Local, opts} = Config.cache()
          assert opts[:fs_path] == "/c"
          assert opts[:render_path] == "/cache"
          assert opts[:extra] == "shared"
        end
      )
    end

    test "cache opts win over inherited store opts" do
      with_config(
        [
          store: {Local, fs_path: "/s", render_path: "/store"},
          cache: [fs_path: "/c"],
          secret_key: "k"
        ],
        fn ->
          {Local, opts} = Config.cache()
          # render_path inherited from store
          assert opts[:render_path] == "/store"
          # fs_path overridden by cache
          assert opts[:fs_path] == "/c"
        end
      )
    end

    test "store config is unaffected" do
      with_config(
        [
          store: {Local, fs_path: "/s", render_path: "/store"},
          cache: [fs_path: "/c", render_path: "/cache"],
          secret_key: "k"
        ],
        fn ->
          {Local, opts} = Config.store()
          assert opts[:fs_path] == "/s"
        end
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Uploader-level cache override — keyword list
  # ---------------------------------------------------------------------------

  describe "uploader-level keyword-list cache override" do
    test "merges over global cache when global cache is explicit {mod, opts}" do
      with_config(
        [
          store: {Local, fs_path: "/s", render_path: "/store"},
          cache: {Local, fs_path: "/c", render_path: "/cache"},
          secret_key: "k"
        ],
        fn ->
          {mod, opts} = Config.cache(cache: [fs_path: "/custom"])
          assert mod == Local
          assert opts[:fs_path] == "/custom"
          assert opts[:render_path] == "/cache"
        end
      )
    end

    test "merges over global cache when global cache is keyword-list form" do
      with_config(
        [
          store: {Local, fs_path: "/s", render_path: "/store"},
          cache: [fs_path: "/c", render_path: "/cache"],
          secret_key: "k"
        ],
        fn ->
          {mod, opts} = Config.cache(cache: [render_path: "/override"])
          assert mod == Local
          assert opts[:fs_path] == "/c"
          assert opts[:render_path] == "/override"
        end
      )
    end
  end
end
