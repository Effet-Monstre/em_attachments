defmodule EmAttachments.Cmd do
  @moduledoc """
  Helpers for invoking CLI tools as derivative processors.

  `:input` and `:output` atoms in `args` are substituted with the actual input
  and output paths before the command is executed. For `run_stdout/4`, only
  `:input` is substituted — output is captured from the command's stdout.

  ## Options

    * `:ext` — output file extension including the dot, e.g. `".jpg"`. Defaults
      to `""`. Tools like ffmpeg and ImageMagick infer the output format from the
      file extension, so this option is usually required for `run/4`.

  ## Typical usage inside `handle/2`

  Returning `{:cmd, ...}` tuples from `handle/2` is the simplest path — the
  derivatives plugin auto-executes them and supplies the input path automatically.
  Call `run/4` directly only when you need conditional logic:

      {:ok, thumb} =
        EmAttachments.Cmd.run("ffmpeg",
          ["-i", :input, "-frames:v", "1", :output],
          input_path,
          ext: ".jpg")

      {:ok, text} =
        EmAttachments.Cmd.run_stdout("pdftotext", [:input, "-"], input_path)

  """

  alias EmAttachments.{MemoryFile, TempFile, Util}

  @type arg :: String.t() | :input | :output
  @type opt :: {:ext, String.t()}

  @doc """
  Runs `cmd` with `args`, writing output to a managed temp file.

  Returns `{:ok, TempFile.t()}` on success. The caller is responsible for
  cleaning up the TempFile (the derivatives plugin does this automatically).

  Errors:
    - `{:error, :command_not_found}` — executable not on PATH
    - `{:error, :non_zero_exit}` — command exited with a non-zero code
    - `{:error, :no_output}` — command exited 0 but wrote nothing to the output path
  """
  @spec run(String.t(), [arg()], String.t(), [opt()]) ::
          {:ok, TempFile.t()}
          | {:error, :command_not_found | :non_zero_exit | :no_output}
  def run(cmd, args, input_path, opts \\ []) do
    ext = Keyword.get(opts, :ext, "")
    output_path = Path.join(System.tmp_dir!(), "em_attach_cmd_#{Util.random_id(8)}#{ext}")
    resolved = expand_args(args, input_path, output_path)

    try do
      case System.cmd(cmd, resolved, stderr_to_stdout: false) do
        {_, 0} ->
          if File.exists?(output_path) do
            {:ok, TempFile.new(output_path, "derivative")}
          else
            {:error, :no_output}
          end

        {_, _} ->
          File.rm(output_path)
          {:error, :non_zero_exit}
      end
    rescue
      ErlangError -> {:error, :command_not_found}
    end
  end

  @doc "Like `run/4` but raises on error, returning `TempFile.t()` directly."
  @spec run!(String.t(), [arg()], String.t(), [opt()]) :: TempFile.t()
  def run!(cmd, args, input_path, opts \\ []) do
    case run(cmd, args, input_path, opts) do
      {:ok, tf} -> tf
      {:error, reason} -> raise "EmAttachments.Cmd: #{inspect(reason)}"
    end
  end

  @doc """
  Runs `cmd` with `args`, capturing stdout as an in-memory `MemoryFile`.

  Only `:input` is substituted in `args`; there is no `:output` — the tool is
  expected to write its result to stdout (e.g. `pdftotext input.pdf -`).

  Returns `{:ok, MemoryFile.t()}` on success.

  Errors:
    - `{:error, :command_not_found}` — executable not on PATH
    - `{:error, :non_zero_exit}` — command exited with a non-zero code
  """
  @spec run_stdout(String.t(), [arg()], String.t(), [opt()]) ::
          {:ok, MemoryFile.t()} | {:error, :command_not_found | :non_zero_exit}
  def run_stdout(cmd, args, input_path, opts \\ []) do
    filename = Keyword.get(opts, :filename, "derivative")
    resolved = expand_args(args, input_path, nil)

    try do
      case System.cmd(cmd, resolved, stderr_to_stdout: false) do
        {stdout, 0} -> {:ok, MemoryFile.new(stdout, filename)}
        {_, _} -> {:error, :non_zero_exit}
      end
    rescue
      ErlangError -> {:error, :command_not_found}
    end
  end

  @doc "Like `run_stdout/4` but raises on error, returning `MemoryFile.t()` directly."
  @spec run_stdout!(String.t(), [arg()], String.t(), [opt()]) :: MemoryFile.t()
  def run_stdout!(cmd, args, input_path, opts \\ []) do
    case run_stdout(cmd, args, input_path, opts) do
      {:ok, mf} -> mf
      {:error, reason} -> raise "EmAttachments.Cmd: #{inspect(reason)}"
    end
  end

  defp expand_args(args, input_path, output_path) do
    Enum.map(args, fn
      :input -> input_path
      :output -> output_path
      arg -> arg
    end)
  end
end
