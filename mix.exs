defmodule EmAttachments.MixProject do
  use Mix.Project

  def project do
    [
      app: :em_attachments,
      version: "0.1.14",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "File attachment library for Elixir, inspired by Shrine",
      docs: [main: "EmAttachments"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ecto, "~> 3.11", optional: true},
      {:ecto_sql, "~> 3.11", only: :test, optional: true},
      {:postgrex, "~> 0.17", only: :test, optional: true},
      {:plug, "~> 1.16", optional: true},
      {:vix, "~> 0.35", optional: true},
      {:mogrify, "~> 0.9", optional: true},
      {:phoenix, "~> 1.8", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
