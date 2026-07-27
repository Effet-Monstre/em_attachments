defmodule EmAttachments.CmdTest do
  use ExUnit.Case, async: false

  alias EmAttachments.{Cmd, MemoryFile, TempFile}
  alias EmAttachments.Test.Fixtures

  setup do
    input = Fixtures.txt_path("hello cmd")
    on_exit(fn -> File.rm(input) end)
    {:ok, input: input}
  end

  describe "run/4" do
    test "returns {:ok, TempFile} when command succeeds", %{input: input} do
      assert {:ok, %TempFile{} = tf} = Cmd.run("cp", [:input, :output], input, ext: ".txt")
      assert tf.managed
      assert File.exists?(tf.path)
      assert File.read!(tf.path) == "hello cmd"
      assert String.ends_with?(tf.path, ".txt")
      assert tf.size > 0
      TempFile.cleanup(tf)
      refute File.exists?(tf.path)
    end

    test "applies ext: option to output path", %{input: input} do
      assert {:ok, tf} = Cmd.run("cp", [:input, :output], input, ext: ".copy")
      assert String.ends_with?(tf.path, ".copy")
      File.rm(tf.path)
    end

    test "defaults to no extension when ext: is omitted", %{input: input} do
      assert {:ok, tf} = Cmd.run("cp", [:input, :output], input)
      refute String.contains?(Path.basename(tf.path), ".")
      File.rm(tf.path)
    end

    test "returns {:error, :non_zero_exit} when command exits non-zero", %{input: input} do
      assert {:error, :non_zero_exit} = Cmd.run("sh", ["-c", "exit 1"], input)
    end

    test "removes command output created before a non-zero exit", %{input: input} do
      before = Path.join(System.tmp_dir!(), "em_attach_cmd_*") |> Path.wildcard() |> MapSet.new()

      assert {:error, :non_zero_exit} =
               Cmd.run("sh", ["-c", "printf leaked > \"$1\"; exit 1", "sh", :output], input)

      after_files =
        Path.join(System.tmp_dir!(), "em_attach_cmd_*") |> Path.wildcard() |> MapSet.new()

      assert after_files == before
    end

    test "returns {:error, :no_output} when command exits 0 but writes nothing", %{input: input} do
      assert {:error, :no_output} = Cmd.run("sh", ["-c", "true"], input, ext: ".txt")
    end

    test "returns {:error, :command_not_found} when executable does not exist", %{input: input} do
      assert {:error, :command_not_found} =
               Cmd.run("__no_such_cmd__", [:input, :output], input, ext: ".txt")
    end
  end

  describe "run!/4" do
    test "returns TempFile on success", %{input: input} do
      tf = Cmd.run!("cp", [:input, :output], input, ext: ".txt")
      assert %TempFile{} = tf
      File.rm(tf.path)
    end

    test "raises on non-zero exit", %{input: input} do
      assert_raise RuntimeError, ~r/non_zero_exit/, fn ->
        Cmd.run!("sh", ["-c", "exit 1"], input)
      end
    end

    test "raises on command not found", %{input: input} do
      assert_raise RuntimeError, ~r/command_not_found/, fn ->
        Cmd.run!("__no_such_cmd__", [:input, :output], input)
      end
    end
  end

  describe "run_stdout/4" do
    test "returns {:ok, MemoryFile} capturing stdout", %{input: input} do
      assert {:ok, %MemoryFile{} = mf} = Cmd.run_stdout("cat", [:input], input)
      assert {:ok, "hello cmd"} = EmAttachments.SourceFile.fetch_bytes(mf)
      assert %{data: nil, local_path: path} = MemoryFile.state(mf)
      assert is_binary(path)
      MemoryFile.cleanup(mf)
      refute File.exists?(path)
    end

    test "MemoryFile is disk-backed so command stdout is not retained in memory", %{input: input} do
      {:ok, mf} = Cmd.run_stdout("cat", [:input], input)
      assert %{data: nil, local_path: path} = MemoryFile.state(mf)
      assert File.exists?(path)
      MemoryFile.cleanup(mf)
      refute File.exists?(path)
    end

    test "returns {:error, :non_zero_exit} when command exits non-zero", %{input: input} do
      assert {:error, :non_zero_exit} = Cmd.run_stdout("sh", ["-c", "exit 1"], input)
    end

    test "returns {:error, :command_not_found} when executable does not exist", %{input: input} do
      assert {:error, :command_not_found} =
               Cmd.run_stdout("__no_such_cmd__", [:input], input)
    end
  end

  describe "run_stdout!/4" do
    test "returns MemoryFile on success", %{input: input} do
      mf = Cmd.run_stdout!("cat", [:input], input)
      assert %MemoryFile{} = mf
      MemoryFile.cleanup(mf)
    end

    test "raises on non-zero exit", %{input: input} do
      assert_raise RuntimeError, ~r/non_zero_exit/, fn ->
        Cmd.run_stdout!("sh", ["-c", "exit 1"], input)
      end
    end
  end
end
