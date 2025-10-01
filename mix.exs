defmodule Financex.MixProject do
  use Mix.Project

  def project do
    [
      app: :financex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Financex.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5.0"},
      {:yaml_elixir, "~> 2.9"},
      {:plug, "~> 1.0"}
    ]
  end
end
