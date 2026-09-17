# The pure layer (questions, reply parsing) never reaches the transport or the server,
# and the transport never reaches the server. Jev.Server sits on top of both.
[
  layers: [
    pure: ["Jev", "Jev.Noul", "Jev.Choice", "Jev.Score", "Jev.Error"],
    transport: "Jev.HTTP",
    server: ["Jev.Server", "Jev.Application"]
  ],
  deps: [
    forbidden: [
      {:pure, :transport},
      {:pure, :server},
      {:transport, :server}
    ]
  ]
]
