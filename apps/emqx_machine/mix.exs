defmodule EMQXMachine.MixProject do
  use Mix.Project
  alias EMQXUmbrella.MixProject, as: UMP

  def project do
    [
      app: :emqx_machine,
      version: "0.1.0",
      build_path: "../../_build",
      # config_path: "../../config/config.exs",
      erlc_options: UMP.erlc_options(),
      erlc_paths: UMP.erlc_paths(),
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications
  def application do
    [extra_applications: UMP.extra_applications(), mod: {:emqx_machine_app, []}]
  end

  def deps() do
    [
      {:emqx, in_umbrella: true, runtime: false},
      {:emqx_conf, in_umbrella: true, runtime: false},
      {:emqx_dashboard, in_umbrella: true, runtime: false},
      {:emqx_management, in_umbrella: true, runtime: false},
      {:covertool, github: "zmstone/covertool", tag: "2.0.4.1"}
    ]
  end
end
