defmodule Jev.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/dannote/jev"

  def project do
    [
      app: :jev,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      name: "Jev",
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_apps: [:ex_unit]],
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Jev.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "TypeSafe Jev and compatible decision models for OTP: reply to Jev from a GenServer " <>
      "and pattern match on its answer."
  end

  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:json_codec, "~> 0.2.5"},
      {:telemetry, "~> 1.4"},
      {:plug, "~> 1.14", optional: true},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "TypeSafe docs" => "https://docs.typesafe.ai"},
      files: ~w(lib guides .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/introduction/getting-started.md",
        "guides/introduction/why-jev.md",
        "guides/usage/questions.md",
        "guides/usage/server.md",
        "guides/usage/recursive-workflows.md",
        "guides/usage/telemetry.md",
        "guides/usage/testing.md",
        "guides/cheatsheets/api.cheatmd",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Introduction: ~r/guides\/introduction\//,
        Usage: ~r/guides\/usage\//,
        Cheatsheets: ~r/guides\/cheatsheets\//
      ],
      groups_for_modules: [
        Questions: [Jev, Jev.Noul, Jev.Choice, Jev.Score],
        Server: [Jev.Server],
        Backends: [Jev.Backend, Jev.Telemetry],
        Transport: [Jev.HTTP, Jev.Error],
        Testing: [Jev.Test],
        Wire: [Jev.Wire, Jev.Wire.Response, Jev.Wire.Answer, Jev.Wire.Usage]
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
