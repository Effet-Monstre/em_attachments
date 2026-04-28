defmodule EmAttachments.MemoryFileTest do
  use ExUnit.Case, async: true

  alias EmAttachments.{MemoryFile, SourceFile}

  test "new/2 creates a MemoryFile struct" do
    mf = MemoryFile.new("hello", "test.txt")
    assert %MemoryFile{pid: pid} = mf
    assert is_pid(pid)
    MemoryFile.cleanup(mf)
  end

  test "fetch_bytes/1 returns data without writing to disk" do
    mf = MemoryFile.new("hello world", "test.txt")
    assert {:ok, "hello world"} = SourceFile.fetch_bytes(mf)
    # Agent should still be alive (no local_path written)
    assert MemoryFile.state(mf).local_path == nil
    MemoryFile.cleanup(mf)
  end

  test "local_path!/1 writes data to disk on first call" do
    mf = MemoryFile.new("content", "test.txt")
    path = SourceFile.local_path!(mf)
    assert File.exists?(path)
    assert File.read!(path) == "content"
    MemoryFile.cleanup(mf)
  end

  test "local_path!/1 returns the same path on subsequent calls" do
    mf = MemoryFile.new("content", "test.txt")
    path1 = SourceFile.local_path!(mf)
    path2 = SourceFile.local_path!(mf)
    assert path1 == path2
    MemoryFile.cleanup(mf)
  end

  test "fetch_local_path/1 returns {:ok, path}" do
    mf = MemoryFile.new("data", "test.txt")
    assert {:ok, path} = SourceFile.fetch_local_path(mf)
    assert File.exists?(path)
    MemoryFile.cleanup(mf)
  end

  test "filename/1 returns the filename without disk I/O" do
    mf = MemoryFile.new("x", "photo.jpg")
    assert SourceFile.filename(mf) == "photo.jpg"
    assert MemoryFile.state(mf).local_path == nil
    MemoryFile.cleanup(mf)
  end

  test "size/1 returns byte_size of data without disk I/O" do
    mf = MemoryFile.new("hello", "f.txt")
    assert SourceFile.size(mf) == 5
    assert MemoryFile.state(mf).local_path == nil
    MemoryFile.cleanup(mf)
  end

  test "size/1 returns 0 for empty data" do
    mf = MemoryFile.new("", "empty.bin")
    assert SourceFile.size(mf) == 0
    MemoryFile.cleanup(mf)
  end

  test "cleanup/1 stops agent and removes temp file" do
    mf = MemoryFile.new("data", "test.txt")
    path = SourceFile.local_path!(mf)
    assert File.exists?(path)
    MemoryFile.cleanup(mf)
    refute File.exists?(path)
    refute Process.alive?(mf.pid)
  end

  test "cleanup/1 with no written file only stops agent" do
    mf = MemoryFile.new("data", "test.txt")
    pid = mf.pid
    MemoryFile.cleanup(mf)
    refute Process.alive?(pid)
  end
end
