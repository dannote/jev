# The pure layer (questions, reply parsing) never reaches the transport or the server,
# the backend contract and telemetry sit above it, the transport implements them,
# and the transport never reaches the server. Jev.Server sits on top of all of it.
# Jev.Test builds wire bodies from the pure layer and nothing reaches it.
[
  layers: [
    pure: [
      "Jev",
      "Jev.Noul",
      "Jev.Choice",
      "Jev.Score",
      "Jev.Error",
      "Jev.Wire",
      "Jev.Wire.Response",
      "Jev.Wire.Answer",
      "Jev.Wire.Usage"
    ],
    backend: ["Jev.Backend", "Jev.Telemetry"],
    transport: "Jev.HTTP",
    server: ["Jev.Server", "Jev.Application"],
    testing: "Jev.Test"
  ],
  deps: [
    forbidden: [
      {:pure, :backend},
      {:pure, :transport},
      {:pure, :server},
      {:pure, :testing},
      {:backend, :transport},
      {:backend, :server},
      {:backend, :testing},
      {:transport, :server},
      {:transport, :testing},
      {:server, :testing},
      {:testing, :backend},
      {:testing, :transport},
      {:testing, :server}
    ]
  ]
]
