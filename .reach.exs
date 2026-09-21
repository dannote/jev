# The pure layer (questions, reply parsing) never reaches the transport or the server,
# and the transport never reaches the server. Jev.Server sits on top of both.
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
    transport: "Jev.HTTP",
    server: ["Jev.Server", "Jev.Application"],
    testing: "Jev.Test"
  ],
  deps: [
    forbidden: [
      {:pure, :transport},
      {:pure, :server},
      {:pure, :testing},
      {:transport, :server},
      {:transport, :testing},
      {:server, :testing},
      {:testing, :transport},
      {:testing, :server}
    ]
  ]
]
